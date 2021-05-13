defmodule MeshxRpc.App.T do
  @moduledoc false

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
