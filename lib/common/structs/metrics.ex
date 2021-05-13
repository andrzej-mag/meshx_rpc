defmodule MeshxRpc.Common.Structs.Metrics do
  @moduledoc false
  defstruct time: %{hsk: 0, idle: 0, send: 0, recv: 0, exec: 0, ser: 0, dser: 0},
            size: %{send: 0, recv: 0},
            blocks: %{send: 0, recv: 0}
end
