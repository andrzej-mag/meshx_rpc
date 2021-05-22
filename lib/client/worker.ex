defmodule MeshxRpc.Client.Worker do
  @moduledoc false
  @behaviour :gen_statem
  @behaviour :poolboy_worker
  alias MeshxRpc.App.T
  alias MeshxRpc.Common.{Telemetry, Structs.Data, Structs.Svc}
  alias MeshxRpc.Protocol.{Hsk, Block.Decode, Block.Encode}

  @error_prefix :error_rpc
  @error_prefix_remote :error_rpc_remote
  @reconnect_result :ok_reconnect

  @impl :poolboy_worker
  def start_link([args, opts]), do: :gen_statem.start_link(__MODULE__, args, opts)

  @impl :gen_statem
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init({data, node_ref_mfa, svc_ref_mfa, conn_ref_mfa}) do
    data = %Data{data | local: Svc.init(node_ref_mfa, svc_ref_mfa, conn_ref_mfa)}
    {:ok, :closed, data, [{:next_event, :internal, :connect}]}
  end

  @impl :gen_statem
  def terminate(_reason, _state, %Data{} = data) when is_port(data.socket), do: :gen_tcp.close(data.socket)

  # closed -> hsk -> idle -> send -> recv -> reply -> idle -> ...

  # ________closed
  def closed(:enter, :closed, _data), do: :keep_state_and_data

  def closed(:enter, _old_state, %Data{} = data) do
    :ok = :gen_tcp.close(data.socket)
    Telemetry.execute(data)
    {:keep_state, Data.reset_full(data)}
  end

  def closed(:internal, :connect, %Data{} = data) do
    {_type, ip, port} = data.address

    case :gen_tcp.connect(ip, port, data.socket_opts, data.timeout_connect) do
      {:ok, socket} ->
        data = %Data{data | socket: socket}
        {:next_state, :hsk, data, [{:next_event, :internal, :start_hsk}]}

      {:error, error} ->
        data = %Data{data | result: {@error_prefix, error}}
        Telemetry.execute(data)
        {:keep_state_and_data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_proxy_fail), []}]}
    end
  end

  def closed({:timeout, :reconnect}, [], _data), do: {:keep_state_and_data, [{:next_event, :internal, :connect}]}

  def closed({:call, from}, {:request, _request}, _data),
    do: {:keep_state_and_data, [{:reply, from, {@error_prefix, :closed}}]}

  # ________hsk
  def hsk(:enter, :closed, %Data{} = data),
    do: {:keep_state, %Data{data | state: :hsk} |> Data.start_time(:hsk), [{:state_timeout, data.timeout_hsk, :reconnect}]}

  def hsk(:internal, :start_hsk, %Data{} = data) do
    data = %Data{data | hsk_ref: System.unique_integer([:positive])}
    payload = Hsk.encode(:req, data)

    case :gen_tcp.send(data.socket, payload) do
      :ok ->
        {:keep_state, Data.inc_size(data, byte_size(payload), :send) |> Data.inc_blk(:send)}

      {:error, error} ->
        data = %Data{data | result: {@error_prefix, error}} |> Data.set_time(:hsk)
        {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_hsk_fail), []}]}
    end
  end

  def hsk(:info, {:tcp, _socket, payload}, %Data{} = data) do
    :inet.setopts(data.socket, active: :once)

    case Hsk.decode(payload, %Data{} = data) do
      {:ok, data} ->
        data = %Data{data | result: :ok} |> Data.set_time(:hsk) |> Data.inc_size(byte_size(payload), :recv) |> Data.inc_blk(:recv)

        Telemetry.execute(data)
        {:next_state, :idle, data}

      {:error, error, data} ->
        data = %Data{data | result: {@error_prefix, error}} |> Data.set_time(:hsk)
        {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_hsk_fail), []}]}

      {@error_prefix_remote, error} ->
        data = %Data{data | result: {@error_prefix_remote, error}} |> Data.set_time(:hsk)
        {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_hsk_fail), []}]}
    end
  end

  def hsk({:call, from}, {:request, _request}, _data), do: {:keep_state_and_data, [{:reply, from, {@error_prefix, :closed}}]}

  def hsk(:state_timeout, :reconnect, %Data{} = data) do
    data = %Data{data | result: {@error_prefix, :timeout_hsk}} |> Data.set_time(:hsk)
    {:next_state, :closed, data, [{:next_event, :internal, :connect}]}
  end

  def hsk(:info, {:tcp_closed, _socket}, %Data{} = data) do
    data = %Data{data | result: {@error_prefix, :tcp_closed}} |> Data.set_time(:hsk)
    {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_hsk_fail), []}]}
  end

  def hsk(:info, {:tcp_error, _socket, reason}, %Data{} = data) do
    data = %Data{data | result: {@error_prefix, reason}} |> Data.set_time(:hsk)
    {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_hsk_fail), []}]}
  end

  # ________idle
  def idle(:enter, :hsk, %Data{} = data) do
    :inet.setopts(data.socket, packet: 4)

    {:keep_state, %Data{data | state: :idle} |> Data.reset_request() |> Data.start_time(:idle),
     [{:state_timeout, T.rand_retry(data.idle_reconnect), :reconnect}]}
  end

  def idle(:enter, :reply, %Data{} = data) do
    Telemetry.execute(data)

    {:keep_state, Data.reset_request(data) |> Data.start_time(:idle),
     [{:state_timeout, T.rand_retry(data.idle_reconnect), :reconnect}]}
  end

  def idle({:call, from}, {:request, {fun_req, fun_name, args}}, %Data{} = data) do
    data =
      %Data{data | fun_name: fun_name, fun_req: fun_req, reply_to: from, req_ref: System.unique_integer([:positive])}
      |> Data.set_time(:idle)

    case Encode.encode(:request, data, args) do
      {:ok, data} ->
        {:next_state, :send, data, [{:next_event, :internal, :start}]}

      {:error, e} ->
        {:next_state, :closed, %Data{data | result: {@error_prefix, e}}, [{:next_event, :internal, :connect}]}
    end
  end

  def idle(:state_timeout, :reconnect, %Data{} = data) do
    data = %Data{data | result: @reconnect_result} |> Data.set_time(:idle)
    {:next_state, :closed, data, [{:next_event, :internal, :connect}]}
  end

  def idle(:info, {:tcp_closed, _socket}, %Data{} = data) do
    data = %Data{data | result: {@error_prefix, :tcp_closed}} |> Data.set_time(:idle)
    {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_idle_error), []}]}
  end

  def idle(:info, {:tcp_error, _socket, reason}, %Data{} = data) do
    data = %Data{data | result: {@error_prefix, reason}} |> Data.set_time(:idle)
    {:next_state, :closed, data, [{{:timeout, :reconnect}, T.rand_retry(data.retry_idle_error), []}]}
  end

  # ________send
  def send(:enter, :idle, %Data{} = data) do
    data = %Data{data | state: :send} |> Data.start_time(:send)
    {:keep_state, data}
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
        data = %Data{data | result: {@error_prefix, reason}} |> Data.set_time(:send)
        {:next_state, :closed, data, [{:next_event, :internal, :connect}]}
    end
  end

  def send(:info, {:cks_gen, cks, len, from}, %Data{} = data) do
    if length(data.dta) == len and from == data.workers do
      {:keep_state, %Data{data | cks_bin: cks}, [{:next_event, :internal, :send}]}
    else
      data = %Data{data | result: {@error_prefix, :invalid_state}} |> Data.set_time(:send)
      {:next_state, :closed, data, [{:next_event, :internal, :connect}]}
    end
  end

  def send(:state_timeout, :timeout_cks, %Data{} = data),
    do:
      {:next_state, :reply, %Data{data | result: {@error_prefix, :timeout_cks}} |> Data.set_time(:send),
       [{:next_event, :internal, :reply_close}]}

  def send(:info, {:tcp, _socket, payload}, %Data{} = data) do
    :inet.setopts(data.socket, active: :once)
    data = Data.inc_size(data, byte_size(payload), :recv) |> Data.inc_blk(:recv) |> Data.set_time(:send)

    case Decode.decode(payload, data) do
      {@error_prefix_remote, e} ->
        {:next_state, :reply, %Data{data | result: {@error_prefix_remote, e}}, [{:next_event, :internal, :reply_close}]}

      {:error, e} ->
        {:next_state, :reply, %Data{data | result: {@error_prefix, e}}, [{:next_event, :internal, :reply_close}]}

      _ ->
        {:next_state, :reply, %Data{data | result: {@error_prefix, :invalid_state}}, [{:next_event, :internal, :reply_close}]}
    end
  end

  def send(:info, {:tcp_closed, _socket}, %Data{} = data),
    do:
      {:next_state, :reply, %Data{data | result: {@error_prefix, :tcp_closed}} |> Data.set_time(:send),
       [{:next_event, :internal, :reply_close}]}

  def send(:info, {:tcp_error, _socket, reason}, %Data{} = data),
    do:
      {:next_state, :reply, %Data{data | result: {@error_prefix, reason}} |> Data.set_time(:send),
       [{:next_event, :internal, :reply_close}]}

  # ________recv
  def recv(:enter, :send, %Data{} = data) do
    data = %Data{data | dta: [], req_seq: nil, state: :recv, workers: []} |> Data.start_time(:exec)
    {:keep_state, data}
  end

  def recv(:info, {:tcp, _socket, payload}, %Data{} = data) do
    :inet.setopts(data.socket, active: :once)
    data = if Enum.empty?(data.dta), do: Data.set_time(data, :exec, :recv), else: data
    data = Data.inc_size(data, byte_size(payload), :recv) |> Data.inc_blk(:recv)

    case Decode.decode(payload, %Data{} = data) do
      :ok_ack ->
        {:next_state, :reply, %Data{data | result: :ok} |> Data.set_time(:recv), [{:next_event, :internal, :reply}]}

      {@error_prefix_remote, error} ->
        {:next_state, :reply, %Data{data | result: {@error_prefix_remote, error}} |> Data.set_time(:recv),
         [{:next_event, :internal, :reply_close}]}

      {:error, err} ->
        {:next_state, :reply, %Data{data | result: {@error_prefix, err}} |> Data.set_time(:recv),
         [{:next_event, :internal, :reply_close}]}

      {:cont, data, hdr, cks} ->
        data = Data.maybe_cks(self(), data, hdr, cks)
        {:keep_state, data}

      {:ok, data, hdr, cks, ser_flag} ->
        data = Data.maybe_cks(self(), data, hdr, cks)

        case Decode.bin_to_args(data, ser_flag) do
          {:ok, result, dser} ->
            met = %{data.metrics | time: %{data.metrics.time | dser: dser}}
            {:keep_state, %Data{data | result: result, state: :recv_fin, metrics: met}, [{:next_event, :internal, :wait_for_cks}]}

          {:error, err} ->
            {:next_state, :reply, %Data{data | result: {@error_prefix, err}} |> Data.set_time(:recv),
             [{:next_event, :internal, :reply_terminate}]}
        end
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
      {:next_state, :reply, %Data{data | state: :recv, result: {@error_prefix, :invalid_state}} |> Data.set_time(:recv),
       [{:next_event, :internal, :reply_close}]}
    end
  end

  def recv(:info, {:cks_check, :invalid}, %Data{} = data) do
    act = if is_nil(data.cks_mfa), do: {:next_event, :internal, :reply_close}, else: {:next_event, :internal, :reply_terminate}
    {:next_state, :reply, %Data{data | state: :recv, result: {@error_prefix, :invalid_cks}} |> Data.set_time(:recv), [act]}
  end

  def recv(:internal, :wait_for_cks, %Data{} = data) do
    if Enum.empty?(data.workers),
      do:
        {:next_state, :reply, %Data{data | state: :recv, telemetry_result: :ok} |> Data.set_time(:recv),
         [{:next_event, :internal, :reply}]},
      else: {:keep_state_and_data, [{:state_timeout, data.timeout_cks, :timeout_cks}]}
  end

  def recv(:state_timeout, :timeout_cks, %Data{} = data) do
    act = if is_nil(data.cks_mfa), do: {:next_event, :internal, :reply_close}, else: {:next_event, :internal, :reply_terminate}
    {:next_state, :reply, %Data{data | state: :recv, result: {@error_prefix, :timeout_cks}} |> Data.set_time(:recv), [act]}
  end

  def recv(:info, {:tcp_closed, _socket}, %Data{} = data) do
    act = if is_nil(data.cks_mfa), do: {:next_event, :internal, :reply_close}, else: {:next_event, :internal, :reply_terminate}
    {:next_state, :reply, %Data{data | state: :recv, result: {@error_prefix, :tcp_closed}} |> Data.set_time(:recv), [act]}
  end

  def recv(:info, {:tcp_error, _socket, reason}, %Data{} = data) do
    act = if is_nil(data.cks_mfa), do: {:next_event, :internal, :reply_close}, else: {:next_event, :internal, :reply_terminate}
    {:next_state, :reply, %Data{data | state: :recv, result: {@error_prefix, reason}} |> Data.set_time(:recv), [act]}
  end

  # ________reply
  def reply(:enter, :send, data), do: {:keep_state, %Data{data | state: :reply}}
  def reply(:enter, :recv, data), do: {:keep_state, %Data{data | state: :reply}}

  def reply(:internal, :reply, %Data{} = data) do
    :ok = :gen_statem.reply(data.reply_to, data.result)
    {:next_state, :idle, data}
  end

  def reply(:internal, :reply_close, %Data{} = data) do
    :ok = :gen_statem.reply(data.reply_to, data.result)
    {:next_state, :closed, data, [{:next_event, :internal, :connect}]}
  end

  def reply(:internal, :reply_terminate, %Data{} = data) do
    :ok = :gen_statem.reply(data.reply_to, data.result)
    Telemetry.execute(data)
    {:stop, :normal}
  end

  def reply(:info, _any, %Data{} = _data), do: {:stop, :normal}
end
