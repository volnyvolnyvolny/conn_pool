defmodule(Conn.Agent, do: defstruct([:res]))

defimpl Conn, for: Conn.Agent do
  def init(conn, nil) do
    if Process.alive?(conn.res) do
      {:ok, conn}
    else
      {:error, :dead, :infinity, conn}
    end
  end

  def init(conn, res: agent) do
    if Process.alive?(agent) do
      {:ok, %{conn | res: agent}}
    else
      {:error, :dead, :infinity, %{conn | res: agent}}
    end
  end

  def init(conn, fun) when is_function(fun, 0) do
    case Agent.start_link(fun) do
      {:ok, agent} ->
        init(conn, res: agent)

      :ignore ->
        {:error, :ignore, :infinity, conn}

      {:error, reason} ->
        {:error, reason, :infinity, conn}
    end
  end

  def resource(%_{res: agent}), do: agent

  def methods!(_conn), do: [:get, :get_and_update, :update, :stop]

  def call(conn, method, fun \\ nil)

  def call(%_{res: agent} = conn, method, fun) when method in [:get, :get_and_update, :update] do
    if Process.alive?(agent) do
      {:ok, apply(Agent, method, [agent, fun]), 0, conn}
    else
      {:error, :closed}
    end
  end

  def call(%_{res: agent} = conn, :stop, nil) do
    Agent.stop(agent)
    {:ok, :closed, conn}
  end

  def parse(_conn, _data), do: {:error, :notimplemented}
end
