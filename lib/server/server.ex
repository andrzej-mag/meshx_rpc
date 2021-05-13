defmodule MeshxRpc.Server do
  @moduledoc """
  Syntactic sugar on top of MeshxRpc.Server.Pool.

  todo: Documentation will be provided at a later date.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @opts opts
      @pool_mod MeshxRpc.Server.Pool

      def child_spec(arg_opts \\ []) do
        opts = Keyword.merge(@opts, arg_opts)
        @pool_mod.child_spec(__MODULE__, opts)
      end
    end
  end

  @optional_callbacks child_spec: 1
  @callback child_spec(arg_opts :: list()) :: Supervisor.child_spec()
end
