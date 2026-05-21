defmodule HttpDouble.MockApiTest do
  use HttpDouble.Case, async: true

  test "stub by method and path", %{http_server: server, http_endpoint: endpoint} do
    {:ok, _rule} =
      HttpDouble.stub(server, %{method: :get, path: "/health"}, %{status: 200, body: "ok"})

    url = HttpDouble.url(server, "/health")

    {:ok, socket} =
      :gen_tcp.connect(
        String.to_charlist(endpoint.host),
        endpoint.port,
        [:binary, packet: :raw, active: false]
      )

    :ok = :gen_tcp.send(socket, "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)

    assert data =~ "200"
    assert data =~ "ok"
    assert String.starts_with?(url, "http://")

    :gen_tcp.close(socket)
  end

  test "recorded calls are available for assertions", %{http_server: server} do
    {:ok, _rule} =
      HttpDouble.stub(server, %{method: :post, path: "/api/messages"}, %{
        status: 201,
        json: %{result: "accepted"}
      })

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    body = ~s({"message":"hello"})
    len = byte_size(body)

    payload =
      [
        "POST /api/messages HTTP/1.1\r\n",
        "host: localhost\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(len),
        "\r\n\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, payload)
    {:ok, _data} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)

    calls = HttpDouble.calls(server)

    assert [
             %{
               request: %HttpDouble.Request{
                 method: "POST",
                 path: "/api/messages",
                 body: ^body
               }
             }
           ] = calls
  end

  test "dynamic route update at runtime", %{http_server: server} do
    :ok =
      HttpDouble.set_routes(server, [
        %{method: "GET", path: "/foo", response: %{status: 200, body: "foo"}}
      ])

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /foo HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data1} = :gen_tcp.recv(socket, 0, 1_000)
    assert data1 =~ "foo"

    :ok =
      HttpDouble.update_route(server, %{
        method: "GET",
        path: "/foo",
        response: %{status: 200, body: "bar"}
      })

    :ok = :gen_tcp.send(socket, "GET /foo HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data2} = :gen_tcp.recv(socket, 0, 1_000)
    assert data2 =~ "bar"

    :gen_tcp.close(socket)
  end

  test "mockserver expectation JSON body uses application/json content-type", %{
    http_server: server
  } do
    %{host: host, port: port, base_url: base_url} = HttpDouble.endpoint(server)

    expectation = %{
      httpRequest: %{method: "GET", path: "/api/example"},
      httpResponse: %{
        statusCode: 200,
        body: %{
          type: "JSON",
          json: ~s({"ok":true}),
          contentType: "application/json"
        }
      }
    }

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    payload =
      Jason.encode!(expectation)
      |> then(fn body ->
        [
          "PUT /expectation HTTP/1.1\r\n",
          "host: localhost\r\n",
          "content-type: application/json\r\n",
          "content-length: ",
          Integer.to_string(byte_size(body)),
          "\r\n\r\n",
          body
        ]
        |> IO.iodata_to_binary()
      end)

    :ok = :gen_tcp.send(socket, payload)
    {:ok, _} = :gen_tcp.recv(socket, 0, 1_000)

    {:ok, socket2} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket2, "GET /api/example HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data} = :gen_tcp.recv(socket2, 0, 1_000)
    :gen_tcp.close(socket2)
    :gen_tcp.close(socket)

    # Cowboy/Plug emit lowercase header names (HTTP header names are case-insensitive).
    assert String.downcase(data) =~ "content-type: application/json"
    assert data =~ ~s({"ok":true})
    refute data =~ "text/plain"
    assert is_binary(base_url)
  end

  test "fault injection with raw and partial responses", %{http_server: server} do
    {:ok, _rule} =
      HttpDouble.stub(server, %{method: "GET", path: "/broken"}, {:raw, "BROKEN RESPONSE"})

    {:ok, _rule2} =
      HttpDouble.stub(
        server,
        %{method: "GET", path: "/partial"},
        {:partial, ["HTTP/1.1 200 OK\r\n", "content-length: 100\r\n\r\n", "half"]}
      )

    %{host: host, port: port} = HttpDouble.endpoint(server)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "GET /broken HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data1} = :gen_tcp.recv(socket, 0, 1_000)
    # With Cowboy we get full HTTP response; body is the raw string
    assert data1 =~ "BROKEN RESPONSE"
    assert String.ends_with?(data1, "\r\n\r\nBROKEN RESPONSE")

    :ok = :gen_tcp.send(socket, "GET /partial HTTP/1.1\r\nhost: localhost\r\n\r\n")
    {:ok, data2} = :gen_tcp.recv(socket, 0, 1_000)
    assert data2 =~ "half"

    :gen_tcp.close(socket)
  end
end
