defmodule MeshxRpc do
  @readme File.read!("docs/README.md") |> String.split("<!-- MDOC !-->") |> Enum.fetch!(1)

  @moduledoc """
  #{@readme}

  ## Common configuration
  RPC client and server modules provide child specifications which should be used with user supervisors as shown on examples above. RPC client `child_spec` can be created directly by accessing `MeshxRpc.Client.Pool.child_spec/2` or by using wrapper module `MeshxRpc.Client`. Similarly RPC server `child_spec` is available through `MeshxRpc.Server.Pool.child_spec/2` or `MeshxRpc.Server` modules.

  Configuration options common to client and server `child_spec/2` functions:
  #{NimbleOptions.docs(MeshxRpc.Common.Options.common())}

  ## Telemetry

  ### Telemetry events
  Telemetry event prefix is defined with `:telemetry_prefix` configuration option.

  Events generated by `MeshxRpc`:
    * `:init` - emitted only by server when server worker cannot establish socket connection with user provided `address` terminated with transport solution (e.g. service mesh sidecar proxy),
    * `:hsk` - emitted by both server and client during connection handshake phase,
    * `:idle` - emitted only by client workers when worker is in idle state waiting for user requests,
    * `:recv` and `:send` - emitted by both client and server workers if there was a problem when receiving or sending request data,
    * `:call` and `:cast` - emitted by client and server during failed or after successful call/cast request processing.

  ### Telemetry metadata
  * `:address` - connection address, e.g. `{:tcp, {127, 0, 0, 1}, 1024}`,
  * `:fun_name` - request function name, e.g. `:echo`,
  * `:fun_req` - request function type, can be `:call` or `:cast`,
  * `:hsk_ref` - handshake reference, `integer()`,
  * `:id` - RPC server or client id, e.g. `Example2.Client`,
  * `:local` - map describing local endpoint using keys: `conn_ref`, `node_ref` and `svc_ref`.
  * `:remote` - as `:local` but for remote endpoint,
  * `:req_ref` - request reference, `integer()`,
  * `:result` - execution result. If request execution was successful `:result` is set to atom `:ok`, real execution results are not emitted by telemetry. If execution failed, error reason is emitted,
  * `:socket` - socket port used in connection, e.g. `#Port<0.19>`,
  * `:state` - worker `:gen_statem` last state, e.g. `:reply`.

  Example request telemetry metadata:
  ```elixir
  %{
    address: {:tcp, {127, 0, 0, 1}, 65535},
    fun_name: :echo,
    fun_req: :cast,
    hsk_ref: 3490,
    id: Example2.Client,
    local: %{
      conn_ref: <<123, 219, 9, 168>>,
      node_ref: "nonode@nohost",
      svc_ref: "Elixir.Example2.Client"
    },
    remote: %{
      conn_ref: <<66, 9, 108, 5>>,
      node_ref: "nonode@nohost",
      svc_ref: "Elixir.Example2.Server"
    },
    req_ref: 3650,
    result: :ok,
    socket: #Port<0.12863>,
    state: :reply
  }
  ```

  ### Telemetry metrics
  Three metrics types are reported:
    * `:blocks` - reports number of blocks, send and received,
    * `:size` - number of bytes, send and received,
    * `:time` - **approximate** time in microseconds spend on consecutive request processing steps.

  `:time` metrics:
    * `:ser` and `:dser` - serialization and de-serialization time,
    * `:exec` - request function execution time,
    * `:hsk` - handshake time,
    * `:idle` - worker idle time,
    * `:recv` and `:send` - time spent on request data receiving and sending.

  Example telemetry metrics:
  ```elixir
  %{
    blocks: %{recv: 1, send: 1},
    size: %{recv: 14, send: 40},
    time: [
      dser: 0,
      exec: 1038,
      hsk: 0,
      idle: 101101,
      recv: 12,
      send: 102,
      ser: 1
    ]
  }
  ```
  """

  @doc """
  Attaches pretty-printing Logger handler to telemetry events.

  First argument should correspond to `:telemetry_prefix` configuration option described earlier. Second argument is telemetry [handler id](https://hexdocs.pm/telemetry/telemetry.html#type-handler_id). If handler id is undefined it will be assigned value equal to second list element in `telemetry_prefix`.

  Errors are logged with `:error` Logger level, all other events are logged with `:debug` level.

  Example log of `:ping` call request:
  ```elixir
  Example2.Client.call(:ping)
  12:17:11.869 [debug]
  [:example2, Example2.Client, :call, :ping] -> :ok
  local: %{conn_ref: "e9sJqA", node_ref: "nonode@nohost", svc_ref: "Elixir.Example2.Client"}
  remote: %{conn_ref: "QglsBQ", node_ref: "nonode@nohost", svc_ref: "Elixir.Example2.Server"}
  address: {:tcp, {127, 0, 0, 1}, 65535}
  meta: [hsk_ref: 4034, req_ref: 4066, socket: #Port<0.14455>, state: :reply]
  t_req: 2.152 [dser: 0.006, exec: 2.002, recv: 0.036, send: 0.105, ser: 0.003]
  t_idle: 17547.272
  size: [recv: "31B", send: "31B"]
  blocks: [recv: 1, send: 1]
  ```
  `t_req` is a total request time followed by [individual request steps times], milliseconds.

  `t_idle` is a worker idle time, milliseconds.

  `attach_telemetry/2` is created as helper for use during development phase, most probably should not be used in production.
  """
  @spec attach_telemetry(telemetry_prefix :: [atom()], id :: term()) :: :ok
  def attach_telemetry(telemetry_prefix, id \\ nil), do: MeshxRpc.Common.Telemetry.attach(telemetry_prefix, id)
end
