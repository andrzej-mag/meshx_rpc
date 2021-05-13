defmodule MeshxRpc.Common.Telemetry do
  @moduledoc false
  alias MeshxRpc.Common.Structs.Data
  require Logger

  def attach([_n, i] = telemetry_prefix, id \\ nil) do
    id = if is_nil(id), do: i, else: id

    events = [
      telemetry_prefix ++ [:init],
      telemetry_prefix ++ [:hsk],
      telemetry_prefix ++ [:idle],
      telemetry_prefix ++ [:recv],
      telemetry_prefix ++ [:send],
      telemetry_prefix ++ [:call],
      telemetry_prefix ++ [:cast]
    ]

    :ok = :telemetry.attach_many(id, events, &handle_event/4, nil)
  end

  def execute(%Data{} = data) do
    event_name = if is_nil(data.fun_req), do: data.telemetry_prefix ++ [data.state], else: data.telemetry_prefix ++ [data.fun_req]
    metrics = data.metrics
    time = Enum.map(metrics.time, fn {k, v} -> if v < 0, do: {k, -1}, else: {k, v} end)
    metrics = %{metrics | time: time}
    measurements = Map.from_struct(metrics)

    result = if is_nil(data.telemetry_result), do: data.result, else: data.telemetry_result

    metadata = %{
      address: data.address,
      fun_name: data.fun_name,
      fun_req: data.fun_req,
      hsk_ref: data.hsk_ref,
      id: data.pool_id,
      local: Map.from_struct(data.local),
      remote: Map.from_struct(data.remote),
      req_ref: data.req_ref,
      result: result,
      socket: data.socket,
      state: data.state
    }

    :ok = :telemetry.execute(event_name, measurements, metadata)
  end

  defp handle_event(event_name, measurements, metadata, _config) do
    {result, meta} = Map.pop!(metadata, :result)
    {local, meta} = Map.pop!(meta, :local)
    {remote, meta} = Map.pop!(meta, :remote)
    {address, meta} = Map.pop!(meta, :address)
    {fun_name, meta} = Map.pop!(meta, :fun_name)
    {_fun_req, meta} = Map.pop!(meta, :fun_req)
    {_id, meta} = Map.pop!(meta, :id)

    event_name = if is_nil(fun_name), do: event_name, else: event_name ++ [fun_name]
    meta = if is_nil(fun_name), do: Map.delete(meta, :state), else: meta
    local = if is_nil(local.conn_ref), do: local, else: %{local | conn_ref: local.conn_ref |> Base.encode64(padding: false)}
    remote = if is_nil(remote.conn_ref), do: remote, else: %{remote | conn_ref: remote.conn_ref |> Base.encode64(padding: false)}
    meta = Enum.reject(meta, fn {_k, v} -> is_nil(v) end)

    {time, measurements} = Map.pop!(measurements, :time)
    {size, measurements} = Map.pop!(measurements, :size)
    {blocks, _measurements} = Map.pop!(measurements, :blocks)

    {idle, time} = Keyword.pop!(time, :idle)
    idle = idle / 1_000
    time = Enum.reject(time, fn {_k, v} -> v == 0 end) |> Enum.map(fn {k, time} -> {k, time / 1_000} end)
    t_req = Enum.reduce(time, 0, fn {_k, v}, acc -> v + acc end)
    t_req = if is_float(t_req), do: Float.round(t_req, 3), else: t_req
    size = Enum.map(size, fn {k, s} -> {k, pretty_bytes(s)} end)
    blocks = Map.to_list(blocks)

    level =
      case result do
        {:error, _e} -> :error
        {:error_remote, _e} -> :error
        _ -> :debug
      end

    Logger.log(
      level,
      """

      #{inspect(event_name)} -> #{inspect(result)}
      local: #{inspect(local)}
      remote: #{inspect(remote)}
      address: #{inspect(address)}
      meta: #{inspect(meta)}
      t_req: #{t_req} #{inspect(time)}
      t_idle: #{idle}
      size: #{inspect(size)}
      blocks: #{inspect(blocks)}
      """
    )
  end

  defp pretty_bytes(val) do
    {val_div, val_unit} =
      cond do
        val < 1_000 -> {1, "B"}
        val < 1_000_000 -> {1_000, "KB"}
        val < 1_000_000_000 -> {1_000_000, "MB"}
        val < 1_000_000_000_000 -> {1_000_000_000, "GB"}
        true -> {1_000_000_000_000, "TB"}
      end

    if val_unit == "B", do: "#{round(val / val_div)}#{val_unit}", else: "#{Float.round(val / val_div, 3)}#{val_unit}"
  end
end
