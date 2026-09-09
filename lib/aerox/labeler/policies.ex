defmodule Aerox.Labeler.Policies do
  @moduledoc """
  The label values aerox's labeler declares and their definitions: the
  `policies` of its `app.bsky.labeler.service` record (DESIGN §17.1), which
  the AppView's plugin 11 reads for severity, blur and default setting.
  """

  @values ["spam", "rude", "!hide"]

  def default_values, do: @values

  @doc "The `app.bsky.labeler.defs#labelerPolicies` value."
  def policies(values \\ @values) do
    %{
      "labelValues" => values,
      "labelValueDefinitions" => values |> Enum.map(&definition/1) |> Enum.reject(&is_nil/1)
    }
  end

  @doc "The `app.bsky.labeler.service` record body."
  def service_record(values \\ @values, created_at \\ DateTime.utc_now()) do
    %{
      "$type" => "app.bsky.labeler.service",
      "policies" => policies(values),
      "createdAt" => Aerox.ATProto.Syntax.format_datetime(created_at)
    }
  end

  # Global (`!`-prefixed) values are defined by the protocol, not the labeler.
  defp definition("!" <> _), do: nil

  defp definition("spam") do
    %{
      "identifier" => "spam",
      "severity" => "inform",
      "blurs" => "content",
      "defaultSetting" => "hide",
      "locales" => [
        %{
          "lang" => "en",
          "name" => "Spam",
          "description" => "Unwanted promotion, repetitive posting or engagement farming."
        }
      ]
    }
  end

  defp definition("rude") do
    %{
      "identifier" => "rude",
      "severity" => "alert",
      "blurs" => "content",
      "defaultSetting" => "warn",
      "locales" => [
        %{
          "lang" => "en",
          "name" => "Rude",
          "description" => "Insulting or hostile towards other people."
        }
      ]
    }
  end

  defp definition(value) do
    %{
      "identifier" => value,
      "severity" => "inform",
      "blurs" => "none",
      "defaultSetting" => "warn",
      "locales" => [%{"lang" => "en", "name" => value, "description" => value}]
    }
  end
end
