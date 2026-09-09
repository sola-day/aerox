defmodule Aerox.ImageServer.ProcessorTest do
  @moduledoc "DESIGN §16: sharp.ts resize semantics on libvips, metadata stripping, bomb limits."
  use Aerox.ImageServerCase, async: false

  alias Aerox.ImageServer.{Presets, Processor}

  defp preset(name, format \\ :webp) do
    {:ok, p} = Presets.fetch(name)
    p |> Map.delete(:name) |> Map.put(:format, format)
  end

  defp process!(source, opts) do
    assert {:ok, bytes} = Processor.process(source, opts)
    assert {:ok, info} = Processor.info(bytes)
    info
  end

  test "avatar: cover 1000x1000 crops to a square and scales small sources up (min: true)" do
    assert %{width: 1000, height: 1000, loader: "webpload_buffer"} =
             process!(png(300, 200), preset("avatar"))

    assert %{width: 1000, height: 1000} = process!(png(4000, 3000), preset("avatar"))
  end

  test "banner: cover 3000x1000" do
    assert %{width: 3000, height: 1000} = process!(png(600, 400), preset("banner"))
  end

  test "feed_fullsize: inside 1000x1000 keeps the aspect ratio, scaling up or down" do
    assert %{width: 1000, height: 667} = process!(png(300, 200), preset("feed_fullsize"))
    assert %{width: 500, height: 1000} = process!(png(2000, 4000), preset("feed_fullsize"))
  end

  test "feed_thumbnail: inside 2000x2000" do
    assert %{width: 2000, height: 1000} = process!(png(400, 200), preset("feed_thumbnail"))
  end

  test "without min, small sources are not enlarged (sharp withoutEnlargement)" do
    assert %{width: 300, height: 200} =
             process!(png(300, 200), Map.put(preset("feed_fullsize"), :min, false))
  end

  test "jpeg output, EXIF orientation applied and every metadata field dropped" do
    # 300x200 tagged "rotate 90 CW" is a 200x300 picture
    source = jpeg(300, 200, 6)
    assert {:ok, bytes} = Processor.process(source, preset("feed_fullsize", :jpeg))
    assert {:ok, %{width: 667, height: 1000, loader: "jpegload_buffer"}} = Processor.info(bytes)
    assert {:ok, image} = Vix.Vips.Image.new_from_buffer(bytes)
    {:ok, fields} = Vix.Vips.Image.header_field_names(image)
    refute Enum.any?(fields, &String.starts_with?(&1, "exif-"))
    refute "orientation" in fields
    refute "icc-profile-data" in fields
  end

  test "sources that are not images fail cleanly" do
    assert {:error, :not_an_image} = Processor.process("<html>nope</html>", preset("avatar"))
    assert {:error, :not_an_image} = Processor.process(<<>>, preset("avatar"))
  end

  test "decompression-bomb limits: bytes and pixels" do
    put_config(Aerox.ImageServer, max_source_bytes: 100)
    assert {:error, :too_large} = Processor.process(png(300, 200), preset("avatar"))

    put_config(Aerox.ImageServer, max_source_bytes: 20_000_000, max_pixels: 10_000)
    assert {:error, :too_many_pixels} = Processor.process(png(300, 200), preset("avatar"))
    assert {:ok, _} = Processor.process(png(50, 50), preset("avatar"))
  end

  test "processing is bounded by the semaphore and slots are released" do
    assert %{in_use: 0} = Aerox.ImageServer.Semaphore.stats()

    results =
      1..8
      |> Task.async_stream(fn _ -> Processor.process(png(800, 600), preset("avatar")) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert %{in_use: 0, waiting: 0} = Aerox.ImageServer.Semaphore.stats()
  end

  test "a holder that dies releases its slot" do
    sem = start_supervised!({Aerox.ImageServer.Semaphore, name: :sem_test, limit: 1})
    parent = self()

    pid =
      spawn(fn ->
        :ok = Aerox.ImageServer.Semaphore.acquire(:sem_test)
        send(parent, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    assert {:error, :busy} = Aerox.ImageServer.Semaphore.acquire(:sem_test, 50)
    Process.exit(pid, :kill)
    assert :ok = Aerox.ImageServer.Semaphore.acquire(:sem_test, 1_000)
    assert %{in_use: 1, waiting: 0} = Aerox.ImageServer.Semaphore.stats(:sem_test)
    Aerox.ImageServer.Semaphore.release(:sem_test)
    assert Process.alive?(sem)
  end
end
