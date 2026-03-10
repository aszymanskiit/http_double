defmodule HttpDouble.Server do
  @moduledoc """
  OTP process that runs an HTTP server via Plug.Cowboy, holds static routes
  and mock rules, and records HTTP call history.

  Users normally interact with this module indirectly via the `HttpDouble`
  facade, but the functions here are public to make supervision and advanced
  control easier when needed.
  """

  use GenServer

  require Logger
  alias HttpDouble.{MockEngine, MockRule, PlugAdapter, Request, Route}

  @typedoc "Internal server mode."
  @type mode :: :mock_first | :routes_only | :mock_only

  @typedoc "Server state kept in the GenServer."
  @type t :: %__MODULE__{
          cowboy_ref: reference() | nil,
          port: non_neg_integer() | nil,
          ip: :inet.ip_address(),
          host: String.t(),
          mode: mode(),
          routes: [Route.t()],
          rules: [MockRule.t()],
          calls: [HttpDouble.call_record()],
          max_calls: pos_integer(),
          next_conn_id: non_neg_integer()
        }

  defstruct cowboy_ref: nil,
            port: nil,
            ip: {127, 0, 0, 1},
            host: "127.0.0.1",
            mode: :mock_first,
            routes: [],
            rules: [],
            calls: [],
            max_calls: 1_000,
            next_conn_id: 1

  ## Public API

  @doc """
  Starts a new server process.

  Options:

    * `:port` – TCP port to listen on (0 = random free port, default)
    * `:ip` – IP tuple to bind to (defaults to `{127, 0, 0, 1}`)
    * `:host` – logical host string reported by `HttpDouble.host/1` (defaults to `"127.0.0.1"`)
    * `:routes` – list of static route definitions
    * `:mode` – `:mock_first` (default), `:routes_only`, or `:mock_only`
    * `:name` – optional registered name (e.g. via `Registry`)
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name_opt =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, name_opt)
  end

  @doc """
  Returns a child spec suitable for supervision trees.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Registers a new stub or expectation rule.

  This is the backing implementation for `HttpDouble.stub/2`, `stub/3`
  and `HttpDouble.expect/3`.
  """
  @spec add_rule(GenServer.server(), MockRule.kind(), Keyword.t()) ::
          {:ok, reference()}
  def add_rule(server, kind, opts) when kind in [:stub, :expect] do
    GenServer.call(server, {:add_rule, kind, opts})
  end

  @doc """
  Adds one or more static routes at runtime.
  """
  @spec add_routes(GenServer.server(), [map()]) :: :ok
  def add_routes(server, route_specs) do
    GenServer.call(server, {:add_routes, route_specs})
  end

  @doc """
  Replaces the full static route table.
  """
  @spec set_routes(GenServer.server(), [map()]) :: :ok
  def set_routes(server, route_specs) do
    GenServer.call(server, {:set_routes, route_specs})
  end

  @doc """
  Updates a single route identified by `:id` or by `{method, path}`.
  """
  @spec update_route(GenServer.server(), map()) :: :ok
  def update_route(server, route_spec) do
    GenServer.call(server, {:update_route, route_spec})
  end

  @doc """
  Deletes a route identified by `:id` or by `{method, path}`.
  """
  @spec delete_route(GenServer.server(), map()) :: :ok
  def delete_route(server, route_spec) do
    GenServer.call(server, {:delete_route, route_spec})
  end

  @doc """
  Returns the list of recorded calls, ordered from oldest to newest.
  """
  @spec calls(GenServer.server()) :: [HttpDouble.call_record()]
  def calls(server) do
    GenServer.call(server, :calls)
  end

  @doc """
  Resets the server state (routes, rules, history).
  """
  @spec reset!(GenServer.server()) :: :ok
  def reset!(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Returns the TCP port the server is listening on.
  """
  @spec port(GenServer.server()) :: non_neg_integer()
  def port(server) do
    GenServer.call(server, :port)
  end

  @doc """
  Returns the logical host string reported by the server.
  """
  @spec host(GenServer.server()) :: String.t()
  def host(server) do
    GenServer.call(server, :host)
  end

  @doc """
  Returns a convenient endpoint map `%{host, port, base_url}`.
  """
  @spec endpoint(GenServer.server()) :: HttpDouble.endpoint()
  def endpoint(server) do
    GenServer.call(server, :endpoint)
  end

  @doc """
  Handles a single request (Plug.Conn). Called from HttpDouble.Plug.

  Reads the request body, converts to HttpDouble.Request, dispatches via the
  server state, and returns a Plug.Conn response.
  """
  @spec serve_plug_conn(Plug.Conn.t(), GenServer.server()) :: Plug.Conn.t()
  def serve_plug_conn(conn, server) do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = PlugAdapter.conn_to_request(conn, body, 0, 0)
    resp_spec = GenServer.call(server, {:handle_request, request})
    PlugAdapter.response_spec_to_conn(conn, resp_spec)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    mode = Keyword.get(opts, :mode, :mock_first)

    unless mode in [:mock_first, :routes_only, :mock_only] do
      raise ArgumentError, "invalid :mode option: #{inspect(mode)}"
    end

    port = Keyword.get(opts, :port, 0)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    host = Keyword.get(opts, :host, "127.0.0.1")
    routes = Keyword.get(opts, :routes, []) |> Enum.map(&Route.from_spec/1)

    cowboy_ref = make_ref()

    # Pass registered name if any so the Plug can resolve current pid after restarts; else pass self().
    # Optional :plug_server_resolver e.g. {Module, :fun} is called when whereis returns nil (e.g. cross-node).
    plug_opts =
      [server: Keyword.get(opts, :name) || self()]
      |> maybe_add_resolver(opts)

    case Plug.Cowboy.http(HttpDouble.Plug, plug_opts,
           port: port,
           ref: cowboy_ref,
           ip: ip
         ) do
      {:ok, _cowboy_pid} ->
        # Do not link to Cowboy so that terminate/2 can shut it down without
        # the Server receiving EXIT and exiting with :shutdown (which would
        # kill linked test processes).
        :ok

      {:error, :eaddrinuse} ->
        raise "HttpDouble: port #{port} already in use. Stop the process using it or choose another port."

      {:error, reason} ->
        raise "HttpDouble: failed to start Cowboy: #{inspect(reason)}"
    end

    actual_port = if port == 0, do: :ranch.get_port(cowboy_ref), else: port

    Logger.info(
      "[HttpDouble.Server] listening on #{host}:#{actual_port} mode=#{mode} routes=#{length(routes)}"
    )

    state = %__MODULE__{
      mode: mode,
      cowboy_ref: cowboy_ref,
      port: actual_port,
      ip: ip,
      host: host,
      routes: routes
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:handle_request, %Request{} = req}, _from, state) do
    conn_id = state.next_conn_id
    request_index = length(state.calls)
    req = %{req | conn_id: conn_id, request_index: request_index}
    state = %{state | next_conn_id: conn_id + 1}

    Logger.info(
      "[HttpDouble.Server] request conn_id=#{conn_id} #{req.method} #{req.path} mode=#{state.mode}"
    )

    # Run dispatch in an unlinked task so route callbacks run in a different process. This avoids
    # "process attempted to call itself" when the Cowboy/Hackney pool process would otherwise
    # run code that uses the same pool. If the task crashes we return 500 and keep the Server alive.
    {resp_spec, new_state, rule_id, route_id} =
      case mockserver_control(req, state) do
        nil ->
          task =
            Task.Supervisor.async_nolink(HttpDouble.TaskSupervisor, fn ->
              dispatch_request(req, state)
            end)

          case Task.yield(task, 15_000) || Task.shutdown(task) do
            {:ok, result} ->
              result

            {:exit, reason} ->
              Logger.warning("[HttpDouble.Server] dispatch task exited: #{inspect(reason)}")
              {%{status: 500, body: "Internal Server Error"}, state, nil, nil}

            nil ->
              Logger.warning("[HttpDouble.Server] dispatch task timeout")
              {%{status: 504, body: "Gateway Timeout"}, state, nil, nil}
          end

        result ->
          result
      end

    call_record = %{
      conn_id: conn_id,
      request: req,
      timestamp: System.system_time(:millisecond),
      rule_id: rule_id,
      route_id: route_id,
      action: resp_spec
    }

    calls = [call_record | new_state.calls] |> Enum.take(new_state.max_calls)
    state = %{new_state | calls: calls}

    {:reply, resp_spec, state}
  end

  @impl GenServer
  def handle_call({:request, _conn_id, %Request{} = req}, _from, state) do
    # Legacy path for custom TCP connections; same dispatch as handle_request.
    Logger.info(
      "[HttpDouble.Server] request conn_id=#{req.conn_id} #{req.method} #{req.path} mode=#{state.mode}"
    )

    {resp_spec, new_state, rule_id, route_id} = dispatch_request(req, state)

    call_record = %{
      conn_id: req.conn_id,
      request: req,
      timestamp: System.system_time(:millisecond),
      rule_id: rule_id,
      route_id: route_id,
      action: resp_spec
    }

    calls = [call_record | new_state.calls] |> Enum.take(new_state.max_calls)
    state = %{new_state | calls: calls}

    {:reply, resp_spec, state}
  end

  @impl GenServer
  def handle_call({:add_routes, route_specs}, _from, state) do
    new_routes = Enum.map(route_specs, &Route.from_spec/1)
    {:reply, :ok, %{state | routes: state.routes ++ new_routes}}
  end

  @impl GenServer
  def handle_call({:set_routes, route_specs}, _from, state) do
    new_routes = Enum.map(route_specs, &Route.from_spec/1)
    {:reply, :ok, %{state | routes: new_routes}}
  end

  @impl GenServer
  def handle_call({:update_route, route_spec}, _from, state) do
    updated_routes = Route.update_in_list(state.routes, route_spec)
    {:reply, :ok, %{state | routes: updated_routes}}
  end

  @impl GenServer
  def handle_call({:delete_route, route_spec}, _from, state) do
    remaining_routes = Route.delete_from_list(state.routes, route_spec)
    {:reply, :ok, %{state | routes: remaining_routes}}
  end

  @impl GenServer
  def handle_call({:add_rule, kind, opts}, _from, state) do
    rule = MockRule.build(kind, opts)
    {:reply, {:ok, rule.id}, %{state | rules: [rule | state.rules]}}
  end

  @impl GenServer
  def handle_call(:calls, _from, state) do
    {:reply, Enum.reverse(state.calls), state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | rules: [],
        routes: [],
        calls: []
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def handle_call(:host, _from, state) do
    {:reply, state.host, state}
  end

  @impl GenServer
  def handle_call(:endpoint, _from, state) do
    base_url = "http://" <> state.host <> ":" <> Integer.to_string(state.port)

    endpoint = %{
      host: state.host,
      port: state.port,
      base_url: base_url
    }

    {:reply, endpoint, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.cowboy_ref do
      Plug.Cowboy.shutdown(state.cowboy_ref)
    end

    :ok
  end

  ## MockServer-compat (PUT /expectation, PUT /mockserver/clear, PUT /reset, PUT /verify)
  ## Method is normalised so both atom :put (from Plug) and string "PUT" match.

  defp mockserver_control(%Request{method: method, path: "/mockserver/clear"}, state) do
    if norm_method(method) == "PUT" do
      # Clear rules and call history so verify (e.g. want=0) sees 0 calls after clear.
      new_state = %{state | rules: [], calls: []}
      {%{status: 200}, new_state, nil, nil}
    else
      nil
    end
  end

  defp mockserver_control(%Request{method: method, path: "/reset"}, state) do
    if norm_method(method) == "PUT" do
      new_state = %{state | rules: [], calls: []}
      Logger.info("[HttpDouble.Server] mockserver reset (rules and calls cleared)")
      {%{status: 200}, new_state, nil, nil}
    else
      nil
    end
  end

  # AuthUtils (JWKS) uses PUT /verify; TransFrameProductsClientUtils uses PUT /mockserver/verify. Same semantics.
  defp mockserver_control(%Request{method: method, path: path, body: body}, state)
       when path in ["/verify", "/mockserver/verify"] do
    if norm_method(method) == "PUT" do
      case Jason.decode(body) do
        {:ok, %{"httpRequest" => req_spec, "times" => times} = _full} ->
          {want_path, path_regex?} =
            case req_spec do
              %{"pathRegex" => pat} when is_binary(pat) ->
                {pat, true}

              %{"path" => pat} when is_binary(pat) ->
                {pat, path_has_wildcards?(pat)}

              _ ->
                {"/", false}
            end

          method = (req_spec["method"] || "GET") |> String.upcase()
          # Support MockServer-style times: count/exact or atLeast+atMost (equal => exact).
          want_count = times["atMost"] || times["atLeast"] || times["count"] || 1

          exact =
            (times["atLeast"] != nil and times["atMost"] != nil and
               times["atLeast"] == times["atMost"]) or times["exact"] == true

          {count, _re} =
            state.calls
            |> Enum.reduce({0, nil}, fn %{request: req}, {acc, re} ->
              path_ok =
                cond do
                  path_regex? and is_binary(want_path) ->
                    compiled =
                      case re do
                        %Regex{} = already -> already
                        _ -> Regex.compile!(want_path)
                      end

                    Regex.match?(compiled, norm_path(req.path))

                  true ->
                    norm_path(req.path) == norm_path(want_path)
                end

              if path_ok and norm_method(req.method) == method do
                {acc + 1, if(path_regex?, do: (re || Regex.compile!(want_path)), else: re)}
              else
                {acc, re}
              end
            end)

          status = verify_match(count, want_count, exact)

          Logger.info(
            "[HttpDouble.Server] verify #{method} #{want_path} count=#{count} want=#{want_count} exact=#{exact} -> #{status}"
          )

          {%{status: status}, state, nil, nil}

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp mockserver_control(%Request{method: method, path: "/expectation", body: body}, state) do
    if norm_method(method) == "PUT" do
      case Jason.decode(body) do
        {:ok, %{"httpRequest" => req_spec, "httpResponse" => resp_spec} = full} ->
          method = (req_spec["method"] || "GET") |> String.upcase()
          path = req_spec["path"] || "/"
          status = resp_spec["statusCode"] || 200
          body_obj = resp_spec["body"] || %{}

          times = full["times"] || %{}

          max_calls =
            cond do
              times["unlimited"] == true -> :infinity
              r = times["remainingTimes"] -> coerce_remaining_times(r)
              true -> :infinity
            end

          response_body =
            if status >= 500 and status < 600 and body_obj == %{} do
              # Avoid returning "{}" for 5xx so logs are clearer (e.g. Auth.JWT.PublicKey).
              "Service Unavailable"
            else
              mockserver_body_bytes(body_obj)
            end

          delay_ms =
            case resp_spec["delay"] do
              %{"timeUnit" => unit, "value" => value} ->
                ms =
                  case {unit, value} do
                    {"SECONDS", v} when is_number(v) -> trunc(v * 1000)
                    {"MILLISECONDS", v} when is_number(v) -> trunc(v)
                    _ -> 0
                  end

                if ms > 0, do: ms, else: nil

              _ ->
                nil
            end

          matcher =
            if path_has_wildcards?(path) do
              %{
                method: method,
                path_regex: Regex.compile!(path)
              }
            else
              %{
                method: method,
                path: path
              }
            end

          base_response = %{status: status, body: response_body}

          respond_spec =
            case delay_ms do
              nil -> base_response
              ms -> {:delay, ms, base_response}
            end

          rule =
            MockRule.build(:stub,
              matcher: matcher,
              respond: respond_spec,
              max_calls: max_calls
            )

          # Append so expectations are consumed in the order they were added (FIFO).
          new_state = %{state | rules: state.rules ++ [rule]}

          Logger.info(
            "[HttpDouble.Server] mockserver expectation added #{method} #{path} -> #{status}"
          )

          # 201 for compatibility with tests that expect MockServer-style "expectation created".
          {%{status: 201}, new_state, nil, nil}

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp mockserver_control(_, _), do: nil

  defp verify_match(count, want, true) when count == want, do: 202
  defp verify_match(_, _, true), do: 417
  defp verify_match(count, want, _) when count >= want, do: 202
  defp verify_match(_, _, _), do: 417

  defp norm_path(""), do: "/"

  defp norm_path(p) when is_binary(p),
    do: p |> String.trim_trailing("/") |> then(&if &1 == "", do: "/", else: &1)

  defp norm_method(m) when is_atom(m), do: m |> Atom.to_string() |> String.upcase()
  defp norm_method(m) when is_binary(m), do: String.upcase(m)

  defp path_has_wildcards?(path) when is_binary(path) do
    String.contains?(path, ".*")
  end

  defp path_has_wildcards?(_), do: false

  defp maybe_add_resolver(plug_opts, opts) do
    case Keyword.get(opts, :plug_server_resolver) do
      {_mod, _fun} = resolver -> Keyword.put(plug_opts, :server_resolver, resolver)
      _ -> plug_opts
    end
  end

  defp coerce_remaining_times(n) when is_integer(n) and n >= 0, do: n

  defp coerce_remaining_times(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n >= 0 -> n
      _ -> :infinity
    end
  end

  defp coerce_remaining_times(_), do: :infinity

  defp mockserver_body_bytes(%{"type" => "JSON", "json" => encoded}) when is_binary(encoded),
    do: encoded

  defp mockserver_body_bytes(%{"type" => "STRING", "string" => s}) when is_binary(s), do: s
  defp mockserver_body_bytes(%{} = map), do: Jason.encode!(map)
  defp mockserver_body_bytes(_), do: ""

  ## Dispatch (shared by handle_request and legacy :request)

  defp inspect_status(%{status: s}), do: "status=#{s}"
  defp inspect_status(other), do: inspect(other)

  defp dispatch_request(req, state) do
    case state.mode do
      :routes_only ->
        {route_resp, route_id} = dispatch_routes(state.routes, req)

        Logger.info(
          "[HttpDouble.Server] routes_only -> route_id=#{inspect(route_id)} resp=#{inspect_status(route_resp)}"
        )

        {route_resp, state, nil, route_id}

      mode when mode in [:mock_first, :mock_only] ->
        result =
          MockEngine.apply(state.rules, req, req.conn_id, mode, fn ->
            dispatch_routes(state.routes, req)
          end)

        state1 = %{state | rules: result.rules}

        case result.response do
          {:no_route, default} ->
            {default, state1, nil, nil}

          # Route fallback returns {response_spec, route_id} with a reference
          {resp, route_id} when is_reference(route_id) ->
            {resp, state1, result.rule_id, route_id}

          # Matched mock rule: map or other response_spec (e.g. {:delay, ms, _}, :close, {:raw, _})
          resp ->
            {resp, state1, result.rule_id, nil}
        end
    end
  end

  @spec dispatch_routes([Route.t()], Request.t()) ::
          {HttpDouble.response_spec(), reference() | nil}
  defp dispatch_routes(routes, %Request{} = req) do
    case Route.find_match(routes, req) do
      {:ok, route, response_spec} ->
        Logger.info(
          "[HttpDouble.Server] route matched #{req.method} #{req.path} -> #{inspect_status(response_spec)}"
        )

        {response_spec, route.id}

      :nomatch ->
        Logger.warning(
          "[HttpDouble.Server] no route for #{req.method} #{req.path} (#{length(routes)} routes), returning 404"
        )

        {%{status: 404, body: "Not found"}, nil}
    end
  end
end
