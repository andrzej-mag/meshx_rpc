defmodule MeshxRpc.Protocol.Default do
  @moduledoc """
  RPC Protocol default functions implementations.

  todo: Documentation will be provided at a later date.
  """

  require Logger
  @int32_max round(:math.pow(2, 32) - 1)

  @ser_flag_bin 0
  @ser_flag_ser 1

  def checksum(data, _opts), do: :erlang.crc32(data) |> :binary.encode_unsigned()

  def node_ref(), do: Node.self() |> to_string() |> String.slice(0..255)
  def conn_ref(), do: :rand.uniform(@int32_max) |> :binary.encode_unsigned()

  def serialize(term, _opts) when is_binary(term), do: {:ok, term, @ser_flag_bin}

  def serialize(term, opts) do
    :erlang.term_to_binary(term, opts)
  catch
    :error, e ->
      Logger.error(__STACKTRACE__)
      {:error, e}
  else
    res -> {:ok, res, @ser_flag_ser}
  end

  def deserialize(bin, opts, ser_flag \\ @ser_flag_ser) do
    if ser_flag == @ser_flag_bin do
      {:ok, bin}
    else
      try do
        :erlang.binary_to_term(bin, opts)
      catch
        :error, e ->
          Logger.error(__STACKTRACE__)
          {:error, e}
      else
        res -> {:ok, res}
      end
    end
  end
end
