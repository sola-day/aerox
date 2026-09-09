defmodule Aerox.Identity.DNS do
  @moduledoc "DNS TXT lookup as a behaviour so tests can inject answers; `Inet` uses `:inet_res`."

  @callback txt(name :: String.t(), timeout :: pos_integer) ::
              {:ok, [String.t()]} | {:error, term}

  @spec txt(String.t(), keyword) :: {:ok, [String.t()]} | {:error, term}
  def txt(name, opts \\ []) do
    mod = Keyword.get(opts, :dns) || Application.get_env(:aerox, __MODULE__, __MODULE__.Inet)
    mod.txt(name, Keyword.get(opts, :timeout, 3_000))
  end

  defmodule Inet do
    @moduledoc false
    @behaviour Aerox.Identity.DNS

    @impl true
    def txt(name, timeout) do
      case :inet_res.lookup(String.to_charlist(name), :in, :txt, [], timeout) do
        [] ->
          {:error, :nxdomain}

        records ->
          {:ok,
           Enum.map(records, fn chunks -> chunks |> Enum.map(&List.to_string/1) |> Enum.join() end)}
      end
    rescue
      e -> {:error, e}
    end
  end
end
