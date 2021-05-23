defmodule MeshxRpc.Client.Pool do
  require Logger
  alias MeshxRpc.App.{C, T}
  alias MeshxRpc.Common.{Options, Structs.Data}

  @error_prefix :error_rpc
  @error_prefix_remote :error_rpc_remote

  @request_retries_statem 5

  @opts [
    idle_reconnect: [
      type: :timeout,
      default: 600_000,
      doc: """
      after RPC client-server connection is established or after RPC request processing, client worker enters `idle` state waiting for the next user request. `:idle_reconnect` specifies amount of idle time after which client should reestablish connection. One can think about this feature as high level TCP keep-alive/heartbeat action.
      """
    ],
    retry_idle_error: [
      type: :pos_integer,
      default: 1_000,
      doc: """
      amount of time RPC client worker should wait before reconnecting after connection failure when in idle state.
      """
    ],
    retry_hsk_fail: [
      type: :pos_integer,
      default: 5_000,
      doc: """
      amount of time RPC client worker should wait before reconnecting after handshake failure. Most common handshake failure reason probably will be inconsistent client/server configuration, for example different `:shared_key` option on client and server.
      """
    ],
    retry_proxy_fail: [
      type: :pos_integer,
      default: 1_000,
      doc: """
      amount of time RPC client worker should wait before retrying reconnect to `:address` after initial socket connection failure. If `:address` points to mesh upstream endpoint proxy address, failures here can be associated with proxy binary problem.
      """
    ],
    timeout_connect: [
      type: :timeout,
      default: 5_000,
      doc: """
      timeout used when establishing initial TCP socket connection with RPC server.
      """
    ],
    exec_retry_on_error: [
      type: {:list, :atom},
      default: [:closed, :tcp_closed],
      doc: """
      list of request processing errors on which request execution should be retried.
      """
    ]
  ]
  @moduledoc """
  RPC client workers pool.

  ## Configuration
  RPC client pool is configured with `opts` argument in `child_spec/2` function. Configuration options common to both RPC client and server are described in `MeshxRpc` "Common configuration" section.

  Configuration options specific to RPC client `opts` argument in `child_spec/2`:
  #{NimbleOptions.docs(@opts)}

  Values for options prefixed with `:retry-` and `:idle_reconnect` are randomized by `+/-10%`. Unit for time related options is millisecond.
  """

  @worker_mod MeshxRpc.Client.Worker

  @doc """
  Returns a specification to start a RPC client workers pool under a supervisor.

  `id` is a pool id which might be a name of a module implementing user RPC functions.

  `opts` are options described in "Configuration" section above and in `MeshxRpc` "Common configuration" section.

  Example:
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
      |> Map.put(:retry_idle_error, Keyword.fetch!(opts, :retry_idle_error))
      |> Map.put(:retry_hsk_fail, Keyword.fetch!(opts, :retry_hsk_fail))
      |> Map.put(:retry_proxy_fail, Keyword.fetch!(opts, :retry_proxy_fail))
      |> Map.put(:timeout_connect, Keyword.fetch!(opts, :timeout_connect))

    node_ref_mfa = Keyword.fetch!(opts, :node_ref_mfa)
    svc_ref_mfa = Keyword.get(opts, :svc_ref_mfa, id |> to_string() |> String.slice(0..255))
    conn_ref_mfa = Keyword.fetch!(opts, :conn_ref_mfa)
    gen_statem_opts = Keyword.fetch!(opts, :gen_statem_opts)

    retry_on_error = Keyword.fetch!(opts, :exec_retry_on_error)
    :persistent_term.put({C.lib(), :retry_on_error}, retry_on_error)

    {id, start, restart, shutdown, type, modules} =
      :poolboy.child_spec(id, pool_opts, [{data, node_ref_mfa, svc_ref_mfa, conn_ref_mfa}, gen_statem_opts])

    %{id: id, start: start, restart: restart, shutdown: shutdown, type: type, modules: modules}
  end

  @doc """
  Sends an asynchronous RPC cast `request` using workers `pool`.

  Function always immediately returns `:ok`, even if `pool` doesn't exist or any other error takes place.

  `args`, `timeout`, `retry` and `retry_sleep` function arguments have the same meaning as in case of `call/6`.

  Example:
  ```elixir
  iex(1)> MeshxRpc.Client.Pool.cast(NotExisting, :undefined, [])
  :ok
  ```
  """
  @spec cast(
          pool :: atom(),
          request :: atom(),
          args :: list(),
          timeout :: timeout,
          retry :: pos_integer(),
          retry_sleep :: non_neg_integer()
        ) :: :ok
  def cast(pool, request, args, timeout \\ :infinity, retry \\ 5, retry_sleep \\ 100) do
    spawn(__MODULE__, :retry_request, [pool, :cast, request, args, timeout, retry, retry_sleep])
    :ok
  end

  @doc """
  Makes a synchronous RPC call `request` using workers `pool` and waits for reply.

  If successful, `call/6` returns `Kernel.apply(RpcServerMod, request, args)` evaluation result on remote server.

  If error occurs during request processing `{:error_rpc, reason}` is returned.

  User defined RPC server functions should not return results as tuples with first tuple element being `:error_rpc` or any atom name starting with `:error_rpc` (for example `:error_rpc_remote`) as those tuples are reserved by `MeshxRpc` internally for error reporting and processing.

  Possible request processing errors:
  * `:full` - all client pool workers are busy and pool manager cannot checkout new worker,
  * `:killed` - process executing request on remote server was killed because function execution time exceeded allowed timeout (see `MeshxRpc.Server.Pool` option `:timeout_execute`),
  * `:invalid_cks` - checksum check with user provided checksum function (`:cks_mfa` option) failed,
  * `:timeout_cks` - checksum calculation timeout,
  * `:closed` - client worker received user request before handshake with server was completed,
  * `:tcp_closed` - TCP socket connection was closed,
  * `:invalid_ref` - request message failed referential integrity check,
  * `{:undef, [...]}` - request function not defined on server,
  * `:invalid_state` - server or client worker encountered inconsistent critical state,
  * any `:inet` [POSIX Error Codes](http://erlang.org/doc/man/inet.html#posix-error-codes),
  * any errors from (de)serialization function.

  If remote server does not respond within time specified by `timeout` argument, process executing RPC call is killed, the function call fails and the caller exits. Additionally connection to remote server is closed which kills corresponding RPC call process being executed on the server. Please be aware of `MeshxRpc.Server.Pool` `:timeout_execute` configuration option playing similar role to `timeout` function argument on the server side.

  If error occurs during request processing and error reason is in list defined by `:exec_retry_on_error` configuration option, request will be retried `retry` times with randomized exponential back-off starting with `retry_sleep` msec.

  Example:
  ```elixir
  iex(1)> MeshxRpc.Client.Pool.call(Example1.Client, :echo, "hello world")
  "hello world"
  iex(2)> MeshxRpc.Client.Pool.call(Example1.Client, :not_existing, "hello world")
  {:error_rpc, {:undef,  [...]}}
  """
  @spec call(
          pool :: atom(),
          request :: atom(),
          args :: list(),
          timeout :: timeout,
          retry :: pos_integer(),
          retry_sleep :: non_neg_integer()
        ) ::
          term() | {:error_rpc, reason :: term()}
  def call(pool, request, args, timeout \\ :infinity, retry \\ 5, retry_sleep \\ 100) do
    case retry_request(pool, :call, request, args, timeout, retry, retry_sleep) do
      {@error_prefix_remote, e} -> {@error_prefix, e}
      r -> r
    end
  end

  @doc """
  Same as `call/6`, will reraise remote exception locally.

  Example:
  ```elixir
  iex(1)> MeshxRpc.Client.Pool.call(Example1.Client, :raise_test, "raise kaboom!")
  {:error_rpc, %RuntimeError{message: "raise kaboom!"}}
  iex(2)> MeshxRpc.Client.Pool.call!(Example1.Client, :raise_test, "raise kaboom!")
  ** (RuntimeError) raise kaboom!
  ```
  """
  @spec call!(
          pool :: atom(),
          request :: atom(),
          args :: list(),
          timeout :: timeout,
          retry :: pos_integer(),
          retry_sleep :: non_neg_integer()
        ) ::
          term() | {:error_rpc, reason :: term()}
  def call!(pool, request, args, timeout \\ :infinity, retry \\ 5, retry_sleep \\ 100) do
    case retry_request(pool, :call, request, args, timeout, retry, retry_sleep) do
      {@error_prefix_remote, e} when is_exception(e) -> raise(e)
      {@error_prefix_remote, e} -> {@error_prefix, e}
      r -> r
    end
  end

  def retry_request(pool, req_type, request, args, timeout, retry, retry_sleep, retries \\ 0) when req_type in [:cast, :call] do
    case request(pool, req_type, request, args, timeout) do
      {err, e} when err in [@error_prefix, @error_prefix_remote] ->
        retry_on_error = :persistent_term.get({MeshxRpc.App.C.lib(), :retry_on_error})

        if e in retry_on_error and retries < retry do
          retry_sleep |> T.rand_retry() |> Process.sleep()
          retry_request(pool, req_type, request, args, timeout, retry, retry_sleep * 2, retries + 1)
        else
          {err, e}
        end

      r ->
        r
    end
  end

  defp request(pool, req_type, request, args, timeout, retries_statem \\ 0) do
    case :poolboy.checkout(pool, false) do
      pid when is_pid(pid) ->
        ref =
          if timeout == :infinity do
            nil
          else
            {:ok, ref} = :timer.kill_after(timeout, pid)
            ref
          end

        result =
          try do
            :gen_statem.call(pid, {:request, {req_type, request, args}})
          catch
            :exit, e ->
              if retries_statem < @request_retries_statem,
                do: request(pool, request, args, timeout, retries_statem + 1),
                else: exit(e)
          else
            r -> r
          end

        if !is_nil(ref), do: {:ok, :cancel} = :timer.cancel(ref)
        :poolboy.checkin(pool, pid)
        result

      :full ->
        {@error_prefix, :full}
    end
  end
end
