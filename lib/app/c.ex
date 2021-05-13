defmodule MeshxRpc.App.C do
  @moduledoc false

  @lib Mix.Project.config() |> Keyword.fetch!(:app)

  def lib, do: @lib
end
