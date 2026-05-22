# HttpDouble

[![CI](https://github.com/aszymanskiit/http_double/actions/workflows/ci.yml/badge.svg)](https://github.com/aszymanskiit/http_double/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/http_double.svg)](https://hex.pm/packages/http_double)
[![Documentation](https://img.shields.io/badge/hexdocs-HttpDouble-blue)](https://hexdocs.pm/http_double)

**HttpDouble** is a controllable, HTTP/1.1 dummy server for **integration testing** in Elixir. It speaks real HTTP over TCP on a configurable (or random) port and gives you a programmatic API to stub responses, record requests, and inject faults (timeouts, connection drops, partial responses). The library’s **HTTP control API** (expectations, verification, reset, and related paths) is **compatible with [MockServer](https://www.mock-server.com/)** for the supported subset—see [MockServer compatibility](#mockserver-compatibility). It is designed for testing systems that call external HTTP endpoints—e.g. webhooks, REST APIs callbacks—without hitting the real network.

- **Package:** [hex.pm/packages/http_double](https://hex.pm/packages/http_double)
- **API docs (HexDocs):** [hexdocs.pm/http_double](https://hexdocs.pm/http_double)
- **Repository:** [github.com/aszymanskiit/http_double](https://github.com/aszymanskiit/http_double)
- **License:** MIT (see [LICENSE](LICENSE))
- **Changelog:** [CHANGELOG.md](CHANGELOG.md)
- **MockServer:** implementation includes a [MockServer-compatible](#mockserver-compatibility) control API ([mock-server.com](https://www.mock-server.com/))

---

## What does HttpDouble do?

HttpDouble is a **test double** for HTTP: a fake server your tests can start and control.

1. **Starts a real TCP server** that speaks HTTP/1.1 on a port you choose (or `0` for a random free port).
2. **You define behaviour** via static routes and/or dynamic stubs/expectations: status, headers, body, JSON, delays, timeouts, connection closes.
3. **Your application** (or the system under test) is configured to call `http://host:port/...` instead of the real service.
4. **You assert** on the requests HttpDouble received using `HttpDouble.calls(server)`.

It is **not** a production web server. It is a **test tool** with predictable behaviour, fast startup, and support for parallel tests.

---

## Features

- **Real TCP, real HTTP/1.1** – works with any HTTP client (HTTPoison, Req, `:httpc`, raw `:gen_tcp`, Plug/Cowboy in front).
- **Configurable or random port** – bind to `0` for an OS-assigned port, ideal for parallel tests.
- **Static routes** – define method + path (and optional host, query, headers, body); support prefix and regex path matching; responses as maps, structs, or callbacks.
- **Mock/stub engine** – match by method, path, host, query, headers, body, regex, call index, connection id; respond with constants, callbacks, lists (sequential responses), delays, timeouts, connection close, partial/raw bytes.
- **Full call history** – every request is recorded; assert on method, path, headers, body.
- **ExUnit integration** – `use HttpDouble.Case` gives you a fresh server per test and `http_server` / `http_endpoint` in context.
- **Multiple modes** – mock-first (stubs override routes), routes-only, or mock-only.
- **Fast and isolated** – one OTP process per server; safe for async tests.
- **MockServer-compatible control API** – `PUT /mockserver/expectation`, `/verify`, `/clear` (full or selective by matcher), `/reset`; JSON bodies with correct `Content-Type` for `body.type: JSON` (see [MockServer compatibility](#mockserver-compatibility)).

---

## MockServer compatibility

HttpDouble exposes an HTTP **control plane** on the **same port** as the mock traffic. Clients that already speak [MockServer](https://www.mock-server.com/)’s REST API (e.g. test helpers using `RestClient`, `:httpc`, or curl) can target HttpDouble **without** a separate JVM process.

This is an intentional **subset** of MockServer’s full API—not every endpoint, header, or JSON field behaves exactly like the reference implementation.

- **MockServer (documentation & product):** [mock-server.com](https://www.mock-server.com/)
- **MockServer (source):** [github.com/mock-server/mockserver](https://github.com/mock-server/mockserver)

### Supported control endpoints

| Method | Path(s) | Purpose |
|--------|---------|---------|
| `PUT` | `/expectation`, `/mockserver/expectation` | Register a dynamic expectation (stub rule) |
| `PUT` | `/verify`, `/mockserver/verify` | Assert how many times a request was received |
| `PUT` | `/clear`, `/mockserver/clear` | Remove expectation rules (all or selective) |
| `PUT` | `/reset`, `/mockserver/reset` | Clear **all** expectation rules and call history |

Path aliases (`/clear` vs `/mockserver/clear`, etc.) exist because different codebases in the wild use different prefixes.

**Important:** MockServer `clear` / `reset` affect only **dynamic expectation rules** and **call history**. **Static routes** configured at startup (`:routes`, `set_routes/2`, …) are unchanged. To wipe routes as well, use `HttpDouble.reset!/1` from Elixir.

### Registering expectations (`PUT /expectation`)

Body shape (JSON) follows MockServer: `httpRequest`, `httpResponse` or `httpError`, optional `times` (`unlimited`, `remainingTimes`).

```json
{
  "httpRequest": {
    "method": "GET",
    "path": "/api/rest/v1/employees/42/permissions"
  },
  "httpResponse": {
    "statusCode": 200,
    "body": {
      "type": "JSON",
      "json": "{\"total_items\": 1}",
      "contentType": "application/json"
    }
  },
  "times": { "unlimited": true }
}
```

- `body.type: "JSON"` with `json` as a **string** — response is sent with `Content-Type: application/json` (since 1.0.1).
- `body.type: "STRING"` with `string` — plain text; optional `contentType`.
- `httpError.dropConnection: true` — connection drop (`:close`), no HTTP response body.
- `httpResponse.delay` — optional delay before the response (MockServer-style `timeUnit` / `value`).

Expectation rules are evaluated in **`:mock_first`** mode before static routes; in **`:mock_only`** they are the only matchers besides 404.

### Verifying calls (`PUT /verify`)

```json
{
  "httpRequest": { "method": "GET", "path": "/api/example" },
  "times": { "atLeast": 1, "atMost": 1 }
}
```

Returns HTTP `202` when the match count satisfies `times`, otherwise `417`. Call history is read-only for verify; use `clear` to reset counts between scenarios.

### Clearing expectations (`PUT /clear`)

**Clear all** — empty body or `{}` removes every dynamic rule and clears call history:

```bash
curl -X PUT "http://127.0.0.1:PORT/mockserver/clear" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Selective clear** (since **1.0.2**) — only rules matching the request matcher are removed; other expectations and static routes stay:

```json
{
  "httpRequest": {
    "pathRegex": "^/api/rest/v1/context-access"
  }
}
```

Also supported:

- Wrapper form: `{ "httpRequest": { "method": "GET", "path": "/api/foo" } }`
- Top-level matcher (no wrapper): `{ "method": "GET", "path": "/api/foo" }` — same as some existing test utilities send to `/mockserver/clear`

Matching uses rule `method` + `path` (exact or prefix under a concrete path) or `pathRegex` against the rule’s path. Rules registered with a path regex in the expectation are matched against the clear regex when applicable.

Use selective clear when long-lived stubs (e.g. permissions for a fixed `setup_all` account) must survive per-test cleanup of another API surface.

### Reset vs Elixir `reset!/1`

| Mechanism | Dynamic rules | Call history | Static routes |
|-----------|---------------|--------------|---------------|
| `PUT /mockserver/clear` `{}` | cleared | cleared | kept |
| `PUT /mockserver/clear` selective | matching only | cleared | kept |
| `PUT /mockserver/reset` | cleared | cleared | kept |
| `HttpDouble.reset!/1` | cleared | cleared | **cleared** |

---

## Installation

Add HttpDouble as a dependency **only in test** (it is not for production).

```elixir
{:http_double, "~> 1.0.2", only: :test}
```

---

## Quick start

### 1. Start a server with a static route

```elixir
routes = [
  %{method: "GET", path: "/health", response: %{status: 200, body: "ok"}}
]

{:ok, server} = HttpDouble.start_link(port: 0, routes: routes, mode: :routes_only)

%{host: host, port: port, base_url: base_url} = HttpDouble.endpoint(server)
# base_url is e.g. "http://127.0.0.1:12345"

# Your app would GET base_url <> "/health" and receive 200 with body "ok"

HttpDouble.stop(server)
```

### 2. Use the ExUnit helper (recommended)

```elixir
defmodule MyApp.WebhookTest do
  use HttpDouble.Case, async: true

  test "webhook receives POST", %{http_server: server, http_endpoint: endpoint} do
    {:ok, _rule} =
      HttpDouble.stub(server, %{method: :post, path: "/webhook"}, %{
        status: 200,
        json: %{result: "ok"}
      })

    # Point your app at endpoint.base_url <> "/webhook" and trigger the flow...
    # Then assert:
    calls = HttpDouble.calls(server)
    assert Enum.any?(calls, fn %{request: req} ->
             req.method == "POST" and req.path == "/webhook"
           end)
  end
end
```

---

## Usage examples

### Starting the server

```elixir
# Random port (good for parallel tests)
{:ok, server} = HttpDouble.start_link(port: 0, mode: :mock_only)

# Fixed port
{:ok, server} = HttpDouble.start_link(port: 8081, routes: [], mode: :mock_only)

# With static routes and routes-only mode
routes = [
  %{method: "GET", path: "/health", response: %{status: 200, body: "ok"}},
  %{method: "POST", path: "/api/events", response: %{status: 201, json: %{id: "1"}}}
]
{:ok, server} = HttpDouble.start_link(port: 0, routes: routes, mode: :routes_only)
```

Options:

- `:port` – TCP port (`0` = random).
- `:host` – host string for `endpoint/1` (default `"127.0.0.1"`).
- `:routes` – list of static route maps.
- `:mode` – `:mock_first` (default), `:routes_only`, or `:mock_only`.
- `:name` – optional registered name.

### Getting the endpoint URL

```elixir
%{host: host, port: port, base_url: base_url} = HttpDouble.endpoint(server)

# Full URL for a path
url = HttpDouble.url(server, "/api/events")
# or with segments
url = HttpDouble.url(server, ["api", "events"])
```

Use `base_url` or `url(server, path)` when configuring the system under test (e.g. webhook URL for ejabberd).

### Stubbing a single response

```elixir
{:ok, server} = HttpDouble.start_link(port: 0, mode: :mock_only)

# Always 200 "ok" for GET /health
{:ok, _rule} =
  HttpDouble.stub(server, %{method: "GET", path: "/health"}, %{status: 200, body: "ok"})

# 201 with JSON for POST
{:ok, _rule} =
  HttpDouble.stub(server, %{method: :post, path: "/api/messages"}, %{
    status: 201,
    json: %{result: "accepted"}
  })
```

### Sequential responses (list)

```elixir
# First call -> 200 "ok", second call -> 503 "down"
{:ok, _rule} =
  HttpDouble.stub(server, %{method: :get, path: "/health"}, [
    %{status: 200, body: "ok"},
    %{status: 503, body: "down"}
  ])
```

### Fault injection: delay, timeout, close

```elixir
# 1st: 200 after 500 ms, 2nd: no reply (timeout), 3rd: close connection
{:ok, _rule} =
  HttpDouble.stub(server, %{method: :get, path: "/ping"}, [
    {:delay, 500, %{status: 200, body: "SLOW"}},
    :timeout,
    :close
  ])
```

### Expectations (same as stub, use for “must be called” assertions)

```elixir
{:ok, _rule} =
  HttpDouble.expect(server, %{method: :post, path: "/events"}, %{status: 202})

# Later: assert with HttpDouble.calls(server)
```

### Asserting on received requests (call history)

```elixir
calls = HttpDouble.calls(server)

# Each element: %{conn_id: _, request: %Request{}, timestamp: _, rule_id: _, route_id: _, action: _}
assert length(calls) >= 1
[%{request: req} | _] = calls
assert req.method == "POST"
assert req.path == "/webhook"
assert req.body =~ "payload"
assert {"content-type", _} in req.headers
```

### Dynamic routes at runtime

```elixir
{:ok, server} = HttpDouble.start_link(port: 0, mode: :routes_only)

HttpDouble.set_routes(server, [
  %{method: "GET", path: "/foo", response: %{status: 200, body: "foo"}}
])

# Update one route later
HttpDouble.update_route(server, %{method: "GET", path: "/foo", response: %{status: 200, body: "bar"}})

# Add / delete
HttpDouble.add_route(server, %{method: "GET", path: "/baz", response: %{status: 200, body: "baz"}})
HttpDouble.delete_route(server, %{method: "GET", path: "/foo"})
```

### Resetting state between tests

From Elixir (full wipe including static routes):

```elixir
HttpDouble.reset!(server)
# Clears static routes, mock/expectation rules, and call history
```

From HTTP (MockServer clients) — only dynamic rules and history; routes defined at `start_link` remain:

```elixir
# Via :httpc, Req, RestClient, etc. on the same base_url as the app under test:
# PUT base_url <> "/mockserver/clear"  body: "{}"
# PUT base_url <> "/mockserver/reset"
```

Prefer **selective** `PUT /mockserver/clear` with `path` / `pathRegex` when shared stubs must outlive a single test (see [Clearing expectations](#clearing-expectations-put-clear)).

### Using with ExUnit.Case context

When you `use HttpDouble.Case`, the context has `http_server` and `http_endpoint`. You can use the helper macros that take the context:

```elixir
test "stub via context", %{http_server: server, http_endpoint: _endpoint} do
  stub(server, %{method: "GET", path: "/ping"}, %{status: 200, body: "pong"})
  # or: HttpDouble.stub(server, ...)
end
```

---

## Public API summary

| Function | Description |
|----------|-------------|
| `start_link/1` | Start a new HTTP dummy server |
| `child_spec/1` | For use under a supervisor |
| `stub/2`, `stub/3` | Add a stub rule (matcher + response or keyword list) |
| `expect/3` | Add an expectation rule (same shape as stub) |
| `add_route/2`, `add_routes/2`, `set_routes/2`, `update_route/2`, `delete_route/2` | Manage static routes |
| `calls/1` | List of all recorded requests |
| `reset!/1` | Clear routes, rules, and call history |
| `host/1`, `port/1`, `endpoint/1`, `url/2` | Server address and URLs |
| `stop/1` | Stop the server |

Matchers can be a map (`%{method: ..., path: ...}`), or `:any`, `{:method, m}`, `{:path, p}`, `{:prefix, p}`, `{:path_regex, re}`, `{:route, method, path}`, `{:fn, fun}`. Response specs can be maps (with `:status`, `:body`, `:json`, `:headers`), `{:delay, ms, spec}`, `:timeout`, `:close`, `{:close, spec}`, `{:raw, iodata}`, `{:partial, [iodata]}`, `{:fun, fun}`, or a list of specs for sequential responses. For full API and types, see [HexDocs](https://hexdocs.pm/http_double) or run `mix docs` locally and open `doc/index.html`.

---

## Modes

- **`:mock_first`** (default) – Evaluate mock/stub rules first; if none match, fall back to static routes.
- **`:routes_only`** – Only static routes; mock rules are ignored.
- **`:mock_only`** – Only mock rules; no static routes. Unmatched requests get 404.

---

## Architecture (overview)

- **HttpDouble.Application** – Registry for optional server names.
- **HttpDouble.Server** – GenServer: TCP listener, connections, static routes, mock rules, call history.
- **HttpDouble.Connection** – One process per TCP connection: parse HTTP/1.1, apply response specs (including delay/close/partial).
- **HttpDouble.Request / Response** – Request and response representation and encoding.
- **HttpDouble.Route** – Static route matching.
- **HttpDouble.MockRule / MockEngine** – Rule representation and application.
- **HttpDouble.Case** – ExUnit case template that starts a server per test and injects `http_server` and `http_endpoint`.

---

## Limitations

HttpDouble is a **test double**, not a full HTTP stack:

- HTTP/1.1 over TCP only (no TLS, no HTTP/2/3).
- Request bodies: `Content-Length` supported; chunked request bodies are not.
- Keep-alive and pipelining work for typical clients; edge cases may differ.
- No automatic compression or advanced features.

For heavy real-world behaviour use a real server in system tests; use HttpDouble for **deterministic integration tests** and fault injection.

## Repository and license

- **Source:** [github.com/aszymanskiit/http_double](https://github.com/aszymanskiit/http_double)
- **License:** MIT – see [LICENSE](LICENSE).

You can use, copy, modify, merge, publish, distribute, sublicense, and sell copies of the software under the terms of the MIT License.
