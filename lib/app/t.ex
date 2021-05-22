defmodule MeshxRpc.App.T do
  @moduledoc false

  def rand_retry(retry_time, rand_perc \\ 10)

  def rand_retry(retry_time, rand_perc) when is_integer(retry_time) and is_integer(rand_perc) do
    rand_perc = if rand_perc > 100, do: 100, else: rand_perc
    (retry_time + retry_time * (:rand.uniform(2 * rand_perc * 10) - rand_perc * 10) / 1000) |> round()
  end

  def rand_retry(retry_time, _rand_perc) when retry_time == :infinity, do: :infinity

  def merge_improper_keyword(li1, li2) do
    li = Keyword.merge(extract_2s(li1), extract_2s(li2))
    Enum.uniq(extract_1s(li1) ++ extract_1s(li2)) ++ li
  end

  defp extract_1s(li),
    do:
      Enum.map(li, fn el ->
        case el do
          {_k, _v} -> nil
          v -> v
        end
      end)
      |> Enum.reject(&is_nil/1)

  defp extract_2s(li),
    do:
      Enum.map(li, fn el ->
        case el do
          {k, v} -> {k, v}
          _v -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
end
