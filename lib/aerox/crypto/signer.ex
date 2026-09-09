defmodule Aerox.Crypto.Signer do
  @moduledoc """
  The instance PLC rotation key behind a behaviour (DESIGN §14.2 point 2).
  Implementations: `Local` (raw key, dev and test only), `Kms` and `Remote`
  (M10). The signer exposes `sign/2` and `did_key/1` only; the private key
  never enters the calling process except in `Local`.

  Production configuration refuses `Local`: see `check_config!/1`.
  """
  alias Aerox.ATProto.Crypto

  @type signer :: {module, term}

  @callback did_key(state :: term) :: String.t()
  @callback sign(state :: term, message :: iodata) :: {:ok, binary} | {:error, term}

  @spec did_key(signer) :: String.t()
  def did_key({mod, state}), do: mod.did_key(state)

  @spec sign(signer, iodata) :: {:ok, binary} | {:error, term}
  def sign({mod, state}, message), do: mod.sign(state, message)

  @doc "Builds the configured signer; `config :aerox, Aerox.Crypto.Signer, adapter: ..., ...`."
  @spec from_config(keyword) :: signer
  def from_config(config) do
    mod = Keyword.fetch!(config, :adapter)
    {mod, mod.init(config)}
  end

  @doc "Raises when a production node is configured with the Local signer."
  @spec check_config!(keyword, atom) :: :ok
  def check_config!(config, env) do
    if env == :prod and Keyword.get(config, :adapter) == __MODULE__.Local do
      raise ArgumentError, "Aerox.Crypto.Signer.Local is not allowed in production (DESIGN §14.2)"
    end

    :ok
  end

  defmodule Local do
    @moduledoc "A keypair held in memory. Dev and test only."
    @behaviour Aerox.Crypto.Signer

    def init(config) do
      case Keyword.get(config, :private_key_hex) do
        nil -> Crypto.generate(Keyword.get(config, :curve, :k256))
        hex -> Crypto.import(Keyword.get(config, :curve, :k256), hex)
      end
    end

    @impl true
    def did_key(%Crypto.Keypair{} = kp), do: Crypto.did_key(kp)

    @impl true
    def sign(%Crypto.Keypair{} = kp, message), do: {:ok, Crypto.sign(kp, message)}
  end
end
