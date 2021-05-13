defmodule MeshxRpc.Protocol.Hsk do
  @moduledoc false
  require Logger
  alias MeshxRpc.Common.Structs.{Data, Svc}

  @proto_ver 1
  @flag_hsk_req 210
  @flag_hsk_ack 215
  @flag_hsk_err 219

  def encode(hsk, %Data{} = data) when hsk in [:req, :ack] do
    hdr = encode_header(hsk, data)
    {m, f, o} = data.hsk_dgt_mfa
    digest = apply(m, f, [hdr <> data.shared_key, o])
    hdr <> digest
  end

  def encode(:error, err) do
    err = err |> to_string() |> String.slice(0..255)
    <<@flag_hsk_err::integer-unsigned-size(8), err::binary>>
  end

  def decode(<<flag::integer-unsigned-size(8), payload::binary>>, %Data{} = data)
      when flag in [@flag_hsk_req, @flag_hsk_ack] do
    case decode_header(flag, payload, data) do
      {:ok, {node_ref, svc_ref, conn_ref, hsk_ref, dgt}} ->
        data = %Data{data | remote: %Svc{node_ref: node_ref, svc_ref: svc_ref, conn_ref: conn_ref}}
        pld = <<flag::integer-unsigned-size(8), payload::binary>>
        hdr = :binary.part(pld, 0, byte_size(pld) - byte_size(dgt))
        {m, f, o} = data.hsk_dgt_mfa
        my_dgt = apply(m, f, [hdr <> data.shared_key, o])

        if my_dgt == dgt do
          if flag == @flag_hsk_req do
            {:ok, %Data{data | hsk_ref: hsk_ref}}
          else
            if hsk_ref == data.hsk_ref, do: {:ok, data}, else: {:error, :invalid_ref, data}
          end
        else
          {:error, :invalid_digest, %Data{data | hsk_ref: hsk_ref}}
        end

      {:error, e} ->
        {:error, e, data}
    end
  end

  def decode(<<flag::integer-unsigned-size(8), payload::binary>>, %Data{} = _data) when flag == @flag_hsk_err do
    err = payload |> to_string() |> String.slice(0..255)
    {:error_remote, err}
  end

  defp encode_header(hsk, %Data{} = data) do
    node_ref_size = byte_size(data.local.node_ref)
    svc_ref_size = byte_size(data.local.svc_ref)
    conn_ref_size = byte_size(data.local.conn_ref)

    hsk_flag =
      case hsk do
        :req -> @flag_hsk_req
        :ack -> @flag_hsk_ack
      end

    <<hsk_flag::integer-unsigned-size(8), data.hsk_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8),
      data.local.conn_ref::binary-size(conn_ref_size), @proto_ver::integer-unsigned-size(8),
      data.blk_max_size::integer-unsigned-size(64), svc_ref_size::integer-unsigned-size(8),
      data.local.svc_ref::binary-size(svc_ref_size), node_ref_size::integer-unsigned-size(8),
      data.local.node_ref::binary-size(node_ref_size)>>
  end

  defp decode_header(flag, payload, data) when flag in [@flag_hsk_req, @flag_hsk_ack] do
    blk_max_size = data.blk_max_size

    <<hsk_ref::integer-unsigned-size(64), conn_ref_size::integer-unsigned-size(8), conn_ref::binary-size(conn_ref_size),
      @proto_ver::integer-unsigned-size(8), ^blk_max_size::integer-unsigned-size(64), svc_ref_size::integer-unsigned-size(8),
      svc_ref::binary-size(svc_ref_size), node_ref_size::integer-unsigned-size(8), node_ref::binary-size(node_ref_size),
      dgt::binary>> = payload

    {node_ref, svc_ref, conn_ref, hsk_ref, dgt}
  rescue
    MatchError ->
      {:error, :invalid_hsk_params}
  else
    res -> {:ok, res}
  end
end
