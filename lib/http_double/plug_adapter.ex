defmodule HttpDouble.PlugAdapter do
  @moduledoc """
  Converts between Plug.Conn and HttpDouble.Request/response_spec.

  Used when HttpDouble runs on Plug.Cowboy: the Plug forwards every request
  to the Server, which returns a response_spec; this module turns that into
  a Plug.Conn response.
  """

  require Logger
  alias HttpDouble.{Request, Response}

  @doc """
  Builds an HttpDouble.Request from a Plug.Conn (after body has been read).

  `conn_id` and `request_index` should be set by the caller (Server).
  """
  @spec conn_to_request(Plug.Conn.t(), binary(), non_neg_integer(), non_neg_integer()) ::
          Request.t()
  def conn_to_request(conn, body, conn_id, request_index) do
    path = conn.request_path |> String.split("?") |> List.first() |> then(&(&1 || "/"))
    raw_path = conn.request_path

    query =
      conn.query_params
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), normalize_query_value(v)} end)

    headers =
      conn.req_headers
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    %Request{
      method: conn.method,
      path: path,
      raw_path: raw_path,
      query: query,
      http_version: "HTTP/1.1",
      headers: headers,
      body: body || "",
      host: conn.host,
      port: conn.port,
      conn_id: conn_id,
      request_index: request_index
    }
  end

  @doc """
  Sends the response_spec back through the Plug.Conn.

  Supports: map/struct (status, body, json, headers), and {:delay, ms, inner}.
  Other specs (e.g. :timeout, :close, {:fun, _}) are simplified to a 200 empty response.
  """
  @spec response_spec_to_conn(Plug.Conn.t(), HttpDouble.response_spec()) :: Plug.Conn.t()
  def response_spec_to_conn(conn, spec) do
    case spec do
      {:delay, ms, inner} ->
        Process.sleep(ms)
        response_spec_to_conn(conn, inner)

      :timeout ->
        # Delay so the client can get a recv timeout; then send 504.
        Process.sleep(2_000)
        Plug.Conn.send_resp(conn, 504, "Gateway Timeout")

      :close ->
        conn
        |> Plug.Conn.put_resp_header("connection", "close")
        |> Plug.Conn.send_resp(200, "")

      %{status: status} = map when is_map(map) ->
        apply_simple_response(conn, map, status)

      %Response{status: status} = struct ->
        map = %{
          status: status,
          headers: struct.headers,
          body: struct.body,
          json: struct.json
        }

        apply_simple_response(conn, map, status)

      {:raw, iodata} ->
        body = IO.iodata_to_binary(iodata)
        Plug.Conn.send_resp(conn, 200, body)

      {:partial, chunks} when is_list(chunks) ->
        body = Enum.map_join(chunks, "", &IO.iodata_to_binary/1)
        Plug.Conn.send_resp(conn, 200, body)

      _ ->
        Logger.warning(
          "[HttpDouble.PlugAdapter] unsupported response_spec, sending 200: #{inspect(spec)}"
        )

        Plug.Conn.send_resp(conn, 200, "")
    end
  end

  defp apply_simple_response(conn, map, status) do
    {body, content_type} =
      case Map.get(map, :json) do
        nil ->
          {Map.get(map, :body, "") |> IO.iodata_to_binary(), "text/plain; charset=utf-8"}

        data ->
          {Jason.encode!(data), "application/json"}
      end

    headers = Map.get(map, :headers, [])

    conn
    |> Plug.Conn.put_resp_content_type(content_type, "utf-8")
    |> put_resp_headers(headers)
    |> Plug.Conn.send_resp(status, body)
  end

  defp normalize_query_value(v) when is_list(v), do: (List.first(v) || "") |> to_string()
  defp normalize_query_value(v), do: to_string(v)

  defp put_resp_headers(conn, []), do: conn

  defp put_resp_headers(conn, [{name, value} | rest]) do
    conn
    |> Plug.Conn.put_resp_header(to_string(name), to_string(value))
    |> put_resp_headers(rest)
  end
end
