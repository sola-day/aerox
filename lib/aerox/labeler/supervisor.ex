defmodule Aerox.Labeler.Supervisor do
  @moduledoc """
  The Labeler service's children beyond its repo and identity cache
  (DESIGN §17, §21.9): the label sequencer. Started after the repo by
  `Aerox.Application.children_for(:labeler)`.
  """
  def children, do: [Aerox.Labeler.Sequencer]
end
