defmodule MeshxRpc.Protocol.Block.Decode do
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

  def decode(<<cmd::integer-unsigned-size(8), rest::binary>> = pld, %Data{} = data) when cmd in [@req_cast_1, @req_call_1] do
    <<req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size),
      ser_flag::integer-unsigned-size(8), fun_name_size::integer-unsigned-size(16), fun_name::binary-size(fun_name_size),
      dta_size::integer-unsigned-size(64), dta::binary-size(dta_size), cks::binary>> = rest

    if conn_ref == data.remote.conn_ref do
      fun_req =
        case cmd do
          @req_cast_1 -> :cast
          @req_call_1 -> :call
        end

      hdr = :binary.part(pld, 0, byte_size(pld) - (dta_size + byte_size(cks)))

      if is_nil(data.req_ref) and is_nil(data.req_seq) do
        data = %Data{data | fun_name: String.to_atom(fun_name), fun_req: fun_req, req_ref: req_ref, dta: [dta]}
        {:ok, data, hdr, cks, ser_flag}
      else
        if req_ref == data.req_ref and (is_nil(data.req_seq) or data.req_seq == 2) do
          data = %Data{data | fun_name: String.to_existing_atom(fun_name), fun_req: fun_req, dta: [dta] ++ data.dta}
          {:ok, data, hdr, cks, ser_flag}
        else
          {:error, :invalid_ref}
        end
      end
    else
      {:error, :invalid_ref}
    end
  end

  def decode(<<@rsp_call_1::integer-unsigned-size(8), rest::binary>> = pld, %Data{} = data) do
    <<req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size),
      ser_flag::integer-unsigned-size(8), dta_size::integer-unsigned-size(64), dta::binary-size(dta_size), cks::binary>> = rest

    if req_ref == data.req_ref and conn_ref == data.remote.conn_ref and (data.req_seq == 2 or data.req_seq == nil) do
      hdr = :binary.part(pld, 0, byte_size(pld) - (dta_size + byte_size(cks)))
      {:ok, %Data{data | dta: [dta] ++ data.dta}, hdr, cks, ser_flag}
    else
      {:error, :invalid_ref}
    end
  end

  def decode(<<cmd::integer-unsigned-size(8), rest::binary>> = pld, %Data{} = data) when cmd in [@req_cast_o, @req_call_o] do
    <<req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size),
      seq::integer-unsigned-size(64), dta_size::integer-unsigned-size(64), dta::binary-size(dta_size), maybe_cks::binary>> = rest

    {cks, cks_size} =
      if maybe_cks == <<>> do
        {<<>>, 0}
      else
        <<cks_size::integer-unsigned-size(32), cks::binary-size(cks_size)>> = maybe_cks
        {cks, 4 + byte_size(cks)}
      end

    hdr = :binary.part(pld, 0, byte_size(pld) - (dta_size + cks_size))

    if conn_ref == data.remote.conn_ref do
      if is_nil(data.req_ref) and is_nil(data.req_seq) do
        data = %Data{data | req_seq: seq, req_ref: req_ref, dta: [dta]}
        {:cont, data, hdr, cks}
      else
        if req_ref == data.req_ref and seq == data.req_seq - 1 do
          data = %Data{data | req_seq: seq, dta: [dta] ++ data.dta}
          {:cont, data, hdr, cks}
        else
          {:error, :invalid_ref}
        end
      end
    else
      {:error, :invalid_ref}
    end
  end

  def decode(<<cmd::integer-unsigned-size(8), rest::binary>> = pld, %Data{} = data) when cmd == @rsp_call_o do
    <<req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size),
      seq::integer-unsigned-size(64), dta_size::integer-unsigned-size(64), dta::binary-size(dta_size), maybe_cks::binary>> = rest

    {cks, cks_size} =
      if maybe_cks == <<>> do
        {<<>>, 0}
      else
        <<cks_size::integer-unsigned-size(32), cks::binary-size(cks_size)>> = maybe_cks
        {cks, 4 + byte_size(cks)}
      end

    hdr = :binary.part(pld, 0, byte_size(pld) - (dta_size + cks_size))

    if req_ref == data.req_ref and conn_ref == data.remote.conn_ref do
      if is_nil(data.req_seq) do
        data = %Data{data | req_seq: seq, dta: [dta]}
        {:cont, data, hdr, cks}
      else
        if seq == data.req_seq - 1 do
          data = %Data{data | req_seq: seq, dta: [dta] ++ data.dta}
          {:cont, data, hdr, cks}
        else
          {:error, :invalid_ref}
        end
      end
    else
      {:error, :invalid_ref}
    end
  end

  def decode(<<@rsp_cast_ack::integer-unsigned-size(8), rest::binary>>, %Data{} = data) do
    <<req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size)>> = rest

    if req_ref == data.req_ref and conn_ref == data.remote.conn_ref,
      do: :ok_ack,
      else: {:error, :invalid_ref}
  end

  def decode(<<@err::integer-unsigned-size(8), rest::binary>>, %Data{} = data) do
    <<req_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size),
      ser_flag::integer-unsigned-size(8), err::binary>> = rest

    if req_ref == data.req_ref and conn_ref == data.remote.conn_ref do
      {{_, _, _}, {m, f, o}} = data.serialize_mfa

      case apply(m, f, [err, o, ser_flag]) do
        {:ok, args} ->
          {:error_remote, args}

        {:error, err} ->
          {:error, err}

        err ->
          {:error, err}
      end
    else
      {:error, :invalid_ref}
    end
  end

  def bin_to_args(%Data{} = data, ser_flag) do
    dta = Enum.join(data.dta)
    {{_, _, _}, {m, f, o}} = data.serialize_mfa
    start = System.monotonic_time(@time_unit)

    case apply(m, f, [dta, o, ser_flag]) do
      {:ok, args} ->
        dt = System.monotonic_time(@time_unit) - start
        {:ok, args, dt}

      {:error, err} ->
        {:error, err}

      err ->
        {:error, err}
    end
  end
end
