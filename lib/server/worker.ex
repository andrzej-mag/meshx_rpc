defmodule MeshxRpc.Server.Worker do
  @moduledoc false
  @behaviour :gen_statem
  alias MeshxRpc.Common.{Telemetry, Structs.Data}
  alias MeshxRpc.Protocol.{Hsk, Block.Decode, Block.Encode}

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init([%Data{} = data, gen_statem_opts]) do
    with {:ok, socket} <- :ranch.handshake(data.pool_id),
         :ok <- data.transport.setopts(socket, data.socket_opts) do
      data = %Data{data | socket: socket}
      :gen_statem.enter_loop(__MODULE__, gen_statem_opts, :hsk, data)
    else
      error ->
        data = %Data{data | result: {:error, error}}
        Telemetry.execute(data)
        error
    end
  end

  @impl true
  def terminate(_reason, _state, %Data{} = data) when is_port(data.socket) and not is_nil(data.transport) do
    Telemetry.execute(data)
    data.transport.close(data.socket)
  end

  def terminate(_reason, _state, _data), do: :ok

  # hsk -> recv -> execute -> send -> recv -> ...

  # ________hsk
  def hsk(:enter, :hsk, %Data{} = data),
    do: {:keep_state, %Data{data | state: :hsk} |> Data.start_time(:idle), [{:state_timeout, data.timeout_hsk, :timeout}]}

  def hsk(:info, {:tcp, _socket, payload}, %Data{} = data) do
    data.transport.setopts(data.socket, [{:active, :once}])
    data = Data.set_time(data, :idle, :hsk) |> Data.inc_size(byte_size(payload), :recv) |> Data.inc_blk(:recv)

    case Hsk.decode(payload, %Data{} = data) do
      {:ok, data} ->
        {:keep_state, data, [{:next_event, :internal, :send_ack}]}

      {:error, err, data} ->
        data = %Data{data | result: {:error, err}} |> Data.set_time(:hsk)
        if !data.quiet_on_hsk_error?, do: data.transport.send(data.socket, Hsk.encode(:error, err))
        {:stop, :normal, data}
    end
  end

  def hsk(:internal, :send_ack, %Data{} = data) do
    payload = Hsk.encode(:ack, data)

    case data.transport.send(data.socket, payload) do
      :ok ->
        data = %Data{data | result: :ok} |> Data.set_time(:hsk) |> Data.inc_size(byte_size(payload), :send) |> Data.inc_blk(:send)
        Telemetry.execute(data)
        {:next_state, :recv, data}

      {:error, reason} ->
        data = %Data{data | result: {:error, reason}} |> Data.set_time(:hsk)
        {:stop, :normal, data}
    end
  end

  def hsk(:state_timeout, :timeout, %Data{} = data) do
    data = %Data{data | result: {:error, :timeout}}
    data = if data.metrics.blocks.recv == 0, do: Data.set_time(data, :idle), else: Data.set_time(data, :hsk)
    {:stop, :normal, data}
  end

  def hsk(:info, {:tcp_closed, _socket}, %Data{} = data) do
    data = %Data{data | result: {:error, :tcp_closed}}
    data = if data.metrics.blocks.recv == 0, do: Data.set_time(data, :idle), else: Data.set_time(data, :hsk)
    {:stop, :normal, data}
  end

  def hsk(:info, {:tcp_error, _socket, reason}, %Data{} = data) do
    data = %Data{data | result: {:error, reason}}
    data = if data.metrics.blocks.recv == 0, do: Data.set_time(data, :idle), else: Data.set_time(data, :hsk)
    {:stop, :normal, data}
  end

  # ________recv
  def recv(:enter, :hsk, %Data{} = data) do
    data.transport.setopts(data.socket, packet: 4)
    data = Data.reset_request(data) |> Data.start_time(:idle)
    {:keep_state, %Data{data | state: :recv}}
  end

  def recv(:enter, :send, %Data{} = data) do
    Telemetry.execute(data)
    data = Data.reset_request(data) |> Data.start_time(:idle)
    {:keep_state, %Data{data | state: :recv}}
  end

  def recv(:info, {:tcp, socket, payload}, %Data{} = data) do
    data.transport.setopts(socket, active: :once)
    data = if is_nil(data.req_ref), do: Data.set_time(data, :idle, :recv), else: data
    data = Data.inc_size(data, byte_size(payload), :recv) |> Data.inc_blk(:recv)

    case Decode.decode(payload, data) do
      {:cont, data, hdr, cks} ->
        data = Data.maybe_cks(self(), data, hdr, cks)
        {:keep_state, data}

      {:ok, data, hdr, cks, ser_flag} ->
        data = Data.maybe_cks(self(), data, hdr, cks)

        case Decode.bin_to_args(data, ser_flag) do
          {:ok, args, dser} ->
            met = %{data.metrics | time: %{data.metrics.time | dser: dser}}
            {:keep_state, %Data{data | dta: args, state: :recv_fin, metrics: met}, [{:next_event, :internal, :wait_for_cks}]}

          {:error, err} ->
            {:next_state, :send, %Data{data | result: err, dta: []} |> Data.set_time(:recv),
             [{:next_event, :internal, :send_err}]}
        end

      {:error, err} ->
        {:next_state, :send, %Data{data | result: err, dta: []} |> Data.set_time(:recv), [{:next_event, :internal, :send_err}]}
    end
  end

  def recv(:info, {:cks_check, :valid, pid}, %Data{} = data) do
    if Enum.member?(data.workers, pid) do
      workers = List.delete(data.workers, pid)
      data = %Data{data | workers: workers}

      if data.state == :recv_fin,
        do: {:keep_state, data, [{:next_event, :internal, :wait_for_cks}]},
        else: {:keep_state, data}
    else
      {:next_state, :send, %Data{data | state: :recv, result: :invalid_state} |> Data.set_time(:recv),
       [{:next_event, :internal, :send_err}]}
    end
  end

  def recv(:info, {:cks_check, :invalid}, %Data{} = data),
    do:
      {:next_state, :send, %Data{data | state: :recv, result: :invalid_cks} |> Data.set_time(:recv),
       [{:next_event, :internal, :send_err}]}

  def recv(:internal, :wait_for_cks, %Data{} = data) do
    if Enum.empty?(data.workers),
      do: {:next_state, :exec, %Data{data | state: :recv} |> Data.set_time(:recv), [{:next_event, :internal, :exec}]},
      else: {:keep_state_and_data, [{:state_timeout, data.timeout_cks, :timeout_cks}]}
  end

  def recv(:state_timeout, :timeout_cks, %Data{} = data),
    do:
      {:next_state, :send, %Data{data | state: :recv, result: :timeout_cks} |> Data.set_time(:recv),
       [{:next_event, :internal, :send_err}]}

  def recv(:info, {:tcp_closed, _socket}, %Data{} = data) do
    data = %Data{data | state: :recv, result: {:error, :tcp_closed}}
    data = if Enum.empty?(data.dta), do: Data.set_time(data, :idle), else: Data.set_time(data, :recv)
    {:stop, :normal, data}
  end

  def recv(:info, {:tcp_error, _socket, reason}, %Data{} = data) do
    data = %Data{data | state: :recv, result: {:error, reason}}
    data = if Enum.empty?(data.dta), do: Data.set_time(data, :idle), else: Data.set_time(data, :recv)
    {:stop, :normal, data}
  end

  # ________exec
  def exec(:enter, :recv, %Data{} = data), do: {:keep_state, %Data{data | state: :exec} |> Data.start_time(:exec)}

  def exec(:internal, :exec, %Data{} = data) do
    case data.fun_req do
      :cast ->
        spawn(fn ->
          :timer.kill_after(data.timeout_execute, self())
          apply(data.pool_id, data.fun_name, [data.dta])
        end)

        {:next_state, :send, %Data{data | dta: []} |> Data.set_time(:exec), [{:next_event, :internal, :send_cast_ack}]}

      :call ->
        from = self()

        {pid, ref} =
          spawn_monitor(fn ->
            :timer.kill_after(data.timeout_execute, self())
            result = apply(data.pool_id, data.fun_name, [data.dta])
            send(from, {:result, result, self()})
          end)

        action = if is_integer(data.timeout_execute), do: round(data.timeout_execute * 1.1), else: data.timeout_execute
        {:keep_state, %Data{data | workers: {pid, ref}, dta: []}, [{:state_timeout, action, :timeout_execute}]}
    end
  end

  def exec(:info, {:result, result, pid}, %Data{} = data) do
    {p, _ref} = data.workers

    if pid == p,
      do: {:keep_state, %Data{data | result: result, telemetry_result: :ok}},
      else: {:keep_state, %Data{data | result: :invalid_state}}
  end

  def exec(:info, {:DOWN, ref, :process, pid, :normal}, %Data{} = data) do
    {p, r} = data.workers

    if pid == p and ref == r,
      do: {:next_state, :send, data |> Data.set_time(:exec), [{:next_event, :internal, :init}]},
      else:
        {:next_state, :send, %Data{data | result: :invalid_state} |> Data.set_time(:exec), [{:next_event, :internal, :send_err}]}
  end

  def exec(:info, {:DOWN, ref, :process, pid, error}, %Data{} = data) do
    {p, r} = data.workers

    if pid == p and ref == r do
      case error do
        {e, _s} when is_exception(e) ->
          {:next_state, :send, %Data{data | result: e} |> Data.set_time(:exec), [{:next_event, :internal, :send_err}]}

        _ ->
          {:next_state, :send, %Data{data | result: error} |> Data.set_time(:exec), [{:next_event, :internal, :send_err}]}
      end
    else
      {:next_state, :send, %Data{data | result: :invalid_state} |> Data.set_time(:exec), [{:next_event, :internal, :send_err}]}
    end
  end

  def exec(:state_timeout, :timeout_execute, %Data{} = data) do
    true = kill_worker(data.workers)
    {:next_state, :send, %Data{data | result: :timeout_call_exec} |> Data.set_time(:exec), [{:next_event, :internal, :send_err}]}
  end

  def exec(:info, {:tcp, _socket, _payload}, %Data{} = data) do
    true = kill_worker(data.workers)
    {:stop, :normal, %Data{data | result: {:error, :invalid_state}} |> Data.set_time(:exec)}
  end

  def exec(:info, {:tcp_closed, _socket}, %Data{} = data) do
    true = kill_worker(data.workers)
    {:stop, :normal, %Data{data | result: {:error, :tcp_closed}} |> Data.set_time(:exec)}
  end

  def exec(:info, {:tcp_error, _socket, reason}, %Data{} = data) do
    true = kill_worker(data.workers)
    {:stop, :normal, %Data{data | result: {:error, reason}} |> Data.set_time(:exec)}
  end

  defp kill_worker(worker) do
    case worker do
      {pid, _ref} when is_pid(pid) -> Process.exit(pid, :kill)
      _ -> true
    end
  end

  # ________send
  def send(:enter, :recv, %Data{} = data), do: {:keep_state, Data.start_time(data, :send)}
  def send(:enter, :exec, %Data{} = data), do: {:keep_state, %Data{data | state: :send} |> Data.start_time(:send)}

  def send(:internal, :send_cast_ack, %Data{} = data) do
    payload = Encode.encode(:ack, data)

    case data.transport.send(data.socket, payload) do
      :ok ->
        data =
          Data.set_time(data, :send)
          |> Data.inc_size(byte_size(payload), :send)
          |> Data.inc_blk(:send)

        {:next_state, :recv, data}

      err ->
        {:stop, :normal, %Data{data | result: err} |> Data.set_time(:send)}
    end
  end

  def send(:internal, :send_err, %Data{} = data) do
    payload = Encode.encode(:err, data)

    case data.transport.send(data.socket, payload) do
      :ok ->
        data =
          %Data{data | result: {:error, data.result}}
          |> Data.set_time(:send)
          |> Data.inc_size(byte_size(payload), :send)
          |> Data.inc_blk(:send)

        {:stop, :normal, data}

      err ->
        {:stop, :normal, %Data{data | result: {:error, {data.result, err}}} |> Data.set_time(:send)}
    end
  end

  def send(:internal, :init, %Data{} = data) do
    case Encode.encode(:response, data, data.result) do
      {:ok, data} ->
        {:keep_state, data, [{:next_event, :internal, :start}]}

      {:error, e} ->
        {:stop, :normal, %Data{data | result: {:error, e}} |> Data.set_time(:send)}
    end
  end

  def send(:internal, :start, %Data{} = data) do
    if is_nil(data.cks_mfa) do
      {:keep_state, data, [{:next_event, :internal, :send}]}
    else
      {m, f, o} = data.cks_mfa
      cks = apply(m, f, [hd(data.dta), o])
      {:keep_state, %Data{data | cks_bin: cks}, [{:next_event, :internal, :send}]}
    end
  end

  def send(:internal, :send, %Data{} = data) do
    [blk | tail] = data.dta

    {payload, data} =
      cond do
        is_nil(data.cks_mfa) ->
          {blk, data}

        Enum.empty?(tail) ->
          {blk <> data.cks_bin, data}

        true ->
          next = hd(tail)
          {m, f, o} = data.cks_mfa
          len = length(tail)
          from = self()

          pid =
            spawn_link(fn ->
              cks = apply(m, f, [next, o])
              send(from, {:cks_gen, cks, len, self()})
            end)

          cks_size = byte_size(data.cks_bin)
          {blk <> <<cks_size::integer-unsigned-size(32)>> <> data.cks_bin, %Data{data | workers: pid}}
      end

    case :gen_tcp.send(data.socket, payload) do
      :ok ->
        data = Data.inc_size(data, byte_size(payload), :send) |> Data.inc_blk(:send)

        if Enum.empty?(tail) do
          {:next_state, :recv, Data.set_time(data, :send)}
        else
          if is_nil(data.cks_mfa),
            do: {:keep_state, %Data{data | dta: tail}, [{:next_event, :internal, :send}]},
            else: {:keep_state, %Data{data | dta: tail}, [{:state_timeout, data.timeout_cks, :timeout_cks}]}
        end

      {:error, reason} ->
        data = %Data{data | result: {:error, reason}} |> Data.set_time(:send)
        {:stop, :normal, data}
    end
  end

  def send(:info, {:cks_gen, cks, len, from}, %Data{} = data) do
    if length(data.dta) == len and from == data.workers,
      do: {:keep_state, %Data{data | cks_bin: cks}, [{:next_event, :internal, :send}]},
      else: {:stop, :normal, %Data{data | result: {:error, :invalid_state}} |> Data.set_time(:send)}
  end

  def send(:state_timeout, :timeout_cks, %Data{} = data),
    do: {:keep_state, %Data{data | result: :timeout_cks} |> Data.set_time(:send), [{:next_event, :internal, :send_err}]}

  def send(:info, {:tcp_closed, _socket}, %Data{} = data),
    do: {:stop, :normal, %Data{data | result: {:error, :tcp_closed}} |> Data.set_time(:send)}

  def send(:info, {:tcp_error, _socket, reason}, %Data{} = data),
    do: {:stop, :normal, %Data{data | result: {:error, reason}} |> Data.set_time(:send)}
end
