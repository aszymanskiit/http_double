defmodule HttpDouble.ServerIntegrationTest do
  use ExUnit.Case, async: true

  alias HttpDouble.Response

  test "simple GET with static route" do
    routes = [
      %{method: "GET", path: "/health", response: %{status: 200, body: "ok"}}
    ]

    {:ok, server} = HttpDouble.start_link(port: 0, routes: routes, mode: :routes_only)

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)

    assert data =~ "HTTP/1.1 200 OK"
    assert data =~ "\r\n\r\nok"

    :gen_tcp.close(socket)
    Process.unlink(server)
    HttpDouble.stop(server)
  end

  test "keep-alive with two sequential requests" do
    routes = [
      %{method: "GET", path: "/one", response: %{status: 200, body: "one"}},
      %{method: "GET", path: "/two", response: %{status: 200, body: "two"}}
    ]

    {:ok, server} = HttpDouble.start_link(port: 0, routes: routes, mode: :routes_only)
    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /one HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data1} = :gen_tcp.recv(socket, 0, 1_000)
    assert data1 =~ "HTTP/1.1 200 OK"
    assert data1 =~ "one"

    # Connection should still be alive for the second request.
    :ok = :gen_tcp.send(socket, "GET /two HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data2} = :gen_tcp.recv(socket, 0, 1_000)
    assert data2 =~ "HTTP/1.1 200 OK"
    assert data2 =~ "two"

    :gen_tcp.close(socket)
    Process.unlink(server)
    HttpDouble.stop(server)
  end

  test "stubbed response overrides static route" do
    routes = [
      %{method: "GET", path: "/health", response: %{status: 200, body: "ok"}}
    ]

    {:ok, server} = HttpDouble.start_link(port: 0, routes: routes, mode: :mock_first)

    {:ok, _rule} =
      HttpDouble.stub(server, %{method: "GET", path: "/health"}, %{status: 503, body: "down"})

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)

    assert data =~ "503"
    assert data =~ "down"

    :gen_tcp.close(socket)
    Process.unlink(server)
    HttpDouble.stop(server)
  end

  test "sequential responses via stub list" do
    {:ok, server} = HttpDouble.start_link(port: 0, mode: :mock_only)

    {:ok, _rule} =
      HttpDouble.stub(server, %{method: "GET", path: "/health"}, [
        %{status: 200, body: "ok"},
        %{status: 503, body: "down"}
      ])

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data1} = :gen_tcp.recv(socket, 0, 1_000)
    assert data1 =~ "200"
    assert data1 =~ "ok"

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data2} = :gen_tcp.recv(socket, 0, 1_000)
    assert data2 =~ "503"
    assert data2 =~ "down"

    :gen_tcp.close(socket)
    Process.unlink(server)
    HttpDouble.stop(server)
  end

  test "fault injection: delay + timeout + close" do
    {:ok, server} = HttpDouble.start_link(port: 0, mode: :mock_only)

    {:ok, _rule} =
      HttpDouble.stub(server, %{method: "GET", path: "/ping"}, [
        {:delay, 50, %{status: 200, body: "slow"}},
        :timeout,
        :close
      ])

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /ping HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data1} = :gen_tcp.recv(socket, 0, 1_000)
    assert data1 =~ "slow"

    :ok = :gen_tcp.send(socket, "GET /ping HTTP/1.1\r\nhost: localhost\r\n\r\n")
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)

    :ok = :gen_tcp.send(socket, "GET /ping HTTP/1.1\r\nhost: localhost\r\n\r\n")
    :timer.sleep(50)
    assert {:error, _} = :gen_tcp.recv(socket, 0, 100)

    Process.unlink(server)
    HttpDouble.stop(server)
  end

  test "Response helper encodes JSON" do
    resp = Response.json(201, %{foo: "bar"})
    data = Response.to_iodata(resp, nil) |> IO.iodata_to_binary()
    assert data =~ "HTTP/1.1 201 Created"
    assert data =~ "Content-Type: application/json"
    assert data =~ ~s({"foo":"bar"})
  end
end
