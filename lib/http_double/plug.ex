defmodule HttpDouble.Plug do
  @moduledoc """
  Minimal Plug that forwards every request to HttpDouble.Server.
  Used when the server runs on Plug.Cowboy (not from the test process).
  """
  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    server = Keyword.fetch!(opts, :server)
    pid = resolve_server(server, opts)

    if pid && Process.alive?(pid) do
      HttpDouble.Server.serve_plug_conn(conn, pid)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "HttpDouble server not available")
    end
  end

  defp resolve_server(server, opts) do
    case do_resolve(server) do
      nil ->
        case Keyword.get(opts, :server_resolver) do
          {mod, fun} when is_atom(mod) and is_atom(fun) -> safe_resolver_call(mod, fun)
          _ -> nil
        end

      pid ->
        pid
    end
  end

  defp safe_resolver_call(mod, fun) do
    apply(mod, fun, [])
  catch
    :exit, _ -> nil
    :throw, _ -> nil
  end

  defp do_resolve(pid) when is_pid(pid), do: pid
  defp do_resolve(name), do: Process.whereis(name)
end
