defmodule HttpDouble.Case do
  @moduledoc """
  ExUnit case template that spins up an isolated HttpDouble server per test.

  Usage:

      defmodule MyTest do
        use HttpDouble.Case, async: true

        test "example", %{http_server: server, http_endpoint: endpoint} do
          {:ok, _rule} =
            HttpDouble.stub(server, %{method: "GET", path: "/health"}, %{status: 200, body: "ok"})

          assert endpoint.port > 0
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import HttpDouble.Case
    end
  end

  setup _tags do
    {:ok, server} = HttpDouble.start_link(port: 0, mode: :mock_first)

    on_exit(fn ->
      if Process.alive?(server) do
        parent = self()

        spawn(fn ->
          Process.flag(:trap_exit, true)

          try do
            HttpDouble.stop(server)
          after
            send(parent, :stop_done)
          end

          receive do
            {:EXIT, _from, _reason} -> :ok
          after
            0 -> :ok
          end
        end)

        receive do
          :stop_done -> :ok
        after
          3_000 -> :ok
        end
      end
    end)

    {:ok,
     %{
       http_server: server,
       http_endpoint: HttpDouble.endpoint(server)
     }}
  end

  @doc """
  Convenience wrapper around `HttpDouble.stub/3` that reads the server from
  the test context.
  """
  @spec stub(map(), HttpDouble.matcher(), HttpDouble.response_spec()) ::
          {:ok, reference()}
  def stub(%{http_server: server}, matcher, response) do
    HttpDouble.stub(server, matcher, response)
  end

  @doc """
  Convenience wrapper around `HttpDouble.expect/3` that reads the server from
  the test context.
  """
  @spec expect(map(), HttpDouble.matcher(), HttpDouble.response_spec()) ::
          {:ok, reference()}
  def expect(%{http_server: server}, matcher, response) do
    HttpDouble.expect(server, matcher, response)
  end
end
