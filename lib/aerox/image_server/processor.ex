defmodule Aerox.ImageServer.Processor do
  @moduledoc """
  Resize + re-encode with libvips through `vix` (DESIGN §16, the deliberate
  §3.9 exception), transcribing upstream's `sharp.ts`:

  * `fit: :cover` scales to fill `width`×`height` and centre-crops;
    `fit: :inside` scales to fit within them. With `min: true` (every preset)
    small sources are scaled *up* as well (sharp's `withoutEnlargement: false`),
    which is libvips' `thumbnail` with `size: :VIPS_SIZE_BOTH`.
  * EXIF orientation is applied, then every piece of metadata is dropped
    (`keep: none`); output is JPEG or WebP at `quality` (upstream: 100).
  * Decompression bombs: the source is refused above `max_source_bytes` before
    decoding, and above `max_pixels` after reading only the header.
  * Concurrency is bounded by `Aerox.ImageServer.Semaphore`.

  Config, under `config :aerox, Aerox.ImageServer`: `max_source_bytes`
  (default 20 MB), `max_pixels` (default 50 M), `quality` (default 100).
  """

  alias Aerox.ImageServer.{Presets, Semaphore}
  alias Vix.Vips.{Image, Operation}

  @default_max_source_bytes 20 * 1024 * 1024
  @default_max_pixels 50_000_000
  @default_quality 100

  @type opts :: %{
          required(:width) => pos_integer,
          required(:height) => pos_integer,
          required(:fit) => Presets.fit(),
          required(:format) => Presets.format(),
          optional(:min) => boolean
        }

  @doc """
  Processes `source` (any format libvips decodes) per `opts`. Returns the
  encoded bytes. Errors: `:too_large`, `:too_many_pixels`, `:not_an_image`,
  `:busy`, or `{:vips, reason}`.
  """
  @spec process(binary, opts) :: {:ok, binary} | {:error, term}
  def process(source, opts) when is_binary(source) do
    max_bytes = config(:max_source_bytes, @default_max_source_bytes)

    if byte_size(source) > max_bytes do
      {:error, :too_large}
    else
      Semaphore.run(fn -> do_process(source, opts) end)
    end
  end

  @doc "Runs the pipeline without the semaphore (the semaphore calls this)."
  def do_process(source, opts) do
    with :ok <- check_pixels(source),
         {:ok, image} <- thumbnail(source, opts) do
      encode(image, opts.format)
    end
  end

  # Reading the header is lazy in libvips: no pixel data is decoded yet.
  defp check_pixels(source) do
    case Image.new_from_buffer(source) do
      {:ok, header} ->
        pixels = Image.width(header) * Image.height(header)

        if pixels > config(:max_pixels, @default_max_pixels),
          do: {:error, :too_many_pixels},
          else: :ok

      {:error, _} ->
        {:error, :not_an_image}
    end
  end

  defp thumbnail(source, %{width: w, height: h, fit: fit} = opts) do
    size = if Map.get(opts, :min, false), do: :VIPS_SIZE_BOTH, else: :VIPS_SIZE_DOWN
    crop = if fit == :cover, do: :VIPS_INTERESTING_CENTRE, else: :VIPS_INTERESTING_NONE

    case Operation.thumbnail_buffer(source, w, height: h, size: size, crop: crop) do
      {:ok, image} -> {:ok, image}
      {:error, reason} -> {:error, {:vips, reason}}
    end
  end

  defp encode(image, :jpeg) do
    wrap(Operation.jpegsave_buffer(image, Q: quality(), keep: [:VIPS_FOREIGN_KEEP_NONE]))
  end

  defp encode(image, :webp) do
    wrap(Operation.webpsave_buffer(image, Q: quality(), keep: [:VIPS_FOREIGN_KEEP_NONE]))
  end

  defp wrap({:ok, bin}), do: {:ok, bin}
  defp wrap({:error, reason}), do: {:error, {:vips, reason}}

  @doc "Width, height and libvips loader name of an encoded image (tests, diagnostics)."
  @spec info(binary) ::
          {:ok, %{width: pos_integer, height: pos_integer, loader: String.t()}} | {:error, term}
  def info(bin) do
    with {:ok, image} <- Image.new_from_buffer(bin) do
      loader =
        case Image.header_value_as_string(image, "vips-loader") do
          {:ok, l} -> l
          _ -> "unknown"
        end

      {:ok, %{width: Image.width(image), height: Image.height(image), loader: loader}}
    end
  end

  defp quality, do: config(:quality, @default_quality)

  defp config(key, default),
    do: Keyword.get(Application.get_env(:aerox, Aerox.ImageServer, []), key, default)
end
