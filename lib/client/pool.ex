defmodule MeshxRpc.Client.Pool do
  require Logger
  alias MeshxRpc.Common.{Options, Structs.Data}

  @opts [
    idle_reconnect: [
      type: :timeout,
      default: 600_000,
      doc: """
      After RPC client-server connection is established or after RPC request processing client worker enters `idle` state waiting for the next user request. `:idle_reconnect` specifies amount of idle time after which client should reestablish connection. One can think about this feature as high level TCP keep-alive/heartbeat action.
      """
    ],
    retry_error: [
      type: :pos_integer,
      default: 1_000,
      doc: """
      Amount of time RPC client worker should wait before reconnecting after connection failure when in idle state.
      """
    ],
    retry_hsk_fail: [
      type: :pos_integer,
      default: 5_000,
      doc: """
      Amount of time RPC client worker should wait before reconnecting after handshake failure. Most common handshake failure reason probably will be inconsistent client/server configuration, for example different `:shared_key` option on client and server.
      """
    ],
    retry_proxy_fail: [
      type: :pos_integer,
      default: 1_000,
      doc: """
      Amount of time RPC client worker should wait before retrying reconnect to `:address` after initial socket connection failure. If `:address` points to mesh upstream endpoint proxy address, failures here can be associated with proxy binary problem.
      """
    ],
    timeout_connect: [
      type: :timeout,
      default: 5_000,
      doc: """
      Timeout used when establishing initial TCP socket connection with RPC server.
      """
    ]
  ]
  @moduledoc """
  RPC client workers pool.

  ## Configuration
  RPC client pool is configured when starting child defined by `child_spec/2`. Configuration options common to both RPC client and server are described in `MeshxRpc` **Common configuration** section.

  `MeshxRpc.Client.Pool.child_spec/2` configuration options:
  #{NimbleOptions.docs(@opts)}

  Values for options prefixed with `:retry-` and `:idle_reconnect` are randomized by `+/-10%`. Unit for time related options is millisecond.
  """

  @worker_mod MeshxRpc.Client.Worker

  @doc """
  Returns a specification to start a RPC client workers pool under a supervisor.

  `id` is a pool id which might be a name of a module implementing user RPC functions.

  `opts` are options described in **Configuration** section above and in `MeshxRpc` **Common configuration** section.
  ```elixir
  iex(1)> MeshxRpc.Client.Pool.child_spec(Example1.Client, address: {:uds, "/tmp/meshx.sock"})
  {Example1.Client,
   {:poolboy, :start_link,
    [
      [
        name: {:local, Example1.Client},
        worker_module: MeshxRpc.Client.Worker
      ],
      [
        ...
      ]
    ]}, :permanent, 5000, :worker, [:poolboy]}
  ```
  """
  @spec child_spec(id :: atom() | String.t(), opts :: Keyword.t()) :: :supervisor.child_spec()
  def child_spec(id, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @opts ++ Options.common())

    pool_opts =
      Keyword.fetch!(opts, :pool_opts)
      |> Keyword.put_new(:worker_module, @worker_mod)
      |> Keyword.put_new(:name, {:local, id})

    data =
      Data.init(id, opts)
      |> Map.put(:idle_reconnect, Keyword.fetch!(opts, :idle_reconnect))
      |> Map.put(:retry_error, Keyword.fetch!(opts, :retry_error))
      |> Map.put(:retry_hsk_fail, Keyword.fetch!(opts, :retry_hsk_fail))
      |> Map.put(:retry_proxy_fail, Keyword.fetch!(opts, :retry_proxy_fail))
      |> Map.put(:timeout_connect, Keyword.fetch!(opts, :timeout_connect))

    node_ref_mfa = Keyword.fetch!(opts, :node_ref_mfa)
    svc_ref_mfa = Keyword.get(opts, :svc_ref_mfa, id |> to_string() |> String.slice(0..255))
    conn_ref_mfa = Keyword.fetch!(opts, :conn_ref_mfa)
    gen_statem_opts = Keyword.fetch!(opts, :gen_statem_opts)

    :poolboy.child_spec(id, pool_opts, [{data, node_ref_mfa, svc_ref_mfa, conn_ref_mfa}, gen_statem_opts])
  end

  @doc """
  Executes on client `pool` RPC `fun` asynchronous cast with `args` arguments.

  Function always immediately returns `:ok`, even if `pool` or `fun` do not exist or all pool workers are busy.

  `MeshxRpc` workers are pool checked persistent TCP connections. When user runs new `cast` request, first step is to asynchronously checkout new worker from pool manager and then make request using that worker. Client worker due to non-multiplexed connection persistence must wait for server counterpart to acknowledge request execution completion. If acknowledgment is not received in specified by `timeout` time, asynchronous process executing request is killed and given connection to server is closed. User doesn't receive any notifications about timeout error.
  ```elixir
  iex(1)> MeshxRpc.Client.Pool.cast(NotExisting, :undefined, [])
  :ok
  ```
  """
  @spec cast(pool :: atom(), fun :: atom(), args :: list(), timeout :: timeout) :: :ok
  def cast(pool, fun, args, timeout \\ :infinity) when is_integer(timeout) or timeout == :infinity do
    spawn(fn ->
      pid = :poolboy.checkout(pool, false)

      if is_pid(pid) do
        ref =
          if timeout == :infinity do
            nil
          else
            {:ok, ref} = :timer.kill_after(timeout, pid)
            ref
          end

        :gen_statem.call(pid, {:request, {:cast, fun, args}})
        if !is_nil(ref), do: {:ok, :cancel} = :timer.cancel(ref)
        :poolboy.checkin(pool, pid)
        :ok
      else
        Logger.warn("Function #{fun} not casted.")
      end
    end)

    :ok
  end

  @doc """
  Executes on client `pool` RPC `fun` synchronous call with `args` arguments.

  If successful `call/4` returns result of remote function evaluation with `Kernel.apply/3`.

  If pool manager cannot checkout new worker to process user request it returns `:full`.

  If failure occurs on server side function returns `{:error_remote, reason}`.

  If user provided checksum function (`:cks_mfa` option) check fails, function will return: `{:error_remote, :invalid_cks}` if check failed on server or `{:error, :invalid_cks}` if failure was local. If checksum calculation timeouts: `{:error_remote, :timeout_cks}` or `{:error, :timeout_cks}`.

  If request message fails referential integrity check: `{:error_remote, :invalid_ref}` or `{:error, :invalid_ref}`.

  If server or client connection worker encounters inconsistent critical state: `{:error_remote, :invalid_state}` or `{:error, :invalid_state}` respectively.

  Additionally errors from (de-)serialization functions will be reported.

  If remote server does not respond within time specified by `timeout`, process executing RPC call is killed, the function call fails and the caller exits. Additionally connection to remote server is closed which kills corresponding RPC call process being executed on server. Please be aware of `MeshxRpc.Server.Pool` `:timeout_execute` configuration option playing similar role on the server side.

  ```elixir
  iex(1)> MeshxRpc.Client.Pool.call(Example1.Client, :echo, "hello world")
  "hello world"
  iex(2)> MeshxRpc.Client.Pool.call(Example1.Client, :not_existing, "hello world")
  {:error_remote,
   {:undef,
    [
      {Example1.Server, :not_existing, ["hello world"], []},
      {MeshxRpc.Server.Worker, :"-exec/3-fun-1-", 2,
       [file: 'lib/server/worker.ex', line: 188]}
    ]}}
  """
  @spec call(pool :: atom(), fun :: atom(), args :: list(), timeout :: timeout) ::
          term() | {:error_remote, reason :: term()} | :full
  def call(pool, fun, args, timeout \\ :infinity) when is_integer(timeout) or timeout == :infinity do
    case :poolboy.checkout(pool, false) do
      pid when is_pid(pid) ->
        ref =
          if timeout == :infinity do
            nil
          else
            {:ok, ref} = :timer.kill_after(timeout, pid)
            ref
          end

        result = :gen_statem.call(pid, {:request, {:call, fun, args}})
        if !is_nil(ref), do: {:ok, :cancel} = :timer.cancel(ref)
        :poolboy.checkin(pool, pid)
        result

      r ->
        r
    end
  end

  @doc """
  Same as `call/4`, will reraise remote server function execution exception locally.
  ```elixir
  iex(1)> MeshxRpc.Client.Pool.call(Example1.Client, :raise_test, "raise boom!")
  {:error_remote, %RuntimeError{message: "raise boom!"}}
  iex(2)> MeshxRpc.Client.Pool.call!(Example1.Client, :raise_test, "raise boom!")
  ** (RuntimeError) raise boom!
      (meshx_rpc 0.1.0-dev) lib/client/pool.ex:121: MeshxRpc.Client.Pool.call!/4
  ```
  """
  @spec call!(pool :: atom(), fun :: atom(), args :: list(), timeout :: timeout) ::
          term() | {:error_remote, reason :: term()} | :full
  def call!(pool, fun, args, timeout \\ :infinity) when is_integer(timeout) or timeout == :infinity do
    case :poolboy.checkout(pool, false) do
      pid when is_pid(pid) ->
        ref =
          if timeout == :infinity do
            nil
          else
            {:ok, ref} = :timer.kill_after(timeout, pid)
            ref
          end

        result = :gen_statem.call(pid, {:request, {:call, fun, args}})
        if !is_nil(ref), do: {:ok, :cancel} = :timer.cancel(ref)
        :poolboy.checkin(pool, pid)

        case result do
          {:error_remote, e} when is_exception(e) -> raise(e)
          r -> r
        end

      r ->
        r
    end
  end
end
