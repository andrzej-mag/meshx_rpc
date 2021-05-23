defmodule DefaultTest do
  use ExUnit.Case, async: true

  alias MeshxRpc.Protocol.Default

  test "checksum/2" do
    assert Default.checksum("test", []) == <<216, 127, 126, 12>>
  end

  test "node_ref/0" do
    assert Default.node_ref() == "nonode@nohost"
  end

  test "conn_ref/0" do
    assert is_binary(Default.conn_ref()) == true
  end

  test "serialize/2" do
    assert MeshxRpc.Protocol.Default.serialize("test", []) == {:ok, "test", 0}

    assert MeshxRpc.Protocol.Default.serialize(%{test_k: "test_v"}, []) ==
             {:ok, <<131, 116, 0, 0, 0, 1, 100, 0, 6, 116, 101, 115, 116, 95, 107, 109, 0, 0, 0, 6, 116, 101, 115, 116, 95, 118>>,
              1}
  end

  test "deserialize/3" do
    assert MeshxRpc.Protocol.Default.deserialize("test", [], 0) == {:ok, "test"}

    assert MeshxRpc.Protocol.Default.deserialize(
             <<131, 116, 0, 0, 0, 1, 100, 0, 6, 116, 101, 115, 116, 95, 107, 109, 0, 0, 0, 6, 116, 101, 115, 116, 95, 118>>,
             [],
             1
           ) == {:ok, %{test_k: "test_v"}}
  end
end
