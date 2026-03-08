defmodule HttpDouble.Application do
  @moduledoc """
  OTP application entry point for `:http_double`.

  The application itself is intentionally minimal – it only starts a `Registry`
  used for optional server naming. Individual HTTP dummy servers are started
  via `HttpDouble.start_link/1` or as children under your own supervision tree
  using `HttpDouble.child_spec/1`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: HttpDouble.TaskSupervisor},
      {Registry, keys: :unique, name: HttpDouble.ServerRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HttpDouble.Supervisor)
  end
end
