defmodule HttpDouble do
  @moduledoc """
  Public API for starting and controlling dummy HTTP servers for integration tests.

  The main entry points are:

    * `start_link/1` – start a new HTTP dummy server
    * `child_spec/1` – embed the server directly in your supervision tree
    * `stub/2` and `stub/3` – define stub rules for HTTP requests
    * `expect/3` – define expectation rules for HTTP requests
    * route management helpers – `add_route/2`, `add_routes/2`, `set_routes/2`,
      `update_route/2`, `delete_route/2`
    * `calls/1` – fetch the history of received requests
    * `reset!/1` – reset server state between tests
    * `host/1`, `port/1`, `endpoint/1`, `url/2` – discover where the server is listening
    * `stop/1` – stop the server

  See the project README for more detailed examples.
  """

  @typedoc "A server reference; can be a PID or a registered name."
  @type server :: GenServer.server()

  @typedoc """
  Matcher used to select which HTTP requests should be affected by a stub/expectation.

  Supported shapes:

    * `:any` – match any request
    * `{:method, method}` – e.g. `{:method, :get}` or `{:method, "POST"}`
    * `{:path, path}` – exact path match, e.g. `{:path, "/health"}`
    * `{:prefix, prefix}` – prefix path match, e.g. `{:prefix, "/api"}`
    * `{:path_regex, re}` – regular expression on the request path
    * `{:route, method, path}` – method + path match
    * `{:fn, fun}` – predicate `fun.(request, meta) :: boolean`
    * a map with keys like `:method`, `:path`, `:host`, `:query`, `:headers`, `:body`
      that will be interpreted by `HttpDouble.MockRule`
  """
  @type matcher ::
          :any
          | {:method, atom() | String.t()}
          | {:path, String.t()}
          | {:prefix, String.t()}
          | {:path_regex, Regex.t()}
          | {:route, atom() | String.t(), String.t()}
          | {:fn, (HttpDouble.Request.t(), HttpDouble.MockRule.meta() -> boolean())}
          | map()

  @typedoc """
  Response specification used by stubs, expectations and static routes.

  Supported forms:

    * simple maps:
      * `%{status: 200, body: "ok"}`
      * `%{status: 201, json: %{result: "accepted"}}`
      * `%{status: 204}` (empty body)
    * explicit response struct `HttpDouble.Response.t()`
    * `{:delay, ms, inner}` – delay sending `inner` by `ms` milliseconds
    * `:timeout` or `:no_reply` – do not send any reply
    * `:close` – immediately close the TCP connection
    * `{:close, inner}` – send `inner` then close the connection
    * `{:raw, iodata}` – send raw bytes as-is (can be invalid HTTP)
    * `{:partial, [iodata()]}` – send raw chunks one by one
    * `{:fun, fun}` – callback `fun.(request, meta) :: response_spec`
    * a non-empty list of response specs – used sequentially per matcher
  """
  @type response_spec ::
          map()
          | HttpDouble.Response.t()
          | {:delay, non_neg_integer(), response_spec()}
          | :timeout
          | :no_reply
          | :close
          | {:close, response_spec()}
          | {:raw, iodata()}
          | {:partial, [iodata()]}
          | {:fun, (HttpDouble.Request.t(), HttpDouble.MockRule.meta() -> response_spec())}
          | [response_spec()]

  @typedoc """
  A recorded HTTP call, suitable for assertions in tests.
  """
  @type call_record :: %{
          conn_id: non_neg_integer(),
          request: HttpDouble.Request.t(),
          timestamp: integer(),
          rule_id: reference() | nil,
          route_id: reference() | nil,
          action: term()
        }

  @typedoc """
  Endpoint information for pointing external systems (for example ejabberd)
  at a running HttpDouble instance.
  """
  @type endpoint :: %{
          host: String.t(),
          port: non_neg_integer(),
          base_url: String.t()
        }

  @doc """
  Starts a new dummy HTTP server.

  Options:

    * `:port` – TCP port to listen on (defaults to `0`, meaning a random free port)
    * `:host` – logical host name to report in `endpoint/1` (default: `"127.0.0.1"`)
    * `:ip` – IP tuple to bind to (default: `{127, 0, 0, 1}`)
    * `:routes` – list of static route definitions (see README for examples)
    * `:mode` – one of:
      * `:mock_first` (default) – try mock rules first, fall back to static routes
      * `:routes_only` – ignore mock rules, use only static routes
      * `:mock_only` – only apply mock rules, unknown requests are 404
    * `:name` – optional registered name (via `Registry.HttpDouble.ServerRegistry`)
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    HttpDouble.Server.start_link(opts)
  end

  @doc """
  Returns a `child_spec/1` suitable for embedding the server under a supervisor.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    HttpDouble.Server.child_spec(opts)
  end

  @doc """
  Adds a stub rule using an options keyword list.

  This is the most flexible form and supports all fields of `HttpDouble.MockRule`.
  """
  @spec stub(server(), Keyword.t()) :: {:ok, reference()}
  def stub(server, opts) when is_list(opts) do
    HttpDouble.Server.add_rule(server, :stub, opts)
  end

  @doc """
  Convenience stub form: `stub(server, matcher, response_spec)`.

  Examples:

      # Always return 200/\"ok\" for GET /health
      {:ok, _rule} =
        HttpDouble.stub(server, %{method: "GET", path: "/health"}, %{status: 200, body: "ok"})

      # Sequential responses for POST /api/messages
      {:ok, _rule} =
        HttpDouble.stub(server, %{method: :post, path: "/api/messages"}, [
          %{status: 201, json: %{result: "accepted"}},
          %{status: 503, body: "unavailable"}
        ])
  """
  @spec stub(server(), matcher(), response_spec()) :: {:ok, reference()}
  def stub(server, matcher, response_spec) do
    HttpDouble.Server.add_rule(server, :stub, matcher: matcher, respond: response_spec)
  end

  @doc """
  Adds an expectation rule.

  Semantics are the same as for `stub/3`, but expectations are intended to be
  asserted via `calls/1` in your tests. The engine will keep track of how many
  times each expectation was used.
  """
  @spec expect(server(), matcher(), response_spec()) :: {:ok, reference()}
  def expect(server, matcher, response_spec) do
    HttpDouble.Server.add_rule(server, :expect, matcher: matcher, respond: response_spec)
  end

  @doc """
  Adds a single static route at runtime.
  """
  @spec add_route(server(), map()) :: :ok
  def add_route(server, route_spec) when is_map(route_spec) do
    HttpDouble.Server.add_routes(server, [route_spec])
  end

  @doc """
  Adds multiple static routes at runtime.
  """
  @spec add_routes(server(), [map()]) :: :ok
  def add_routes(server, route_specs) when is_list(route_specs) do
    HttpDouble.Server.add_routes(server, route_specs)
  end

  @doc """
  Replaces the full static route table at runtime.
  """
  @spec set_routes(server(), [map()]) :: :ok
  def set_routes(server, route_specs) when is_list(route_specs) do
    HttpDouble.Server.set_routes(server, route_specs)
  end

  @doc """
  Updates a single route, identified either by `:id` or by `{method, path}`.
  """
  @spec update_route(server(), map()) :: :ok
  def update_route(server, route_spec) when is_map(route_spec) do
    HttpDouble.Server.update_route(server, route_spec)
  end

  @doc """
  Deletes a route, identified either by `:id` or by `{method, path}`.
  """
  @spec delete_route(server(), map()) :: :ok
  def delete_route(server, route_spec) when is_map(route_spec) do
    HttpDouble.Server.delete_route(server, route_spec)
  end

  @doc """
  Returns the list of all HTTP calls observed by a server.
  """
  @spec calls(server()) :: [call_record()]
  def calls(server) do
    HttpDouble.Server.calls(server)
  end

  @doc """
  Resets the server state:

    * clears all routes
    * clears all mock rules and expectations
    * clears call history
  """
  @spec reset!(server()) :: :ok
  def reset!(server) do
    HttpDouble.Server.reset!(server)
  end

  @doc """
  Returns the TCP port the server is currently listening on.
  """
  @spec port(server()) :: non_neg_integer()
  def port(server) do
    HttpDouble.Server.port(server)
  end

  @doc """
  Returns the logical host the server advertises (for configuration injection).
  """
  @spec host(server()) :: String.t()
  def host(server) do
    HttpDouble.Server.host(server)
  end

  @doc """
  Returns a convenient endpoint map `%{host, port, base_url}` for pointing
  external systems (for example ejabberd) at this HttpDouble instance.
  """
  @spec endpoint(server()) :: endpoint()
  def endpoint(server) do
    HttpDouble.Server.endpoint(server)
  end

  @doc """
  Builds a full URL for a given path (string or list of segments) using the
  server's current endpoint.
  """
  @spec url(server(), String.t() | [String.t()]) :: String.t()
  def url(server, path) when is_binary(path) do
    %{base_url: base} = endpoint(server)
    base <> ensure_leading_slash(path)
  end

  def url(server, segments) when is_list(segments) do
    path = Enum.map_join(segments, "/", &URI.encode/1)
    url(server, "/" <> path)
  end

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  @doc """
  Stops the server gracefully.
  """
  @spec stop(server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end
end
