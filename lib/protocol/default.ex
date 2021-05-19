defmodule MeshxRpc.Protocol.Default do
  @moduledoc """
  RPC protocol default functions.
  """

  require Logger
  @int32_max round(:math.pow(2, 32) - 1)

  @ser_flag_bin 0
  @ser_flag_ser 1

  @doc """
  Calculates checksum for given `data` with `:erlang.crc32/1`.

  Function returns checksum as 4 bytes binary big endian unsigned integer.
  ```elixir
  iex(1)> MeshxRpc.Protocol.Default.checksum("test", [])
  <<216, 127, 126, 12>>
  ```
  """
  @spec checksum(data :: binary(), _opts :: term()) :: binary()
  def checksum(data, _opts), do: :erlang.crc32(data) |> :binary.encode_unsigned()

  @doc """
  Returns node reference as `Node.self()` converted to string with length limited to 255 characters.

  ```elixir
  iex(1)> MeshxRpc.Protocol.Default.node_ref()
  "nonode@nohost"
  ```
  """
  @spec node_ref() :: binary()
  def node_ref(), do: Node.self() |> to_string() |> String.slice(0..255)

  @doc """
  Returns connection reference as 4 bytes random binary.

  ```elixir
  iex(1)> MeshxRpc.Protocol.Default.conn_ref()
  <<171, 248, 41, 163>>
  iex(2)> MeshxRpc.Protocol.Default.conn_ref() |> Base.encode64(padding: false)
  "IKWzCw"
  ```
  """
  @spec conn_ref() :: binary()
  def conn_ref(), do: :rand.uniform(@int32_max) |> :binary.encode_unsigned()

  @doc """
  Serializes given Erlang `term` to binary with `:erlang.term_to_binary/2`.

  If successful function returns serialized binary as `result` and `serialization_flag`.

  If user provided `term` is of binary type, serialization step is skipped and `serialization_flag = 0`.
  Otherwise `:erlang.term_to_binary(term, opts)` is called and `serialization_flag` is set to `1`.

  Function argument `opts` is passed as options to `:erlang.term_to_binary/2`. Options can be used to force binary data compression, which by default is disabled.

  ```elixir
  iex(1)> {:ok, bin, ser_flag} = MeshxRpc.Protocol.Default.serialize(%{test_k: "test_v"}, [])
  {:ok,
  <<131, 116, 0, 0, 0, 1, 100, 0, 6, 116, 101, 115, 116, 95, 107, 109, 0, 0, 0,
   6, 116, 101, 115, 116, 95, 118>>, 1}
  iex(2)> MeshxRpc.Protocol.Default.deserialize(bin, [], ser_flag)
  {:ok, %{test_k: "test_v"}}
  iex(3)> {:ok, bin, ser_flag} = MeshxRpc.Protocol.Default.serialize("test", [])
  {:ok, "test", 0}
  iex(4)> MeshxRpc.Protocol.Default.deserialize(bin, [], ser_flag)
  {:ok, "test"}
  ```
  """
  @spec serialize(term :: term(), opts :: Keyword.t()) ::
          {:ok, result :: binary(), serialization_flag :: 0..255} | {:error, reason :: term()}
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

  @doc """
  De-serializes given `bin` to Erlang term with `:erlang.binary_to_term/2`.

  Function performs reverse operation to `serialize/2`. If `serialization_flag` is `0` de-serialization step is skipped and function returns `{:ok, bin}`. Otherwise `bin` is de-serialized using `:erlang.binary_to_term/2`.

  `opts` argument is passed to `:erlang.binary_to_term/2`. `serialize/2` provides usage example.
  """
  @spec deserialize(bin :: binary(), opts :: Keyword.t(), serialization_flag :: 0..255) ::
          {:ok, result :: term()} | {:error, reason :: term}
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
