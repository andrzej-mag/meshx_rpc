defmodule MeshxRpc.Server.Pool do
  @moduledoc """
  RPC server pool.

  todo: Documentation will be provided at a later date.
  """

  @behaviour :ranch_protocol
  alias MeshxRpc.App.T
  alias MeshxRpc.Common.{Options, Structs.Data, Structs.Svc}

  @opts [
    timeout_execute: [
      type: :timeout,
      default: :infinity
    ]
  ]
  @worker_mod MeshxRpc.Server.Worker
  @transport :ranch_tcp

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
    :ranch.child_spec(id, @transport, pool_opts, __MODULE__, [data, gen_statem_opts])
  end

  @impl :ranch_protocol
  def start_link(_pool_id, _transport, [opts, gen_statem_opts]),
    do: {:ok, :proc_lib.spawn_link(@worker_mod, :init, [[opts, gen_statem_opts]])}
end
