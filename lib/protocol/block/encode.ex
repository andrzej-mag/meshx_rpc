defmodule MeshxRpc.Protocol.Block.Encode do
  @moduledoc false
  alias MeshxRpc.Common.Structs.Data

  @time_unit :microsecond

  @req_cast_1 10
  @req_cast_o 11
  @rsp_cast_ack 15

  @req_call_1 50
  @req_call_o 51
  @rsp_call_1 55
  @rsp_call_o 56

  @err 199

  def encode(req_type, %Data{} = data, args) when req_type in [:request, :response] do
    {{m, f, o}, {_, _, _}} = data.serialize_mfa
    start = System.monotonic_time(@time_unit)

    case apply(m, f, [args, o]) do
      {:ok, args_bin, ser_flag} ->
        dt = System.monotonic_time(@time_unit) - start
        met = %{data.metrics | time: %{data.metrics.time | ser: dt}}
        packetize(req_type, %Data{data | metrics: met}, args_bin, ser_flag)

      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  def encode(:ack, %Data{} = data) do
    conn_ref_size = byte_size(data.local.conn_ref)

    <<@rsp_cast_ack::integer-unsigned-size(8), data.req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8),
      data.local.conn_ref::binary-size(conn_ref_size)>>
  end

  def encode(:err, %Data{} = data) do
    conn_ref_size = byte_size(data.local.conn_ref)
    {{m, f, o}, {_, _, _}} = data.serialize_mfa

    {err, ser_flag} =
      case apply(m, f, [data.result, o]) do
        {:ok, payload, ser_flag} ->
          len = 1 + 8 + 1 + conn_ref_size + byte_size(payload)

          if len > data.blk_max_size do
            case data.result do
              {exception, _stack_trace} when is_exception(exception) ->
                {:ok, payload, ser_flag} = apply(m, f, [exception, o])
                {payload, ser_flag}

              _ ->
                {:ok, payload, ser_flag} = apply(m, f, [:error_too_long, o])
                {payload, ser_flag}
            end
          else
            {payload, ser_flag}
          end

        _ ->
          {:ok, payload, ser_flag} = apply(m, f, [:serialization_fail, o])
          {payload, ser_flag}
      end

    <<@err::integer-unsigned-size(8), data.req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8),
      data.local.conn_ref::binary-size(conn_ref_size), ser_flag::integer-unsigned-size(8), err::binary>>
  end

  defp packetize(req_type, %Data{} = data, payload, ser_flag) do
    case frags_size(req_type, data, byte_size(payload)) do
      {:ok, sizes} -> packetize(req_type, data, payload, ser_flag, sizes)
      e -> e
    end
  end

  defp packetize(req_type, %Data{} = data, payload, ser_flag, {f_size, o_size}, seq \\ 1) do
    pld_size = byte_size(payload)
    frag_size = if seq == 1, do: f_size, else: o_size
    cmd_flag = enc_flag(req_type, data.fun_req, seq)
    hdr = enc_hdr(data, seq, cmd_flag, ser_flag)

    if pld_size <= frag_size do
      pkt = hdr <> <<pld_size::integer-unsigned-size(64)>> <> payload
      {:ok, %Data{data | dta: [pkt] ++ data.dta}}
    else
      <<frag::binary-size(frag_size), rest::binary>> = payload
      pkt = hdr <> <<frag_size::integer-unsigned-size(64)>> <> frag
      data = %Data{data | dta: [pkt] ++ data.dta}
      packetize(req_type, data, rest, ser_flag, {f_size, o_size}, seq + 1)
    end
  end

  defp enc_flag(:request, :cast, 1), do: @req_cast_1
  defp enc_flag(:request, :cast, _seq), do: @req_cast_o
  defp enc_flag(:request, :call, 1), do: @req_call_1
  defp enc_flag(:request, :call, _seq), do: @req_call_o
  defp enc_flag(:response, :call, 1), do: @rsp_call_1
  defp enc_flag(:response, :call, _seq), do: @rsp_call_o

  defp enc_hdr(data, 1 = _seq, cmd_flag, ser_flag) when cmd_flag in [@req_cast_1, @req_call_1] do
    fun_name = to_string(data.fun_name)
    fun_name_size = byte_size(fun_name)
    conn_ref_size = byte_size(data.local.conn_ref)

    <<cmd_flag::integer-unsigned-size(8), data.req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8),
      data.local.conn_ref::binary-size(conn_ref_size), ser_flag::integer-unsigned-size(8),
      fun_name_size::integer-unsigned-size(16), fun_name::binary>>
  end

  defp enc_hdr(data, 1 = _seq, cmd_flag, ser_flag) when cmd_flag == @rsp_call_1 do
    conn_ref_size = byte_size(data.local.conn_ref)

    <<cmd_flag::integer-unsigned-size(8), data.req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8),
      data.local.conn_ref::binary-size(conn_ref_size), ser_flag::integer-unsigned-size(8)>>
  end

  defp enc_hdr(data, seq, cmd_flag, _ser_flag) when cmd_flag in [@req_cast_o, @req_call_o, @rsp_call_o] do
    conn_ref_size = byte_size(data.local.conn_ref)

    <<cmd_flag::integer-unsigned-size(8), data.req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8),
      data.local.conn_ref::binary-size(conn_ref_size), seq::integer-unsigned-size(64)>>
  end

  defp frags_size(req_type, data, dta_size) do
    {f, o} = hdrs_size(req_type, data)
    blk_max_size = data.blk_max_size

    cond do
      f >= blk_max_size or o >= blk_max_size ->
        {:error, :invalid_pkt_size}

      dta_size <= blk_max_size - f ->
        {:ok, {dta_size, dta_size}}

      true ->
        count = ceil(dta_size / (blk_max_size - o))
        count = calc_pkt_count(f, o, blk_max_size, dta_size, count)
        base_size = ceil(dta_size / count)
        rem = ceil((f - o) / count)
        f_size = base_size - (f - o) + rem
        o_size = base_size + rem
        {:ok, {f_size, o_size}}
    end
  end

  defp calc_pkt_count(f, o, blk_max_size, dta_size, count) do
    capacity = blk_max_size - f + (blk_max_size - o) * (count - 1)
    if capacity >= dta_size, do: count, else: calc_pkt_count(f, o, blk_max_size, dta_size, count + 1)
  end

  defp hdrs_size(:request, data) do
    fun_size = data.fun_name |> to_string() |> byte_size()
    conn_size = byte_size(data.local.conn_ref)
    first = 1 + 8 + 1 + conn_size + 1 + 2 + fun_size + 8
    other = 1 + 8 + 1 + conn_size + 8 + 8
    {first, other}
  end

  defp hdrs_size(:response, data) do
    conn_size = byte_size(data.local.conn_ref)
    first = 1 + 8 + 1 + conn_size + 1 + 8
    other = 1 + 8 + 1 + conn_size + 8 + 8
    {first, other}
  end
end
