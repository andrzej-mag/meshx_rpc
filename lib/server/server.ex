defmodule MeshxRpc.Server do
  @moduledoc """
  Convenience module on top of `MeshxRpc.Server.Pool`.

  Module leverages `Kernel.use/2` macro to simplify user interaction with `MeshxRpc.Server.Pool` module:
    * current module name is used as pool id,
    * pool options can be specified with `use/2` clause.

  Please refer to `MeshxRpc.Server.Pool` documentation for details.

  Example RPC server module:
  ```elixir
  # lib/server.ex
  defmodule Example1.Server do
    use MeshxRpc.Server,
      address: {:tcp, {127, 0, 0, 1}, 12_345},
      telemetry_prefix: [:example1, __MODULE__],
      timeout_execute: 15_000

    def echo(args), do: call(:echo, args)
    def raise_test(args), do: raise(args)
  end
  ```

  Start with application supervisor:
  ```elixir
  # lib/example1/application.ex
  def start(_type, _args) do
    Supervisor.start_link([Example1.Server],
      strategy: :one_for_one,
      name: Example1.Supervisor
    )
  end
  ```
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

  @doc """
  Returns a specification to start a RPC server workers pool under a supervisor.
  """
  @callback child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
end
