defmodule Aerox.ATProto.CAR do
  @moduledoc """
  CARv1 read and write (DESIGN §3.10). Layout: a varint-prefixed DAG-CBOR
  header `{version: 1, roots: [cid]}` followed by blocks, each a varint
  length then CID bytes then block bytes. Reading verifies every block's
  bytes against its CID (a CAR from a stranger is data, not truth).

  `decode/1` handles a binary; `stream/1` consumes an enumerable of chunks
  and yields `{:root, cid}`/`{:block, cid, bytes}` items lazily, so a
  multi-gigabyte export never has to be held in memory. `encode_stream/2`
  is the writing counterpart.
  """
  import Bitwise
  alias Aerox.ATProto.{CID, DagCBOR}

  @type block :: {CID.t(), binary}

  # -------------------------------------------------------------- write

  @doc "Encodes a CAR with one root (or none) and the given blocks, in order."
  @spec encode(CID.t() | nil, Enumerable.t()) :: binary
  def encode(root, blocks),
    do: root |> encode_stream(blocks) |> Enum.to_list() |> IO.iodata_to_binary()

  @doc "Lazily yields the iodata chunks of a CAR."
  @spec encode_stream(CID.t() | nil, Enumerable.t()) :: Enumerable.t()
  def encode_stream(root, blocks) do
    header = DagCBOR.encode(%{"version" => 1, "roots" => List.wrap(root)})

    Stream.concat(
      [[varint(byte_size(header)), header]],
      Stream.map(blocks, fn {cid, bytes} ->
        cid_bytes = CID.to_bytes(cid)
        [varint(byte_size(cid_bytes) + byte_size(bytes)), cid_bytes, bytes]
      end)
    )
  end

  @doc "Unsigned LEB128."
  @spec varint(non_neg_integer) :: binary
  def varint(n) when n < 0x80, do: <<n>>
  def varint(n), do: <<1::1, n::7, varint(n >>> 7)::binary>>

  # --------------------------------------------------------------- read

  @doc "Decodes a whole CAR: roots and blocks (in file order, CID-verified)."
  @spec decode(binary, keyword) :: {:ok, %{roots: [CID.t()], blocks: [block]}} | {:error, term}
  def decode(bytes, opts \\ []) when is_binary(bytes) do
    with {:ok, roots, rest} <- read_header(bytes),
         {:ok, blocks} <- read_blocks(rest, [], opts) do
      {:ok, %{roots: roots, blocks: blocks}}
    end
  end

  @doc "Decodes a CAR that must have exactly one root."
  @spec decode_with_root(binary, keyword) :: {:ok, CID.t(), [block]} | {:error, term}
  def decode_with_root(bytes, opts \\ []) do
    case decode(bytes, opts) do
      {:ok, %{roots: [root], blocks: blocks}} -> {:ok, root, blocks}
      {:ok, %{roots: roots}} -> {:error, {:expected_one_root, length(roots)}}
      error -> error
    end
  end

  @doc "Decodes a CAR straight into a memory blockstore."
  @spec to_blockstore(binary, keyword) ::
          {:ok, [CID.t()], Aerox.ATProto.Blockstore.t()} | {:error, term}
  def to_blockstore(bytes, opts \\ []) do
    with {:ok, %{roots: roots, blocks: blocks}} <- decode(bytes, opts) do
      {:ok, roots, Aerox.ATProto.Blockstore.Memory.new(blocks)}
    end
  end

  defp read_header(bytes) do
    with {:ok, len, rest} <- read_varint(bytes),
         <<header::binary-size(^len), rest::binary>> <- rest,
         {:ok, %{"version" => 1, "roots" => roots}} when is_list(roots) <- DagCBOR.decode(header),
         true <- Enum.all?(roots, &match?(%CID{}, &1)) do
      {:ok, roots, rest}
    else
      {:ok, other} -> {:error, {:invalid_header, other}}
      {:error, reason} -> {:error, {:invalid_header, reason}}
      _ -> {:error, :invalid_header}
    end
  end

  defp read_blocks(<<>>, acc, _opts), do: {:ok, Enum.reverse(acc)}

  defp read_blocks(bytes, acc, opts) do
    with {:ok, len, rest} <- read_varint(bytes),
         <<section::binary-size(^len), rest::binary>> <- rest,
         {:ok, cid, data} <- split_block(section),
         :ok <- verify(cid, data, opts) do
      read_blocks(rest, [{cid, data} | acc], opts)
    else
      {:error, _} = e -> e
      _ -> {:error, :truncated}
    end
  end

  # CIDv1 dag-cbor/raw sha-256 is always 36 bytes; that is the only CID
  # shape atproto uses, so anything else is malformed rather than merely
  # unsupported.
  defp split_block(<<cid_bytes::binary-size(36), data::binary>>) do
    case CID.from_bytes(cid_bytes) do
      {:ok, cid} -> {:ok, cid, data}
      {:error, reason} -> {:error, {:invalid_block_cid, reason}}
    end
  end

  defp split_block(_), do: {:error, :invalid_block}

  defp verify(cid, data, opts) do
    if Keyword.get(opts, :verify, true) and not CID.verify(cid, data),
      do: {:error, {:cid_mismatch, cid}},
      else: :ok
  end

  @doc false
  def read_varint(bytes, shift \\ 0, acc \\ 0)
  def read_varint(<<0::1, n::7, rest::binary>>, shift, acc), do: {:ok, acc ||| n <<< shift, rest}

  def read_varint(<<1::1, n::7, rest::binary>>, shift, acc) when shift < 63,
    do: read_varint(rest, shift + 7, acc ||| n <<< shift)

  def read_varint(_, _, _), do: {:error, :invalid_varint}

  # ------------------------------------------------------------- stream

  @doc """
  Lazily parses a CAR from an enumerable of binary chunks. Emits
  `{:roots, [cid]}` once, then `{:block, cid, bytes}` per block; a malformed
  or CID-mismatched block raises `Aerox.ATProto.CAR.Error`.
  """
  @spec stream(Enumerable.t(), keyword) :: Enumerable.t()
  def stream(chunks, opts \\ []) do
    Stream.transform(
      Stream.concat(chunks, [:eof]),
      fn -> {:header, <<>>} end,
      fn
        :eof, {_, <<>>} -> {:halt, :done}
        :eof, {_, _rest} -> raise __MODULE__.Error, "truncated CAR"
        chunk, {phase, buf} -> drain(phase, buf <> chunk, [], opts)
      end,
      fn _ -> :ok end
    )
  end

  defp drain(:header, buf, out, opts) do
    case read_header(buf) do
      {:ok, roots, rest} -> drain(:blocks, rest, [{:roots, roots} | out], opts)
      {:error, {:invalid_header, _} = reason} -> raise __MODULE__.Error, inspect(reason)
      _ -> {Enum.reverse(out), {:header, buf}}
    end
  end

  defp drain(:blocks, buf, out, opts) do
    with {:ok, len, rest} <- read_varint(buf),
         <<section::binary-size(^len), rest::binary>> <- rest do
      with {:ok, cid, data} <- split_block(section),
           :ok <- verify(cid, data, opts) do
        drain(:blocks, rest, [{:block, cid, data} | out], opts)
      else
        {:error, reason} -> raise __MODULE__.Error, inspect(reason)
      end
    else
      _ -> {Enum.reverse(out), {:blocks, buf}}
    end
  end

  defmodule Error do
    defexception [:message]
  end
end
