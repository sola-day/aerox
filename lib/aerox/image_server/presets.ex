defmodule Aerox.ImageServer.Presets do
  @moduledoc """
  Upstream's URL shape and presets, verbatim (`bsky/src/image/uri.ts`, DESIGN §16):

      /<preset>/plain/<did>/<cid>[@<jpeg|webp>]

  The format suffix is optional and defaults per preset (webp everywhere).
  `url/4` builds the URL the views emit; upstream's `getPresetUri` emits the
  path *without* a format suffix since #4755, so we do the same.
  """

  @type format :: :jpeg | :webp
  @type fit :: :cover | :inside
  @type preset :: %{
          name: String.t(),
          format: format,
          fit: fit,
          width: pos_integer,
          height: pos_integer,
          min: boolean
        }
  @type options :: %{
          preset: String.t(),
          did: String.t(),
          cid: String.t(),
          format: format,
          fit: fit,
          width: pos_integer,
          height: pos_integer,
          min: boolean
        }

  # `min: true` means "scale up to hit the dimensions as well as down"
  # (sharp's `withoutEnlargement: false`).
  @presets %{
    "avatar" => %{format: :webp, fit: :cover, height: 1000, width: 1000, min: true},
    "banner" => %{format: :webp, fit: :cover, height: 1000, width: 3000, min: true},
    "feed_thumbnail" => %{format: :webp, fit: :inside, height: 2000, width: 2000, min: true},
    "feed_fullsize" => %{format: :webp, fit: :inside, height: 1000, width: 1000, min: true}
  }

  @names Map.keys(@presets) |> Enum.sort()

  @doc "The preset names, in upstream's order."
  def names, do: ~w(avatar banner feed_thumbnail feed_fullsize)

  @doc "The preset by name."
  @spec fetch(String.t()) :: {:ok, preset} | :error
  def fetch(name) when name in @names, do: {:ok, Map.put(@presets[name], :name, name)}
  def fetch(_), do: :error

  @doc "The formats the CDN can produce and their content types."
  def content_type(:jpeg), do: "image/jpeg"
  def content_type(:webp), do: "image/webp"

  @doc "The file extension the cache uses for a format."
  def extension(:jpeg), do: "jpeg"
  def extension(:webp), do: "webp"

  @spec parse_format(String.t()) :: {:ok, format} | :error
  def parse_format("jpeg"), do: {:ok, :jpeg}
  def parse_format("webp"), do: {:ok, :webp}
  def parse_format(_), do: :error

  # upstream: /^\/(.+?)\/plain\/(.+?)\/(.+?)(?:@(.+?))?$/
  @path_regex ~r"^/(.+?)/plain/(.+?)/(.+?)(?:@(.+?))?$"

  @doc """
  Parses a request path (relative to the `/img` mount) into resize options,
  as upstream's `ImageUriBuilder.getOptions`. The DID and CID are returned as
  given; syntactic validation is the facade's job.
  """
  @spec parse_path(String.t()) ::
          {:ok, options} | {:error, :bad_path | :bad_preset | :bad_format}
  def parse_path(path) when is_binary(path) do
    case Regex.run(@path_regex, path) do
      nil ->
        {:error, :bad_path}

      [_, preset_name, did, cid | rest] ->
        with {:ok, preset} <- fetch_preset(preset_name),
             {:ok, format} <- format_or_default(rest, preset) do
          {:ok,
           preset
           |> Map.delete(:name)
           |> Map.merge(%{preset: preset_name, did: did, cid: cid, format: format})}
        end
    end
  end

  def parse_path(_), do: {:error, :bad_path}

  defp fetch_preset(name) do
    case fetch(name) do
      {:ok, preset} -> {:ok, preset}
      :error -> {:error, :bad_preset}
    end
  end

  defp format_or_default([], preset), do: {:ok, preset.format}

  defp format_or_default([fmt], _preset) do
    case parse_format(fmt) do
      {:ok, format} -> {:ok, format}
      :error -> {:error, :bad_format}
    end
  end

  @doc "The path for a preset/did/cid, as upstream's `getPath` (no format suffix)."
  @spec path(String.t(), String.t(), String.t()) :: String.t()
  def path(preset, did, cid), do: "/#{preset}/plain/#{did}/#{cid}"

  @doc """
  The URL a view emits for a blob: `<base>/<preset>/plain/<did>/<cid>`, where
  `base` is `Aerox.AppView.Config.image_url/0` (`…/img`). Raises on an
  unknown preset, as upstream's `getPresetUri`.
  """
  @spec url(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def url(base, preset, did, cid) do
    case fetch(preset) do
      {:ok, _} -> String.trim_trailing(base, "/") <> path(preset, did, cid)
      :error -> raise ArgumentError, "unrecognized image preset #{inspect(preset)}"
    end
  end
end
