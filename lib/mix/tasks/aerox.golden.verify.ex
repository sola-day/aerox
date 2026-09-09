defmodule Mix.Tasks.Aerox.Golden.Verify do
  @shortdoc "Check test/golden/ against MANIFEST.json and, when possible, against upstream"
  @moduledoc """
  VERIFICATION §2.2. Three checks:

  1. Every file under `test/golden/` has a manifest entry (a file without one
     fails), and every manifest entry has a file.
  2. Every file's sha256 equals the manifest's.
  3. For `kind: "copied"` entries, when the reading-room checkout is present
     (`AEROX_UPSTREAM_DIR`, default `../bsky`), the file is byte-identical to
     `git show <commit>:<path>` in the source repository. Pass `--upstream`
     to require this check rather than skip it when the checkout is absent.

  Never edits anything: a golden that has drifted is either an upstream change
  we must follow deliberately or a generator bug.
  """
  use Boundary, top_level?: true, deps: []
  use Mix.Task

  @golden "test/golden"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [upstream: :boolean])
    manifest = File.read!(Path.join(@golden, "MANIFEST.json")) |> Jason.decode!()
    entries = manifest["files"]

    on_disk =
      Path.wildcard(Path.join(@golden, "**/*"), match_dot: false)
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, @golden))
      |> Enum.reject(&(&1 in ["MANIFEST.json", "README.md"]))
      |> MapSet.new()

    listed = entries |> Map.keys() |> MapSet.new()

    errors =
      Enum.map(MapSet.difference(on_disk, listed), &"not in manifest: #{&1}") ++
        Enum.map(MapSet.difference(listed, on_disk), &"missing file: #{&1}") ++
        Enum.flat_map(entries, fn {path, entry} -> check_entry(path, entry, opts) end)

    case errors do
      [] ->
        Mix.shell().info("golden corpus ok: #{map_size(entries)} files verified")

      errors ->
        Enum.each(errors, &Mix.shell().error(&1))
        Mix.raise("#{length(errors)} golden corpus problem(s)")
    end
  end

  defp check_entry(path, entry, opts) do
    full = Path.join(@golden, path)

    with {:ok, bytes} <- File.read(full) do
      actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      hash_errors =
        if actual == entry["sha256"], do: [], else: ["sha256 mismatch: #{path}"]

      hash_errors ++ check_upstream(path, entry, bytes, opts)
    else
      _ -> []
    end
  end

  defp check_upstream(path, %{"kind" => "copied", "source" => src}, bytes, opts) do
    dir = Path.join(System.get_env("AEROX_UPSTREAM_DIR", "../bsky"), src["repo"])

    cond do
      File.dir?(dir) ->
        case System.cmd("git", ["-C", dir, "show", "#{src["commit"]}:#{src["path"]}"],
               stderr_to_stdout: true
             ) do
          {^bytes, 0} -> []
          {_, 0} -> ["upstream drift: #{path} differs from #{src["repo"]}@#{src["commit"]}"]
          {out, _} -> ["upstream lookup failed for #{path}: #{String.trim(out)}"]
        end

      opts[:upstream] ->
        ["upstream checkout missing for #{path}: #{dir}"]

      true ->
        []
    end
  end

  defp check_upstream(_path, _entry, _bytes, _opts), do: []
end
