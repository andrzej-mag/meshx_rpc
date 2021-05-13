defmodule MeshxRpc.Common.Structs.Data do
  @moduledoc false
  alias MeshxRpc.{App.C, App.T}
  alias MeshxRpc.Common.Structs.{Metrics, Svc}

  @time_unit :microsecond
  @socket_opts [mode: :binary, packet: 2, active: :once]

  defstruct [
    :address,
    :blk_max_size,
    :cks_bin,
    :cks_mfa,
    :fun_name,
    :fun_req,
    :hsk_dgt_mfa,
    :hsk_ref,
    :idle_reconnect,
    :pool_id,
    :quiet_on_hsk_error?,
    :reply_to,
    :result,
    :req_ref,
    :req_seq,
    :retry_hsk_fail,
    :retry_proxy_fail,
    :retry_error,
    :serialize_mfa,
    :shared_key,
    :socket,
    :socket_opts,
    :telemetry_prefix,
    :telemetry_result,
    :timeout_cks,
    :timeout_connect,
    :timeout_execute,
    :timeout_hsk,
    :transport,
    dta: [],
    local: %Svc{},
    metrics: %Metrics{},
    remote: %Svc{},
    state: :init,
    workers: []
  ]

  def init(pool_id, opts) do
    %__MODULE__{
      address: Keyword.fetch!(opts, :address),
      blk_max_size: Keyword.fetch!(opts, :blk_max_size),
      cks_mfa: Keyword.fetch!(opts, :cks_mfa),
      hsk_dgt_mfa: Keyword.fetch!(opts, :hsk_dgt_mfa),
      pool_id: pool_id,
      quiet_on_hsk_error?: Keyword.fetch!(opts, :quiet_on_hsk_error?),
      serialize_mfa: {Keyword.fetch!(opts, :serialize_mfa), Keyword.fetch!(opts, :deserialize_mfa)},
      shared_key: Keyword.fetch!(opts, :shared_key),
      socket_opts: T.merge_improper_keyword(@socket_opts, Keyword.fetch!(opts, :socket_opts)),
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, [C.lib(), pool_id]),
      timeout_cks: Keyword.fetch!(opts, :timeout_cks),
      timeout_hsk: Keyword.fetch!(opts, :timeout_hsk)
    }
  end

  def reset_full(data), do: data |> reset_request() |> reset_hsk()

  def reset_hsk(data) do
    %__MODULE__{
      data
      | hsk_ref: nil,
        remote: %Svc{},
        socket: nil,
        state: :init
    }
  end

  def reset_request(data) do
    %__MODULE__{
      data
      | dta: [],
        fun_name: nil,
        fun_req: nil,
        metrics: %Metrics{},
        reply_to: nil,
        result: nil,
        req_ref: nil,
        req_seq: nil,
        state: :idle,
        telemetry_result: nil,
        workers: []
    }
  end

  def rand_retry(retry_time, rand_perc \\ 10)

  def rand_retry(retry_time, rand_perc) when is_integer(retry_time) and is_integer(rand_perc) do
    rand_perc = if rand_perc > 100, do: 100, else: rand_perc
    (retry_time + retry_time * (:rand.uniform(2 * rand_perc * 10) - rand_perc * 10) / 1000) |> round()
  end

  def rand_retry(retry_time, _rand_perc) when retry_time == :infinity, do: :infinity

  def set_time(%__MODULE__{} = data, time_to_set, time_to_start \\ nil) do
    now = System.monotonic_time(@time_unit)
    met = data.metrics.time
    met = Map.replace!(met, time_to_set, now - Map.fetch!(met, time_to_set))

    data = %__MODULE__{data | metrics: %Metrics{data.metrics | time: met}}
    if !is_nil(time_to_start), do: start_time(data, time_to_start), else: data
  end

  def start_time(%__MODULE__{} = data, time_to_start) do
    met = Map.replace(data.metrics.time, time_to_start, System.monotonic_time(@time_unit))
    %__MODULE__{data | metrics: %Metrics{data.metrics | time: met}}
  end

  def zero_time(%__MODULE__{} = data, time_to_set_to_zero) do
    met = Map.replace(data.metrics.time, time_to_set_to_zero, 0)
    %__MODULE__{data | metrics: %Metrics{data.metrics | time: met}}
  end

  def inc_size(%__MODULE__{} = data, size, send_recv) when is_integer(size) and send_recv in [:send, :recv] do
    old_size = Map.fetch!(data.metrics.size, send_recv)
    met = Map.replace(data.metrics.size, send_recv, size + old_size)
    %__MODULE__{data | metrics: %Metrics{data.metrics | size: met}}
  end

  def inc_blk(%__MODULE__{} = data, send_recv) when send_recv in [:send, :recv] do
    old_count = Map.fetch!(data.metrics.blocks, send_recv)
    met = Map.replace(data.metrics.blocks, send_recv, old_count + 1)
    %__MODULE__{data | metrics: %Metrics{data.metrics | blocks: met}}
  end

  def maybe_cks(from, data, hdr, cks) do
    if is_nil(data.cks_mfa) do
      data
    else
      {m, f, o} = data.cks_mfa
      blk = hdr <> hd(data.dta)

      pid =
        spawn_link(fn ->
          my_cks = apply(m, f, [blk, o])
          if cks == my_cks, do: send(from, {:cks_check, :valid, self()}), else: send(from, {:cks_check, :invalid})
        end)

      %__MODULE__{data | workers: [pid] ++ data.workers}
    end
  end
end
