defmodule HttpDouble.Connection do
  @moduledoc """
  Per-client connection process.

  Each accepted TCP socket is owned by a `HttpDouble.Connection` process,
  which is responsible for:

    * reading bytes from the socket and buffering them
    * decoding HTTP/1.1 requests (including simple keep-alive)
    * sending requests to `HttpDouble.Server`
    * applying response specifications (including delays, timeouts, closes,
      partial/raw replies)
  """

  use GenServer

  require Logger
  alias HttpDouble.{Request, Response}

  defstruct socket: nil,
            server: nil,
            conn_id: nil,
            buffer: <<>>,
            closed?: false,
            request_index: 0

  @type t :: %__MODULE__{
          socket: port() | nil,
          server: pid() | nil,
          conn_id: non_neg_integer() | nil,
          buffer: binary(),
          closed?: boolean(),
          request_index: non_neg_integer()
        }

  @spec start_link(pid(), port(), non_neg_integer()) :: GenServer.on_start()
  def start_link(server, socket, conn_id) do
    GenServer.start_link(__MODULE__, {server, socket, conn_id})
  end

  @impl GenServer
  def init({server, socket, conn_id}) do
    state = %__MODULE__{socket: socket, server: server, conn_id: conn_id}
    GenServer.cast(server, {:register_connection_pid, conn_id, self()})
    Logger.info("[HttpDouble.Connection] conn_id=#{conn_id} started")
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:socket_ready, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} received #{byte_size(data)} bytes, buffer was #{byte_size(state.buffer)}"
    )

    buffer = state.buffer <> data
    {buffer, state} = process_buffer(buffer, state)
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} tcp_closed (peer closed), stopping"
    )

    cleanup_and_stop(state)
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} tcp_error reason=#{inspect(reason)}, stopping"
    )

    cleanup_and_stop(state)
  end

  def handle_info({:delayed_reply, request, response_spec}, state) do
    _ = apply_response_spec(response_spec, request, state)
    {:noreply, state}
  end

  defp process_buffer(buffer, state) do
    case parse_request(buffer, state) do
      {:ok, request, rest, new_state} ->
        Logger.info(
          "[HttpDouble.Connection] conn_id=#{state.conn_id} parsed #{request.method} #{request.path} (rest #{byte_size(rest)} bytes)"
        )

        try do
          state2 = handle_request(request, new_state)
          process_buffer(rest, state2)
        rescue
          err ->
            Logger.warning(
              "[HttpDouble.Connection] conn_id=#{state.conn_id} rescue: #{inspect(err)}, sending 500"
            )

            send_error_response(new_state, 500)
            {rest, new_state}
        end

      :more ->
        Logger.info(
          "[HttpDouble.Connection] conn_id=#{state.conn_id} parse :more (buffer #{byte_size(buffer)} bytes, need more data)"
        )

        {buffer, state}

      {:error, reason} ->
        Logger.warning(
          "[HttpDouble.Connection] conn_id=#{state.conn_id} parse error: #{inspect(reason)}, sending 400"
        )

        send_error_response(state, 400)
        # Discard up to and including \r\n\r\n so we don't reprocess the same bad request.
        rest =
          case :binary.match(buffer, "\r\n\r\n") do
            {pos, 4} -> binary_part(buffer, pos + 4, byte_size(buffer) - pos - 4)
            :nomatch -> <<>>
          end

        {rest, state}
    end
  end

  defp send_error_response(state, status) do
    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} send_error_response status=#{status}"
    )

    body = if status == 400, do: "Bad request", else: "Internal Server Error"

    bytes =
      Response.to_iodata(%{status: status, body: body}, nil)
      |> IO.iodata_to_binary()

    :gen_tcp.send(state.socket, bytes)
  end

  defp handle_request(%Request{} = request, state) do
    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} calling server #{request.method} #{request.path}"
    )

    case GenServer.call(state.server, {:request, state.conn_id, request}) do
      response_spec ->
        Logger.info(
          "[HttpDouble.Connection] conn_id=#{state.conn_id} got response_spec #{inspect_spec(response_spec)}, sending"
        )

        _ = apply_response_spec(response_spec, request, state)
        state
    end
  end

  defp inspect_spec(%{status: s}), do: "status=#{s}"
  defp inspect_spec(:close), do: ":close"
  defp inspect_spec(other), do: inspect(other)

  defp apply_response_spec({:delay, ms, inner}, request, _state) do
    Process.send_after(self(), {:delayed_reply, request, inner}, ms)
    :ok
  end

  defp apply_response_spec(:timeout, _request, _state), do: :ok
  defp apply_response_spec(:no_reply, _request, _state), do: :ok

  defp apply_response_spec(:close, _request, state) do
    Logger.warning(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} applying :close (closing socket)"
    )

    :gen_tcp.close(state.socket)
    :ok
  end

  defp apply_response_spec({:close, inner}, request, state) do
    _ = apply_response_spec(inner, request, state)

    Logger.warning(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} applying {:close, _} (closing socket)"
    )

    :gen_tcp.close(state.socket)
    :ok
  end

  defp apply_response_spec({:raw, bytes}, _request, state) do
    :gen_tcp.send(state.socket, bytes)
    :ok
  end

  defp apply_response_spec({:partial, chunks}, _request, state) when is_list(chunks) do
    Enum.each(chunks, fn chunk ->
      :gen_tcp.send(state.socket, chunk)
    end)

    :ok
  end

  defp apply_response_spec(%{} = spec, request, state) do
    status = Map.get(spec, :status, "?")

    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} sending response status=#{status}"
    )

    payload = Response.to_iodata(spec, request)
    :gen_tcp.send(state.socket, payload)

    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} sent #{byte_size(IO.iodata_to_binary(payload))} bytes"
    )

    :ok
  end

  defp apply_response_spec(%Response{} = resp, request, state) do
    Logger.info(
      "[HttpDouble.Connection] conn_id=#{state.conn_id} sending Response status=#{resp.status}"
    )

    payload = Response.to_iodata(resp, request)
    :gen_tcp.send(state.socket, payload)
    :ok
  end

  defp apply_response_spec(other, request, state) when is_list(other) do
    # Treat a bare list as a normal sequence of responses.
    Enum.each(other, fn spec ->
      _ = apply_response_spec(spec, request, state)
    end)

    :ok
  end

  defp apply_response_spec(other, request, state) when is_function(other, 1) do
    apply_response_spec(other.(request), request, state)
  end

  defp apply_response_spec(other, request, state) when is_function(other, 2) do
    meta = HttpDouble.MockRule.meta_from_request(request, nil)
    apply_response_spec(other.(request, meta), request, state)
  end

  defp apply_response_spec(_other, _request, _state), do: :ok

  defp cleanup_and_stop(state) do
    GenServer.cast(state.server, {:connection_closed, state.conn_id, self()})
    {:stop, :normal, %{state | closed?: true}}
  end

  ## Basic HTTP/1.1 request parsing

  @spec parse_request(binary(), t()) ::
          {:ok, Request.t(), binary(), t()} | :more | {:error, term()}
  defp parse_request(buffer, state) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        :more

      {header_end, 4} ->
        headers_part = binary_part(buffer, 0, header_end + 4)
        rest = binary_part(buffer, header_end + 4, byte_size(buffer) - header_end - 4)

        with {:ok, request_line, header_lines} <- split_header_lines(headers_part),
             {:ok, method, raw_path, version} <- parse_request_line(request_line),
             {:ok, headers} <- parse_headers(header_lines) do
          content_length =
            headers
            |> Enum.find_value(0, fn
              {"content-length", value} ->
                case Integer.parse(value) do
                  {n, ""} when n >= 0 -> n
                  _ -> 0
                end

              _ ->
                nil
            end)

          total_needed = content_length

          if byte_size(rest) < total_needed do
            :more
          else
            <<body::binary-size(total_needed), remaining::binary>> = rest

            {path, query} =
              case String.split(raw_path, "?", parts: 2) do
                [p] -> {p, %{}}
                [p, q] -> {p, decode_query(q)}
              end

            host =
              headers
              |> Enum.find_value(nil, fn
                {"host", val} -> val
                _ -> nil
              end)

            req = %Request{
              method: method,
              path: path,
              raw_path: raw_path,
              http_version: version,
              headers: headers,
              body: body,
              query: query,
              host: host,
              conn_id: state.conn_id,
              request_index: state.request_index + 1
            }

            new_state = %{state | request_index: state.request_index + 1}
            {:ok, req, remaining, new_state}
          end
        else
          _ ->
            first_line = headers_part |> String.split("\r\n") |> List.first()

            Logger.warning(
              "[HttpDouble.Connection] parse_request bad_request, first_line=#{inspect(first_line)}"
            )

            {:error, :bad_request}
        end
    end
  end

  defp split_header_lines(headers_part) do
    lines =
      headers_part
      |> String.split("\r\n")
      |> Enum.reject(&(&1 == ""))

    case lines do
      [request_line | header_lines] -> {:ok, request_line, header_lines}
      _ -> {:error, :bad_request}
    end
  end

  defp parse_request_line(line) do
    case String.split(line, " ", parts: 3) do
      [method, path, version] ->
        {:ok, String.upcase(method), path, version}

      _ ->
        {:error, :bad_request}
    end
  end

  defp parse_headers(lines) do
    headers =
      Enum.reduce_while(lines, [], fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, rest] ->
            value = String.trim_leading(rest)
            {:cont, [{String.downcase(name), value} | acc]}

          _ ->
            {:halt, :error}
        end
      end)

    case headers do
      :error -> {:error, :bad_headers}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp decode_query(qs) do
    URI.decode_query(qs)
  rescue
    _ -> %{}
  end
end
