defmodule ConnPool.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications.
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised.
    children = [
      # Starts pool by calling: Conn.Pool.start_link([]).
      {Conn.Pool, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Conn.Pool.Sup]
    Supervisor.start_link(children, opts)
  end
end
