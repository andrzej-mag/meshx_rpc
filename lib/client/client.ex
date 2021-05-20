defmodule MeshxRpc.Client do
  @moduledoc """
  Convenience module on top of `MeshxRpc.Client.Pool`.

  Module leverages `Kernel.use/2` to simplify user interaction with `MeshxRpc.Client.Pool` module:
    * current module name is used as pool id,
    * pool options can be specified with `use/2` clause.

  Please refer to `MeshxRpc.Client.Pool` documentation for details.

  Example RPC client module:
  ```elixir
  # lib/client.ex
  defmodule Example1.Client do
    use MeshxRpc.Client,
      address: {:tcp, {127, 0, 0, 1}, 12_345},
      telemetry_prefix: [:example1, __MODULE__],
      pool_opts: [size: 20, max_overflow: 5],
      idle_reconnect: 60 * 60 * 1000

    def echo(args), do: call(:echo, args)
  end
  ```

  Start with application supervisor:
  ```elixir
  # lib/example1/application.ex
  def start(_type, _args) do
    Supervisor.start_link([Example1.Client],
      strategy: :one_for_one,
      name: Example1.Supervisor
    )
  end
  ```

  Run RPC calls:
  ```elixir
  iex(1)> Example1.Client.echo("hello world")
  "hello world"
  iex(2)> Example1.Client.call(:echo, "hello world")
  "hello world"
  iex(3)> MeshxRpc.Client.Pool.call(Example1.Client, :echo, "hello world")
  "hello world"
  ```
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

  @doc """
  Returns a specification to start a RPC client workers pool under a supervisor.
  """
  @callback child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()

  @doc """
  Executes RPC `fun` asynchronous cast with `args` arguments.
  """
  @callback cast(fun :: atom(), args :: list(), timeout :: timeout) :: :ok

  @doc """
  Executes `fun` synchronous call with `args` arguments.
  """
  @callback call(fun :: atom(), args :: list(), timeout :: timeout) ::
              term() | {:error_remote, reason :: term()} | :full
  @doc """
  Same as `c:call/3`, will reraise remote server function execution exception locally.
  """
  @callback call!(fun :: atom(), args :: list(), timeout :: timeout) ::
              term() | {:error_remote, reason :: term()} | :full
end
