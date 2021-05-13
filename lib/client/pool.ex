defmodule MeshxRpc.Client.Pool do
  @moduledoc """
  RPC client pool.

  todo: Documentation will be provided at a later date.
  """

  require Logger
  alias MeshxRpc.Common.{Options, Structs.Data}

  @opts [
    idle_reconnect: [
      type: :timeout,
      default: 600_000
    ],
    retry_error: [
      type: :pos_integer,
      default: 1_000
    ],
    retry_hsk_fail: [
      type: :pos_integer,
      default: 5_000
    ],
    retry_proxy_fail: [
      type: :pos_integer,
      default: 1_000
    ],
    timeout_connect: [
      type: :timeout,
      default: 5_000
    ]
  ]
  @worker_mod MeshxRpc.Client.Worker

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
