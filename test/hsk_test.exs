defmodule HskTest do
  use ExUnit.Case, async: true

  alias MeshxRpc.Protocol.Hsk
  alias MeshxRpc.Common.Structs.{Data, Svc}
  alias MeshxRpc.Common.Options

  setup_all do
    pool_id = __MODULE__

    node_ref_mfa = {MeshxRpc.Protocol.Default, :node_ref, []}
    svc_ref_mfa = pool_id |> to_string() |> String.slice(0..255)
    conn_ref_mfa = {MeshxRpc.Protocol.Default, :conn_ref, []}
    opts = NimbleOptions.validate!([address: {:uds, "/tmp/beam_test.sock"}], Options.common())
    svc = Svc.init(node_ref_mfa, svc_ref_mfa, conn_ref_mfa)

    data =
      Data.init(pool_id, opts)
      |> Map.replace(:local, svc)
      |> Map.replace(:remote, svc)
      |> Map.replace(:hsk_ref, 1)

    %{data: data}
  end

  test ":req", context do
    payload = Hsk.encode(:req, context.data)
    assert Hsk.decode(payload, context.data) == {:ok, context.data}
  end

  test ":req error", context do
    payload = Hsk.encode(:req, context.data) <> "error"
    assert Hsk.decode(payload, context.data) == {:error, :invalid_digest, context.data}
  end

  test ":ack", context do
    payload = Hsk.encode(:ack, context.data)
    assert Hsk.decode(payload, context.data) == {:ok, context.data}
  end

  test ":ack error", context do
    payload = Hsk.encode(:ack, context.data) <> "error"
    assert Hsk.decode(payload, context.data) == {:error, :invalid_digest, context.data}
  end

  test ":error", context do
    payload = Hsk.encode(:error, :test)
    assert Hsk.decode(payload, context.data) == {:error_rpc_remote, "test"}
  end
end
