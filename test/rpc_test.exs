defmodule RpcTest do
  use ExUnit.Case
  @moduletag capture_log: true

  @error_prefix :error_rpc
  @short_bin_bytes :rand.uniform(20) + 10
  @long_bin_bytes :rand.uniform(1_000_000) + 500_000
  @txt_bytes :rand.uniform(20) + 10

  defmodule Server do
    use MeshxRpc.Server,
      telemetry_prefix: [:test, :server],
      address: {:uds, "/tmp/meshx_test.sock"}

    def echo(args), do: args
    def raise_test(args), do: raise(args)
    def reply([from, msg]), do: send(from, {:reply, msg})
  end

  defmodule Client do
    use MeshxRpc.Client,
      telemetry_prefix: [:test, :client],
      address: {:uds, "/tmp/meshx_test.sock"},
      pool_opts: [size: 10, max_overflow: 5]

    def ecall(args), do: call(:echo, args)
    def ecast(args), do: cast(:echo, args)
    def cast_reply(from, msg), do: cast(:reply, [from, msg])
    def raise_test(args), do: call(:raise_test, args)
    def raise_test!(args), do: call!(:raise_test, args)
  end

  setup_all do
    %{
      s_bin: :crypto.strong_rand_bytes(@short_bin_bytes),
      l_bin: :crypto.strong_rand_bytes(@long_bin_bytes),
      txt: :crypto.strong_rand_bytes(@txt_bytes) |> Base.encode64(padding: false)
    }
  end

  setup context do
    start_supervised(Server.child_spec(context.server))
    start_supervised(Client.child_spec(context.client))
    Process.sleep(10)
    :ok
  end

  def cmd_set(context) do
    # binary
    assert Client.ecall(context.s_bin) == context.s_bin
    assert Client.ecall(context.l_bin) == context.l_bin
    assert Client.ecall(context.txt) == context.txt
    # list
    assert Client.ecall([context.s_bin]) == [context.s_bin]
    assert Client.ecall([context.l_bin]) == [context.l_bin]
    assert Client.ecall([context.s_bin, context.l_bin, context.txt]) == [context.s_bin, context.l_bin, context.txt]
    # tuple
    assert Client.ecall({context.s_bin, context.l_bin, context.txt}) == {context.s_bin, context.l_bin, context.txt}
    # map
    assert Client.ecall(%{s: context.s_bin, l: context.l_bin, txt: context.txt}) == %{
             s: context.s_bin,
             l: context.l_bin,
             txt: context.txt
           }

    # raise
    assert Client.raise_test(context.txt) == {@error_prefix, %RuntimeError{message: context.txt}}
    assert_raise RuntimeError, context.txt, fn -> Client.raise_test!(context.txt) end
    assert Client.ecall(context.l_bin) == context.l_bin

    # cast
    msg = context.txt
    assert Client.cast_reply(self(), msg) == :ok
    assert_receive {:reply, ^msg}, 1000
    assert Client.ecast(context.l_bin) == :ok
  end

  def cmd_set_err(context) do
    assert Client.ecall(context.s_bin) == {@error_prefix, context.error}
    assert Client.ecall(context.l_bin) == {@error_prefix, context.error}
    assert Client.raise_test(context.txt) == {@error_prefix, context.error}
    assert Client.raise_test!(context.txt) == {@error_prefix, context.error}
    assert Client.ecall(context.l_bin) == {@error_prefix, context.error}
    assert Client.ecast(context.l_bin) == :ok
  end

  # TEST___________________________________________

  @tag client: []
  @tag server: []
  test "basic valid config", context do
    cmd_set(context)
  end

  @tag client: [pool_opts: [size: 0, max_overflow: 0]]
  @tag server: []
  @tag error: :full
  test "full client pool manager", context do
    cmd_set_err(context)
  end

  @tag client: [cks_mfa: {MeshxRpc.Protocol.Default, :checksum, []}]
  @tag server: [cks_mfa: {MeshxRpc.Protocol.Default, :checksum, []}]
  test "checksum: ok", context do
    cmd_set(context)
  end

  @tag client: [cks_mfa: {MeshxRpc.Protocol.Default, :checksum, []}]
  @tag server: []
  test "checksum: c", context do
    assert Client.ecall(context.l_bin) == {@error_prefix, :invalid_cks}
    assert Client.raise_test(context.txt) == {@error_prefix, %RuntimeError{message: context.txt}}
    assert_raise RuntimeError, context.txt, fn -> Client.raise_test!(context.txt) end
    assert Client.ecall(context.l_bin) == {@error_prefix, :invalid_cks}
    assert Client.ecast(context.l_bin) == :ok
  end

  @tag client: []
  @tag server: [cks_mfa: {MeshxRpc.Protocol.Default, :checksum, []}]
  @tag error: :invalid_cks
  test "checksum: s", context do
    cmd_set_err(context)
  end

  @tag client: [blk_max_size: 200]
  @tag server: [blk_max_size: 200]
  test "blk_max_size: 200", context do
    cmd_set(context)
  end

  @tag client: [blk_max_size: 268_435_456]
  @tag server: [blk_max_size: 268_435_456]
  test "blk_max_size: 268_435_456", context do
    cmd_set(context)
  end

  @tag client: [
         deserialize_mfa: {MeshxRpc.Protocol.Default, :deserialize, []},
         serialize_mfa: {MeshxRpc.Protocol.Default, :serialize, []}
       ]
  @tag server: [
         deserialize_mfa: {MeshxRpc.Protocol.Default, :deserialize, []},
         serialize_mfa: {MeshxRpc.Protocol.Default, :serialize, []}
       ]
  test "ser/dser: ok", context do
    cmd_set(context)
  end

  @tag client: [socket_opts: [keepalive: true]]
  @tag server: [socket_opts: [keepalive: true]]
  test "socket_opts: ok", context do
    cmd_set(context)
  end

  @tag client: [shared_key: "test"]
  @tag server: [shared_key: "test"]
  test "shared_key: ok", context do
    cmd_set(context)
  end

  @tag client: [shared_key: "test"]
  @tag server: []
  @tag error: :closed
  test "shared_key: c", context do
    cmd_set_err(context)
  end

  @tag client: []
  @tag server: [shared_key: "test"]
  @tag error: :closed
  test "shared_key: s", context do
    cmd_set_err(context)
  end

  @tag client: [blk_max_size: 201]
  @tag server: [blk_max_size: 200]
  @tag error: :closed
  test "blk_max_size: 201/200", context do
    cmd_set_err(context)
  end

  @tag client: [blk_max_size: 200]
  @tag server: [blk_max_size: 201]
  @tag error: :closed
  test "blk_max_size: 200/201", context do
    cmd_set_err(context)
  end
end
