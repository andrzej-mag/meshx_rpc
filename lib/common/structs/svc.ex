defmodule MeshxRpc.Common.Structs.Svc do
  @moduledoc false
  defstruct [:node_ref, :svc_ref, :conn_ref]

  def init(node_ref_mfa, svc_ref_mfa, conn_ref_mfa),
    do: %__MODULE__{node_ref: parse_mfa(node_ref_mfa), svc_ref: parse_mfa(svc_ref_mfa), conn_ref: parse_mfa(conn_ref_mfa)}

  defp parse_mfa(mfa) do
    case mfa do
      {m, f, a} -> apply(m, f, a)
      a when is_atom(a) -> to_string(a)
      a when is_bitstring(a) -> a
    end
  end
end
