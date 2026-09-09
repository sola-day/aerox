defmodule Aerox.ATProto.Lexicon.Vendored do
  @moduledoc """
  The compile-time default registry (DESIGN §6.1, §6.2): every JSON file
  under `priv/lexicons/` embedded as Elixir terms. Each file is an
  `@external_resource`, so editing or re-vendoring one recompiles this
  module and nothing else; cross-file refs resolve at runtime through the
  registry, never at compile time.
  """
  alias Aerox.ATProto.Lexicon.Registry

  @dir Path.expand("../../../../priv/lexicons", __DIR__)
  @files @dir
         |> Path.join("**/*.json")
         |> Path.wildcard()
         |> Enum.reject(&String.ends_with?(&1, "SOURCE.json"))
         |> Enum.sort()

  for file <- @files, do: @external_resource(file)

  @docs Enum.map(@files, &Jason.decode!(File.read!(&1)))
  @registry Registry.new!(@docs)

  @doc "The vendored registry."
  @spec registry() :: Registry.t()
  def registry, do: @registry

  @doc "The raw documents, in path order."
  @spec docs() :: [map]
  def docs, do: @docs

  @doc "Where the documents came from, per `priv/lexicons/SOURCE.json`."
  @spec source() :: map
  def source, do: Jason.decode!(File.read!(Path.join(@dir, "SOURCE.json")))
end
