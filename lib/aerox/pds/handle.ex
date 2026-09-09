defmodule Aerox.PDS.Handle do
  @moduledoc """
  Handle rules on the PDS (upstream `pds/src/handle`, DESIGN §18.3): syntax
  and TLD validity from the kernel, the explicit-slur screen, and for
  handles under this PDS's own domains (DESIGN §8 item 2) the service
  constraints: no dots in the front part, 3–18 characters, and not one of
  the ~1000 reserved subdomains in `priv/reserved_handles.txt`.
  """
  alias Aerox.ATProto.Syntax
  alias Aerox.PDS.Config

  @reserved_path Path.expand("../../../priv/reserved_handles.txt", __DIR__)
  @external_resource @reserved_path
  @reserved @reserved_path |> File.read!() |> String.split("\n", trim: true) |> MapSet.new()

  @type error ::
          {:error, {:invalid_handle | :unsupported_domain | :handle_not_available, String.t()}}

  @doc "Lower-cases and syntax-checks (upstream `baseNormalizeAndValidate`)."
  @spec normalize(String.t()) :: {:ok, String.t()} | error
  def normalize(handle) do
    case Syntax.normalize_and_ensure_valid_handle(handle) do
      {:ok, h} -> {:ok, h}
      {:error, msg} -> {:error, {:invalid_handle, msg}}
    end
  end

  @doc "True when the handle ends with one of this PDS's handle domains."
  @spec service_domain?(String.t(), [String.t()]) :: boolean
  def service_domain?(handle, domains \\ Config.handle_domains()),
    do: Enum.any?(domains, &String.ends_with?(handle, &1))

  @doc """
  Upstream `normalizeAndValidateHandle` without the external-resolution step:
  returns `{:ok, handle}` for a valid service-domain handle, `{:ok, :external, handle}`
  for a valid handle on another domain (the caller must resolve it to the DID),
  or an error. `allow_reserved:` skips the reserved-word and slur checks (admin).
  """
  @spec validate(String.t(), keyword) :: {:ok, String.t()} | {:ok, :external, String.t()} | error
  def validate(handle, opts \\ []) do
    allow_reserved = Keyword.get(opts, :allow_reserved, false)
    domains = Keyword.get(opts, :domains, Config.handle_domains())

    with {:ok, normalized} <- normalize(handle),
         :ok <-
           if(Syntax.valid_tld?(normalized),
             do: :ok,
             else: {:error, {:invalid_handle, "Handle TLD is invalid or disallowed"}}
           ),
         :ok <-
           if(not allow_reserved and __MODULE__.Slurs.explicit_slur?(normalized),
             do: {:error, {:invalid_handle, "Inappropriate language in handle"}},
             else: :ok
           ) do
      if service_domain?(normalized, domains) do
        with :ok <- service_constraints(normalized, domains, allow_reserved),
             do: {:ok, normalized}
      else
        {:ok, :external, normalized}
      end
    end
  end

  @doc "Upstream `ensureHandleServiceConstraints`."
  @spec service_constraints(String.t(), [String.t()], boolean) :: :ok | error
  def service_constraints(handle, domains, allow_reserved \\ false) do
    domain = Enum.find(domains, "", &String.ends_with?(handle, &1))
    front = binary_part(handle, 0, byte_size(handle) - byte_size(domain))

    cond do
      String.contains?(front, ".") ->
        {:error, {:invalid_handle, "Invalid characters in handle"}}

      byte_size(front) < 3 ->
        {:error, {:invalid_handle, "Handle too short"}}

      byte_size(front) > 18 ->
        {:error, {:invalid_handle, "Handle too long"}}

      not allow_reserved and MapSet.member?(@reserved, front) ->
        {:error, {:handle_not_available, "Reserved handle"}}

      true ->
        :ok
    end
  end

  @spec reserved?(String.t()) :: boolean
  def reserved?(front), do: MapSet.member?(@reserved, front)
end
