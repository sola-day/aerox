defmodule Aerox.ATProto.Syntax do
  @moduledoc """
  Identifier syntax (DESIGN §3.10): handle, NSID, DID, at-uri, record key,
  TID and datetime. Every rule here is transcribed from
  `atproto/packages/syntax/src` (commit 62f944dd) and pinned by the
  `interop-test-files/syntax` vectors in `test/golden/syntax/`.

  Each `valid_*?/1` is a boolean; each `ensure_valid_*/1` returns `:ok` or
  `{:error, reason}` with upstream's message, so the XRPC layer can surface
  the same text. Nothing here normalises silently: `normalize_handle/1` is
  the only case-changing function and is explicit.
  """

  @type reason :: String.t()

  # ---------------------------------------------------------------- handle

  @invalid_handle "handle.invalid"
  @disallowed_tlds ~w(.local .arpa .invalid .localhost .internal .example .alt .onion)

  @handle_regex ~r/^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/

  @doc "The reserved handle used when resolution fails (`handle.invalid`)."
  def invalid_handle, do: @invalid_handle

  @spec valid_handle?(term) :: boolean
  def valid_handle?(input) when is_binary(input),
    do: byte_size(input) <= 253 and Regex.match?(@handle_regex, input)

  def valid_handle?(_), do: false

  @spec ensure_valid_handle(String.t()) :: :ok | {:error, reason}
  def ensure_valid_handle(input) when is_binary(input) do
    cond do
      not Regex.match?(~r/^[a-zA-Z0-9.-]*$/, input) ->
        {:error, "Disallowed characters in handle (ASCII letters, digits, dashes, periods only)"}

      byte_size(input) > 253 ->
        {:error, "Handle is too long (253 chars max)"}

      true ->
        labels = String.split(input, ".")

        if length(labels) < 2 do
          {:error, "Handle domain needs at least two parts"}
        else
          check_handle_labels(labels)
        end
    end
  end

  defp check_handle_labels(labels) do
    last = length(labels) - 1

    labels
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {l, i} ->
      cond do
        l == "" ->
          {:error, "Handle parts can not be empty"}

        byte_size(l) > 63 ->
          {:error, "Handle part too long (max 63 chars)"}

        String.starts_with?(l, "-") or String.ends_with?(l, "-") ->
          {:error, "Handle parts can not start or end with hyphens"}

        i == last and not Regex.match?(~r/^[a-zA-Z]/, l) ->
          {:error, "Handle final component (TLD) must start with ASCII letter"}

        true ->
          nil
      end
    end)
  end

  @doc "Lower-cases a handle. The only normalisation in this module."
  @spec normalize_handle(String.t()) :: String.t()
  def normalize_handle(handle), do: String.downcase(handle)

  @spec normalize_and_ensure_valid_handle(String.t()) :: {:ok, String.t()} | {:error, reason}
  def normalize_and_ensure_valid_handle(handle) do
    normalized = normalize_handle(handle)

    case ensure_valid_handle(normalized) do
      :ok -> {:ok, normalized}
      error -> error
    end
  end

  @doc "False for the TLDs upstream refuses to serve handles under."
  @spec valid_tld?(String.t()) :: boolean
  def valid_tld?(handle), do: not Enum.any?(@disallowed_tlds, &String.ends_with?(handle, &1))

  # ------------------------------------------------------------------ NSID

  @nsid_max 253 + 1 + 63
  @nsid_regex ~r/^[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(?:\.[a-zA-Z](?:[a-zA-Z0-9]{0,62})?)$/

  @spec valid_nsid?(term) :: boolean
  def valid_nsid?(input) when is_binary(input),
    do:
      byte_size(input) <= @nsid_max and byte_size(input) >= 5 and Regex.match?(@nsid_regex, input)

  def valid_nsid?(_), do: false

  @spec ensure_valid_nsid(String.t()) :: :ok | {:error, reason}
  def ensure_valid_nsid(input) when is_binary(input) do
    case parse_nsid(input) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Splits an NSID into its segments after full validation."
  @spec parse_nsid(String.t()) :: {:ok, [String.t()]} | {:error, reason}
  def parse_nsid(input) when is_binary(input) do
    cond do
      byte_size(input) > @nsid_max ->
        {:error, "NSID is too long (317 chars max)"}

      not Regex.match?(~r/^[a-zA-Z0-9.-]*$/, input) ->
        {:error, "Disallowed characters in NSID (ASCII letters, digits, dashes, periods only)"}

      true ->
        segments = String.split(input, ".")

        with :ok <- nsid_segment_count(segments),
             :ok <- nsid_segments(segments),
             :ok <- nsid_first(hd(segments)),
             :ok <- nsid_name(List.last(segments)) do
          {:ok, segments}
        end
    end
  end

  defp nsid_segment_count(segments) when length(segments) < 3,
    do: {:error, "NSID needs at least three parts"}

  defp nsid_segment_count(_), do: :ok

  defp nsid_segments(segments) do
    Enum.find_value(segments, :ok, fn l ->
      cond do
        l == "" ->
          {:error, "NSID parts can not be empty"}

        byte_size(l) > 63 ->
          {:error, "NSID part too long (max 63 chars)"}

        String.starts_with?(l, "-") or String.ends_with?(l, "-") ->
          {:error, "NSID parts can not start or end with hyphen"}

        true ->
          nil
      end
    end)
  end

  defp nsid_first(<<c, _::binary>>) when c in ?0..?9,
    do: {:error, "NSID first part may not start with a digit"}

  defp nsid_first(_), do: :ok

  defp nsid_name(<<c, _::binary>>) when c in ?0..?9,
    do: {:error, "NSID name part must be only letters and digits (and no leading digit)"}

  defp nsid_name(name) do
    if String.contains?(name, "-"),
      do: {:error, "NSID name part must be only letters and digits (and no leading digit)"},
      else: :ok
  end

  @doc "The authority of an NSID in domain order (`com.atproto.repo.getRecord` → `atproto.com`)."
  @spec nsid_authority(String.t()) :: String.t()
  def nsid_authority(nsid) do
    {:ok, segments} = parse_nsid(nsid)
    segments |> Enum.drop(-1) |> Enum.reverse() |> Enum.join(".")
  end

  @spec nsid_name(String.t()) :: String.t()
  def nsid_name_of(nsid), do: nsid |> String.split(".") |> List.last()

  # ------------------------------------------------------------------- DID

  @did_regex ~r/^did:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]$/

  @spec valid_did?(term) :: boolean
  def valid_did?(input) when is_binary(input),
    do: byte_size(input) <= 2048 and Regex.match?(@did_regex, input)

  def valid_did?(_), do: false

  @spec ensure_valid_did(String.t()) :: :ok | {:error, reason}
  def ensure_valid_did(input) when is_binary(input) do
    cond do
      not String.starts_with?(input, "did:") ->
        {:error, "DID requires \"did:\" prefix"}

      byte_size(input) > 2048 ->
        {:error, "DID is too long (2048 chars max)"}

      String.ends_with?(input, ":") or String.ends_with?(input, "%") ->
        {:error, "DID can not end with \":\" or \"%\""}

      not Regex.match?(~r/^[a-zA-Z0-9._:%-]*$/, input) ->
        {:error,
         "Disallowed characters in DID (ASCII letters, digits, and a couple other characters only)"}

      true ->
        case String.split(input, ":") do
          [_, _] ->
            {:error, "DID requires prefix, method, and method-specific content"}

          [_, method | _] ->
            if Regex.match?(~r/^[a-z]+$/, method),
              do: :ok,
              else: {:error, "DID method must be lower-case letters"}
        end
    end
  end

  @doc "The method of a syntactically valid DID (`did:plc:abc` → `\"plc\"`)."
  @spec did_method(String.t()) :: String.t()
  def did_method("did:" <> rest), do: rest |> String.split(":", parts: 2) |> hd()

  # ------------------------------------------------------- at-identifier

  @spec valid_at_identifier?(term) :: boolean
  def valid_at_identifier?(input) when is_binary(input) do
    if String.starts_with?(input, "did:"), do: valid_did?(input), else: valid_handle?(input)
  end

  def valid_at_identifier?(_), do: false

  @spec ensure_valid_at_identifier(String.t()) :: :ok | {:error, reason}
  def ensure_valid_at_identifier(input) when is_binary(input) do
    if String.starts_with?(input, "did:") do
      ensure_valid_did(input)
    else
      case ensure_valid_handle(input) do
        :ok -> :ok
        {:error, _} -> {:error, "Not a valid handle or DID"}
      end
    end
  end

  # ---------------------------------------------------------------- at-uri

  @at_uri_invalid_char ~r/[^a-zA-Z0-9._~:@!$&'()*+,;=%\/\\\[\]#?-]/
  @at_uri_regex ~r/^(?<uri>at:\/\/(?<authority>[^\/?#\s]+)(?:\/(?<collection>[^\/?#\s]+)(?:\/(?<rkey>[^\/?#\s]+))?)?(?<trailing>\/)?)(?:\?(?<query>[^#\s]*))?(?:#(?<hash>[^\s]*))?$/
  @json_pointer_regex ~r/^\/[a-zA-Z0-9._~:@!$&')(*+,;=%\[\]\/-]*$/

  @typedoc "Parsed at-uri. `rkey` and `collection` are nil when absent."
  @type at_uri :: %{
          authority: String.t(),
          collection: String.t() | nil,
          rkey: String.t() | nil,
          query: String.t() | nil,
          hash: String.t() | nil
        }

  @doc """
  Parses an at-uri. Default is upstream's *strict* mode (no trailing slash, no
  query, record key validated), which is what the interop vectors are checked
  against; pass `strict: false` for the lenient `AtUri` class behaviour.
  """
  @spec parse_at_uri(term, keyword) :: {:ok, at_uri} | {:error, reason}
  def parse_at_uri(input, opts \\ [])

  def parse_at_uri(input, opts) when is_binary(input) do
    strict = Keyword.get(opts, :strict, true)

    cond do
      byte_size(input) > 8192 ->
        {:error, "ATURI exceeds maximum length"}

      Regex.match?(@at_uri_invalid_char, input) ->
        {:error, "Disallowed characters in ATURI (ASCII)"}

      true ->
        case Regex.named_captures(@at_uri_regex, input) do
          nil -> {:error, at_uri_detail(input)}
          groups -> at_uri_groups(groups, input, strict)
        end
    end
  end

  def parse_at_uri(_, _), do: {:error, "ATURI must be a string"}

  defp at_uri_detail(input) do
    cond do
      not String.starts_with?(input, "at://") ->
        "ATURI must start with \"at://\""

      String.contains?(input, " ") ->
        "ATURI can not contain spaces"

      String.contains?(binary_part(input, 5, byte_size(input) - 5), "//") ->
        "ATURI can not have empty path segments"

      true ->
        "ATURI does not match expected format"
    end
  end

  defp at_uri_groups(g, input, strict) do
    collection = blank_to_nil(g["collection"])
    rkey = blank_to_nil(g["rkey"])
    # An optional group that did not participate and one that matched the
    # empty string both come back as ""; `?`/`#` in the input tells them apart,
    # and upstream treats a present-but-empty query or fragment as present.
    query = if String.contains?(input, "?"), do: g["query"], else: nil
    hash = if String.contains?(input, "#"), do: g["hash"], else: nil
    trailing = blank_to_nil(g["trailing"])

    cond do
      not valid_at_identifier?(g["authority"]) ->
        {:error, "ATURI has invalid authority"}

      collection != nil and not valid_nsid?(collection) ->
        {:error, "ATURI has invalid collection"}

      hash != nil and not Regex.match?(@json_pointer_regex, hash) ->
        {:error, "ATURI has invalid fragment (Invalid JSON pointer)"}

      strict and trailing != nil ->
        {:error, "ATURI can not have a trailing slash"}

      strict and query != nil ->
        {:error, "ATURI query part is not allowed"}

      strict and rkey != nil and not valid_record_key?(rkey) ->
        {:error, "ATURI has invalid record key"}

      true ->
        {:ok,
         %{
           authority: g["authority"],
           collection: collection,
           rkey: rkey,
           query: query,
           hash: hash
         }}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  @doc "Strict validity, as upstream's `isAtUriString` (the syntax vectors run through it)."
  @spec valid_at_uri?(term) :: boolean
  def valid_at_uri?(input), do: match?({:ok, _}, parse_at_uri(input))

  @spec ensure_valid_at_uri(String.t()) :: :ok | {:error, reason}
  def ensure_valid_at_uri(input) do
    case parse_at_uri(input) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Builds `at://authority/collection/rkey`."
  @spec at_uri(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def at_uri(authority, collection \\ nil, rkey \\ nil) do
    Enum.join(["at://#{authority}"] ++ Enum.reject([collection, rkey], &is_nil/1), "/")
  end

  # ------------------------------------------------------------- space-uri

  @space_uri_regex ~r/^ats:\/\/(?<authority>[^\/?#\s]+)(?:\/(?<space_type>[^\/?#\s]+)(?:\/(?<skey>[^\/?#\s]+)(?:\/(?<user_did>[^\/?#\s]+)(?:\/(?<collection>[^\/?#\s]+)(?:\/(?<rkey>[^\/?#\s]+))?)?)?)?)?$/i

  @doc """
  Space URI (DESIGN §12, `permissioned-data` branch `space-uri.ts`):
  `ats://spaceDid/spaceType/skey[/userDid/collection/rkey]`. Strict by
  default: the type and collection are NSIDs, the DIDs are DIDs, the rkey a
  record key.
  """
  @spec parse_space_uri(term, keyword) :: {:ok, map} | {:error, reason}
  def parse_space_uri(input, opts \\ [])

  def parse_space_uri(input, opts) when is_binary(input) do
    strict = Keyword.get(opts, :strict, true)

    with true <- byte_size(input) <= 8192 || {:error, "space-uri exceeds maximum length"},
         false <-
           Regex.match?(@at_uri_invalid_char, input) &&
             {:error, "Disallowed characters in space-uri"},
         %{} = g <-
           Regex.named_captures(@space_uri_regex, space_uri_alpha_form(input)) ||
             {:error, "space-uri does not match expected format"},
         true <- valid_did?(g["authority"]) || {:error, "space-uri has invalid authority"},
         :ok <- space_uri_parts(g, strict) do
      {:ok, Map.new(g, fn {k, v} -> {String.to_atom(k), blank_to_nil(v)} end)}
    else
      {:error, _} = e -> e
    end
  end

  def parse_space_uri(_, _), do: {:error, "space-uri must be a string"}

  defp space_uri_parts(_g, false), do: :ok

  defp space_uri_parts(g, true) do
    cond do
      g["space_type"] != "" and not valid_nsid?(g["space_type"]) ->
        {:error, "space-uri has invalid space type"}

      g["user_did"] != "" and not valid_did?(g["user_did"]) ->
        {:error, "space-uri has invalid user did"}

      g["collection"] != "" and not valid_nsid?(g["collection"]) ->
        {:error, "space-uri has invalid collection"}

      g["rkey"] != "" and not valid_record_key?(g["rkey"]) ->
        {:error, "space-uri has invalid record key"}

      true ->
        :ok
    end
  end

  # The Spaces alpha release (the `bulletin` client, `@atproto/lex` format
  # `space-ref`) writes `at://<did>/space/<type>/<skey>[...]`; the branch's
  # `space-uri.ts` writes `ats://<did>/<type>/<skey>[...]`. Both parse to the
  # same parts; the form is preserved by callers (Aerox.PDS.Space.Uri).
  defp space_uri_alpha_form("at://" <> rest) do
    case String.split(rest, "/space/", parts: 2) do
      [did, tail] -> "ats://" <> did <> "/" <> tail
      _ -> "at://" <> rest
    end
  end

  defp space_uri_alpha_form(input), do: input

  @spec valid_space_uri?(term) :: boolean
  def valid_space_uri?(input), do: match?({:ok, _}, parse_space_uri(input))

  # ------------------------------------------------------------- language

  @language_regex ~r/^(i|[a-z]{2,3})(-[a-zA-Z0-9]+)*$/

  @doc "BCP 47 tag shape, as indigo's `ParseLanguage` (≤ 128 chars)."
  @spec valid_language?(term) :: boolean
  def valid_language?(input) when is_binary(input),
    do: input != "" and byte_size(input) <= 128 and Regex.match?(@language_regex, input)

  def valid_language?(_), do: false

  # ------------------------------------------------------------------ uri

  @uri_regex ~r/^[a-z][a-z.-]{0,80}:[[:graph:]]+$/

  @doc "Generic URI shape, as indigo's `ParseURI` (scheme, then non-space characters, ≤ 8192)."
  @spec valid_uri?(term) :: boolean
  def valid_uri?(input) when is_binary(input),
    do: input != "" and byte_size(input) <= 8192 and Regex.match?(@uri_regex, input)

  def valid_uri?(_), do: false

  # ------------------------------------------------------------ record key

  @rkey_regex ~r/^[a-zA-Z0-9_~.:-]{1,512}$/

  @spec valid_record_key?(term) :: boolean
  def valid_record_key?(input) when is_binary(input) do
    byte_size(input) in 1..512 and Regex.match?(@rkey_regex, input) and input not in [".", ".."]
  end

  def valid_record_key?(_), do: false

  @spec ensure_valid_record_key(String.t()) :: :ok | {:error, reason}
  def ensure_valid_record_key(input) when is_binary(input) do
    cond do
      byte_size(input) > 512 or byte_size(input) < 1 ->
        {:error, "record key must be 1 to 512 characters"}

      input in [".", ".."] ->
        {:error, "record key can not be \".\" or \"..\""}

      not Regex.match?(@rkey_regex, input) ->
        {:error, "record key syntax not valid (regex)"}

      true ->
        :ok
    end
  end

  # ------------------------------------------------------------------- TID

  @tid_regex ~r/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/

  @spec valid_tid?(term) :: boolean
  def valid_tid?(input) when is_binary(input),
    do: byte_size(input) == 13 and Regex.match?(@tid_regex, input)

  def valid_tid?(_), do: false

  @spec ensure_valid_tid(String.t()) :: :ok | {:error, reason}
  def ensure_valid_tid(input) when is_binary(input) do
    cond do
      byte_size(input) != 13 -> {:error, "TID must be 13 characters"}
      not Regex.match?(@tid_regex, input) -> {:error, "TID syntax not valid (regex)"}
      true -> :ok
    end
  end

  # -------------------------------------------------------------- datetime

  @datetime_regex ~r/^(?<year>[0-9]{4})-(?<month>0[1-9]|1[012])-(?<day>[0-2][0-9]|3[01])T(?<hour>[0-1][0-9]|2[0-3]):(?<minute>[0-5][0-9]):(?<second>[0-5][0-9]|60)(?<frac>\.[0-9]+)?(?<offset>Z|(?<numoffset>[+-](?:[0-1][0-9]|2[0-3]):[0-5][0-9]))$/

  @doc """
  Validates and parses an atproto datetime (RFC 3339 profile, `Z` or `±hh:mm`,
  no `-00:00`, at most 64 characters). Returns the instant as a `DateTime` in
  UTC. A syntactically valid string whose calendar date does not exist (month
  zero, day 32, second 61) is rejected here, matching upstream's post-regex
  `Date` parse.
  """
  @spec parse_datetime(term) :: {:ok, DateTime.t()} | {:error, reason}
  def parse_datetime(input) when is_binary(input) do
    cond do
      byte_size(input) > 64 ->
        {:error, "datetime is too long (64 chars max)"}

      String.ends_with?(input, "-00:00") ->
        {:error, "datetime can not use \"-00:00\" for UTC timezone"}

      true ->
        case Regex.named_captures(@datetime_regex, input) do
          nil ->
            {:error,
             "datetime is not in a valid format (must match RFC 3339 & ISO 8601 with 'Z' or ±hh:mm timezone)"}

          g ->
            build_datetime(g)
        end
    end
  end

  def parse_datetime(_), do: {:error, "datetime must be a string"}

  defp build_datetime(g) do
    [year, month, day, hour, minute, second] =
      Enum.map(~w(year month day hour minute second), &String.to_integer(g[&1]))

    micro = frac_to_micro(g["frac"])

    with {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second, micro),
         {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC"),
         {:ok, dt} <- apply_offset(dt, g["numoffset"]) do
      cond do
        dt.year < 0 -> {:error, "datetime normalized to a negative time"}
        dt.year > 9999 -> {:error, "datetime year is too far in the future"}
        true -> {:ok, dt}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "datetime did not parse as ISO 8601"}
    end
  end

  # NaiveDateTime.new accepts second 60 only with a leap-second-aware calendar;
  # Calendar.ISO rejects it, which matches V8's `new Date(...)` giving NaN.
  defp frac_to_micro(""), do: {0, 0}

  defp frac_to_micro("." <> digits) do
    precision = min(byte_size(digits), 6)
    padded = digits |> binary_part(0, precision) |> String.pad_trailing(6, "0")
    {String.to_integer(padded), precision}
  end

  defp apply_offset(dt, ""), do: {:ok, dt}

  defp apply_offset(dt, <<sign, hh::binary-size(2), ":", mm::binary-size(2)>>) do
    seconds = String.to_integer(hh) * 3600 + String.to_integer(mm) * 60
    shift = if sign == ?+, do: -seconds, else: seconds

    case DateTime.add(dt, shift, :second) do
      %DateTime{} = shifted -> {:ok, shifted}
    end
  rescue
    _ -> {:error, "datetime normalized to a negative time"}
  end

  @spec valid_datetime?(term) :: boolean
  def valid_datetime?(input), do: match?({:ok, _}, parse_datetime(input))

  @spec ensure_valid_datetime(String.t()) :: :ok | {:error, reason}
  def ensure_valid_datetime(input) do
    case parse_datetime(input) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Formats a `DateTime` in upstream's preferred form: millisecond precision, `Z`."
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:millisecond)
    |> Map.put(:microsecond, {elem(dt.microsecond, 0) |> div(1000) |> Kernel.*(1000), 3})
    |> DateTime.to_iso8601()
  end
end
