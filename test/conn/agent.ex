defmodule(Conn.Agent, do: defstruct([:res]))

defimpl Conn, for: Conn.Agent do
  use Conn.Defaults

  def init(conn, res: pid) do
    if Process.alive?(pid) do
      {:ok, %Conn.Agent{res: pid}}
    else
      {:error, :dead, conn}
    end
  end

  def init(conn, fun) when is_function(fun, 0) do
    case Agent.start_link(fun) do
      {:ok, pid} ->
        init(conn, res: pid)

      :ignore ->
        {:error, :ignore, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  def resource(%_{res: agent}), do: agent

  def methods!(_conn), do: [:get, :get_and_update, :update, :stop]

  def call(conn, method, fun \\ nil)

  def call(%_{res: pid} = conn, method, fun) when method in [:get, :get_and_update, :update] do
    if Process.alive?(pid) do
      {:ok, apply(Agent, method, [pid, fun]), conn}
    else
      {:error, :closed}
    end
  end

  def call(%_{res: pid} = conn, :stop, nil) do
    Agent.stop(pid)
    {:ok, conn}
  end
end
