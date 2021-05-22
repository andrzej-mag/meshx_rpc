defmodule MeshxRpc.Client do
  @moduledoc """
  Convenience module on top of `MeshxRpc.Client.Pool`.

  Module leverages `Kernel.use/2` macro to simplify user interaction with `MeshxRpc.Client.Pool` module:
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

      def cast(request, args \\ [], timeout \\ :infinity, retry \\ 5, retry_sleep \\ 100),
        do: @pool_mod.cast(__MODULE__, request, args, timeout, retry, retry_sleep)

      def call(request, args \\ [], timeout \\ :infinity, retry \\ 5, retry_sleep \\ 100),
        do: @pool_mod.call(__MODULE__, request, args, timeout, retry, retry_sleep)

      def call!(request, args \\ [], timeout \\ :infinity, retry \\ 5, retry_sleep \\ 100),
        do: @pool_mod.call!(__MODULE__, request, args, timeout, retry, retry_sleep)
    end
  end

  @optional_callbacks child_spec: 1, cast: 5, call: 5, call!: 5

  @doc """
  Returns a specification to start a RPC client workers pool under a supervisor.
  """
  @callback child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()

  @doc """
  Sends an asynchronous RPC cast `request` to the server.
  """
  @callback cast(
              request :: atom(),
              args :: list(),
              timeout :: timeout(),
              retry :: pos_integer(),
              retry_sleep :: non_neg_integer()
            ) ::
              :ok

  @doc """
  Makes a synchronous RPC call `request` to the server and waits for its reply.
  """
  @callback call(
              request :: atom(),
              args :: list(),
              timeout :: timeout(),
              retry :: pos_integer(),
              retry_sleep :: non_neg_integer()
            ) ::
              term() | {:error_rpc, reason :: term()}

  @doc """
  Same as `c:call/5`, will reraise remote exception locally.
  """
  @callback call!(
              request :: atom(),
              args :: list(),
              timeout :: timeout(),
              retry :: pos_integer(),
              retry_sleep :: non_neg_integer()
            ) ::
              term() | {:error_rpc, reason :: term()}
end
