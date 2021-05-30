defmodule MeshxRpc.Server.Pool do
  # @behaviour :ranch_protocol
  alias MeshxRpc.App.T
  alias MeshxRpc.Common.{Options, Structs.Data, Structs.Svc}

  @opts [
    timeout_execute: [
      type: :timeout,
      default: :infinity,
      doc: """
      request function execution timeout, milliseconds. If timeout is exceeded request function is killed and remote RPC client call will error with: `{:error_rpc, :killed}`.
      """
    ]
  ]
  @worker_mod MeshxRpc.Server.Worker
  @transport :ranch_tcp

  @moduledoc """
  RPC server workers pool.

  ## Configuration
  RPC server pool is configured with `opts` argument in `child_spec/2` function. Configuration options common to both RPC client and server are described in `MeshxRpc` "Common configuration" section.

  Configuration options specific to RPC server `opts` argument in `child_spec/2`:
  #{NimbleOptions.docs(@opts)}
  """

  @doc """
  Returns a specification to start a RPC server workers pool under a supervisor.

  `id` is a pool id which should be a name of a module implementing user RPC functions.

  `opts` are options described in "Configuration" section above and in `MeshxRpc` "Common configuration" section.
  ```elixir
  iex(1)> MeshxRpc.Server.Pool.child_spec(Example1.Server, address: {:uds, "/tmp/meshx.sock"})
  %{
    id: {:ranch_embedded_sup, Example1.Server},
    start: {:ranch_embedded_sup, :start_link,
     [
       Example1.Server,
       :ranch_tcp,
       %{socket_opts: [ip: {:local, "/tmp/meshx.sock"}, port: 0]},
       MeshxRpc.Server.Pool,
       [
         ...
       ]
     ]},
    type: :supervisor
  }
  ```
  """
  @spec child_spec(id :: atom(), opts :: Keyword.t()) :: Supervisor.child_spec()
  def child_spec(id, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @opts ++ Options.common())
    node_ref_mfa = Keyword.fetch!(opts, :node_ref_mfa)
    svc_ref_mfa = Keyword.get(opts, :svc_ref_mfa, id |> to_string() |> String.slice(0..255))
    conn_ref_mfa = Keyword.fetch!(opts, :conn_ref_mfa)

    data =
      Data.init(id, opts)
      |> Map.put(:transport, @transport)
      |> Map.put(:timeout_execute, Keyword.fetch!(opts, :timeout_execute))
      |> Map.replace(:local, Svc.init(node_ref_mfa, svc_ref_mfa, conn_ref_mfa))

    {_type, ip, port} = Map.fetch!(data, :address)
    pool_opts = T.merge_improper_keyword([ip: ip, port: port], Keyword.fetch!(opts, :pool_opts))
    gen_statem_opts = Keyword.fetch!(opts, :gen_statem_opts)

    case :ranch.child_spec(id, @transport, pool_opts, __MODULE__, [data, gen_statem_opts]) do
      chi when is_map(chi) ->
        chi

      {id, start, restart, shutdown, type, modules} ->
        %{id: id, start: start, restart: restart, shutdown: shutdown, type: type, modules: modules}
    end
  end

  # start_link/3 compatible with :ranch 2.0
  # @impl :ranch_protocol
  def start_link(_pool_id, _transport, [opts, gen_statem_opts]),
    do: {:ok, :proc_lib.spawn_link(@worker_mod, :init, [[opts, gen_statem_opts]])}

  # start_link/4 compatible with :ranch 1.8.0
  # @impl :ranch_protocol
  def start_link(_pool_id, _socket, _transport, [opts, gen_statem_opts]),
    do: {:ok, :proc_lib.spawn_link(@worker_mod, :init, [[opts, gen_statem_opts]])}
end
