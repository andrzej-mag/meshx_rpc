defmodule MeshxRpc.Client do
  @moduledoc """
  Syntactic sugar on top of MeshxRpc.Client.Pool.

  todo: Documentation will be provided at a later date.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @opts opts
      @pool_mod MeshxRpc.Client.Pool

      def child_spec(arg_opts \\ []) do
        opts = Keyword.merge(@opts, arg_opts)
        @pool_mod.child_spec(__MODULE__, opts)
      end

      def cast(fun, args \\ [], timeout \\ :infinity), do: @pool_mod.cast(__MODULE__, fun, args, timeout)
      def call(fun, args \\ [], timeout \\ :infinity), do: @pool_mod.call(__MODULE__, fun, args, timeout)
      def call!(fun, args \\ [], timeout \\ :infinity), do: @pool_mod.call!(__MODULE__, fun, args, timeout)
    end
  end

  @optional_callbacks child_spec: 1, cast: 3, call: 3, call!: 3
  @callback child_spec(arg_opts :: list()) :: Supervisor.child_spec()
  @callback cast(fun :: atom(), args :: list(), timeout :: pos_integer() | :infinity) :: term()
  @callback call(fun :: atom(), args :: list(), timeout :: pos_integer() | :infinity) :: term()
  @callback call!(fun :: atom(), args :: list(), timeout :: pos_integer() | :infinity) :: term()
end
