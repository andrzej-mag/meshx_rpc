# MeshxRpc

<!-- MDOC !-->
RPC client and server.

`MeshxRpc` can be considered as an alternative to Erlang OTP [`:erpc`](https://erlang.org/doc/man/erpc.html) or [`:rpc`](https://erlang.org/doc/man/rpc.html) modules. Native OTP `:erpc` module requires nodes to be connected with Erlang distribution protocol. Additionally `:erpc` allows execution of arbitrary code on remote node, which might be not acceptable from security point of view in many environments. `MeshxRpc` restricts incoming request function executability to single module associated with given RPC server. This way user has full control over RPC server code exposed to remote RPC clients. Furthermore `MeshxRpc` is using custom binary communication protocol, hence it doesn't depend on Erlang distribution protocol.

`MeshxRpc` features:
  * connection pooling,
  * user customizable serialization functions,
  * traffic chunking into smaller blocks of configurable maximum size to avoid IO socket blocking,
  * optional transmission error detection with user configurable asynchronously executed message block checksum functions,
  * reach per request telemetry metrics,
  * request integrity protection with sequence numbers and node/connection references,
  * primitive access control with optional pre-shared keys,
  * load balancing and high availability provided by service mesh data plane.

`MeshxRpc` designed to work primarily as mesh service doesn't offer data encryption, authorization or authentication mechanisms as those are natively provided by service mesh environment.

## Installation
Add `:meshx_rpc` to application dependencies:
```elixir
# mix.exs
def deps do
  [{:meshx_rpc, "~> 0.1.0-dev", github: "andrzej-mag/meshx_rpc"}]
end
```

## Usage
Same `mix` project is used to implement both RPC server and RPC client to simplify usage examples.
Server node is distinguished from client node by using custom `erl` command line flag `-rpc_server?` when starting nodes with `iex`.

Implement RPC server and client modules:
```elixir
# lib/server.ex
defmodule Example1.Server do
  use MeshxRpc.Server

  def echo(args), do: args
  def ping(_args), do: :pong
end

# lib/client.ex
defmodule Example1.Client do
  use MeshxRpc.Client
  # option suggested for testing and development: to reduce emitted telemetry events limit pool workers number
  # pool_opts: [size: 1, max_overflow: 0]
  def echo(args), do: call(:echo, args)
end
```

Next step involves building communication channel between server and client:
  * **Example 1**: server and client are started on same host and both connect to the same UDS socket,
  * **Example 2**: service mesh data plane is used for RPC client-server communication and `MeshxConsul` is used as service mesh adapter.

### Example 1. Shared Unix Domain Socket.

```elixir
# lib/example1/application.ex
defmodule Example1.Application do
  @moduledoc false
  use Application

  @address {:uds, "/tmp/meshx.sock"}

  @impl true
  def start(_type, _args) do
    mod = if rpc_server?(), do: Example1.Server, else: Example1.Client
    telemetry_prefix = [:example1, mod]
    MeshxRpc.attach_telemetry(telemetry_prefix)
    children = [mod.child_spec(address: @address, telemetry_prefix: telemetry_prefix)]
    Supervisor.start_link(children, strategy: :one_for_one, name: Example1.Supervisor)
  end

  defp rpc_server?() do
    case :init.get_argument(:rpc_server?) do
      {:ok, [['true']]} -> true
      _ -> false
    end
  end
end
```

Launch two terminals, start RPC server node in first one:
```sh
iex --erl "-start_epmd false" --erl "-rpc_server? true" -S mix
```
Start RPC client node in second terminal:
```sh
iex --erl "-start_epmd false" --erl "-rpc_server? false" -S mix
```
In both terminals similar telemetry event should be logged, here client side:
```elixir
# [:example1, Example1.Client, :hsk] -> :ok
# local: %{conn_ref: "VPRihQ", node_ref: "nonode@nohost", svc_ref: "Elixir.Example1.Client"}
# remote: %{conn_ref: "wfyMQQ", node_ref: "nonode@nohost", svc_ref: "Elixir.Example1.Server"}
# ...
```
First line says that successful handshake (`:hsk`) was executed by `[:example1, Example1.Client]`. Next two log lines describe local and remote endpoints. Please check `MeshxRpc.attach_telemetry/2` for details.

Execute RPC requests in client terminal:
```elixir
iex(1)> Example1.Client.call(:ping)
:pong
iex(2)> Example1.Client.echo("hello world")
"hello world"
iex(3)> Example1.Client.cast(:echo, "hello world")
:ok
```
When using OTP [`:erpc`](https://erlang.org/doc/man/erpc.html) module it is possible to execute arbitrary function call on remote node, for example: `:erpc.call(:other_node, File, :rm, ["/1/etc/*.remove_all"])`. As mentioned earlier request execution scope in `MeshxRpc` is limited to single server module, here `Example1.Server` exposes only `ping/1` and `echo/1`. Requesting remote execution of not implemented (or not allowed) function will result in error:
```elixir
iex(3)> Example1.Client.call(:rm, ["/1/etc/*.remove_all"])
{:error_remote,
 {:undef,
  [
    {Example1.Server, :rm, [["/1/etc/*.remove_all"]], []},
    {MeshxRpc.Server.Worker, :"-exec/3-fun-1-", 2,
     [file: 'lib/server/worker.ex', line: 188]}
  ]}}
```
Possible extension to this example could be: run RPC server and client nodes on different hosts and connect UDS sockets using ssh port forwarding.

### Example 2. Service mesh using `MeshxConsul`.
Please check `MeshxConsul` package documentation for additional requirements and necessary configuration steps when using Consul service mesh adapter.

Starting user service providers and upstream clients in service mesh requires interaction with Consul used as external service mesh application. Running external API calls that can block, during supervision tree initialization is considered as bad practice.
To start mesh service provider and mesh upstream client asynchronously, additional `DynamicSupervisor` is created:
```elixir
# lib/example2/application.ex
defmodule Example2.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Example2.MeshSupervisor],
      strategy: :one_for_one,
      name: Example2.Supervisor
    )
  end
end
```

`Example2.MeshSupervisor` used to asynchronously start both RPC server and client depending on `--erl "-rpc_server? true/false"` command line flag:
```elixir
# lib/mesh_supervisor.ex
defmodule Example2.MeshSupervisor do
  use DynamicSupervisor

  @service_name "service-1"

  def start_link(init_arg),
    do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg) do
    spawn(__MODULE__, :start_mesh, [])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_mesh() do
    {mod, address} =
      if rpc_server?() do
        {:ok, _id, address} = MeshxConsul.start(@service_name)
        {Example2.Server, address}
      else
        {:ok, [{:ok, address}]} = MeshxConsul.connect([@service_name])
        {Example2.Client, address}
      end

    telemetry_prefix = [:example2, mod]
    MeshxRpc.attach_telemetry(telemetry_prefix)

    DynamicSupervisor.start_child(
      __MODULE__,
      mod.child_spec(address: address, telemetry_prefix: telemetry_prefix)
    )
  end

  defp rpc_server?() do
    case :init.get_argument(:rpc_server?) do
      {:ok, [['true']]} -> true
      _ -> false
    end
  end
end
```
Commands to start server and client nodes are same as in Example 1.

Following events take place when RPC server node is started:
  * mesh service endpoint `address` is prepared by `MeshxConsul.start("service-1")`,
  * Logger is attached to telemetry events with `MeshxRpc.attach_telemetry(telemetry_prefix)`,
  * `DynamicSupervisor` starts child specified with `Example2.Server.child_spec/1`,
  * started child worker is a user defined (RPC) server attached to mesh service endpoint `address`, hence it becomes user mesh service provider that can be managed using Consul service mesh control plane.

Events taking place when RPC client node is started:
  * mesh upstream endpoint `address` is prepared by `MeshxConsul.connect(["service-1"])`:
    * special `upstream-h11` service with sidecar proxy is started,
    * upstream `service-1` is added to sidecar proxy `upstream-h11`,
  * Logger is attached to telemetry events with `MeshxRpc.attach_telemetry(telemetry_prefix)`,
  * `DynamicSupervisor` starts child specified with `Example2.Client.child_spec/1`,
  * started user (RPC) client is connected to mesh upstream endpoint `address`, hence it acts as user mesh upstream client bound with service mesh data plane.

Consul UI screenshot showing connection between `upstream-h11` proxy service and `service-1`:
![image](assets/topology.png)

<!-- MDOC !-->

Next section on hexdocs.pm: [Common configuration].
