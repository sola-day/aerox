defmodule Aerox.ATProto.Frame do
  @moduledoc """
  Event-stream frames (DESIGN §5.1): a WebSocket message is two DAG-CBOR
  values back to back — a header `{op: 1, t: "#commit"}` and the body, or
  `{op: -1}` and `{error, message}`. Transcribed from
  `xrpc-server/src/stream/frames.ts`.
  """
  alias Aerox.ATProto.DagCBOR

  @type t ::
          {:message, type :: String.t() | nil, body :: map}
          | {:error, name :: String.t(), message :: String.t() | nil}

  @spec encode(t) :: binary
  def encode({:message, nil, body}), do: DagCBOR.encode(%{"op" => 1}) <> DagCBOR.encode(body)

  def encode({:message, type, body}),
    do: DagCBOR.encode(%{"op" => 1, "t" => type}) <> DagCBOR.encode(body)

  def encode({:error, name, message}) do
    body = if message, do: %{"error" => name, "message" => message}, else: %{"error" => name}
    DagCBOR.encode(%{"op" => -1}) <> DagCBOR.encode(body)
  end

  @doc "Builds a message frame from a body whose `$type` names the frame type (upstream `fromLexValue`)."
  @spec message(map, String.t()) :: t
  def message(%{"$type" => type} = body, nsid) when is_binary(type) do
    t =
      case String.split(type, "#") do
        [prefix, frag] when prefix in ["", nsid] -> "#" <> frag
        _ -> type
      end

    {:message, t, Map.delete(body, "$type")}
  end

  def message(body, _nsid), do: {:message, nil, body}

  @spec decode(binary) :: {:ok, t} | {:error, term}
  def decode(bytes) do
    with {:ok, header, rest} <- DagCBOR.decode_prefix(bytes),
         {:ok, body, <<>>} <- decode_body(rest) do
      case header do
        %{"op" => 1} = h -> {:ok, {:message, h["t"], body}}
        %{"op" => -1} -> decode_error(body)
        _ -> {:error, :invalid_frame_header}
      end
    else
      {:ok, _body, _more} -> {:error, :too_many_items}
      {:error, _} = e -> e
    end
  end

  defp decode_body(<<>>), do: {:error, :missing_frame_body}
  defp decode_body(rest), do: DagCBOR.decode_prefix(rest)

  defp decode_error(%{"error" => name} = body) when is_binary(name),
    do: {:ok, {:error, name, body["message"]}}

  defp decode_error(_), do: {:error, :invalid_error_frame}
end
