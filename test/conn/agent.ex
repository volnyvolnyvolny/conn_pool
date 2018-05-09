defmodule(Conn.Agent, do: defstruct([:res]))

defimpl Conn, for: Conn.Agent do
  def init(conn, []) do
    if Process.alive?(conn.res) do
      {:ok, %Conn.Agent{res: conn.res}}
    else
      {:error, :dead, :infinity, conn}
    end
  end

  def init(conn, res: pid) do
    if Process.alive?(pid) do
      {:ok, %Conn.Agent{res: pid}}
    else
      {:error, :dead, :infinity, conn}
    end
  end

  def init(conn, fun) when is_function(fun, 0) do
    case Agent.start_link(fun) do
      {:ok, pid} ->
        init(conn, res: pid)

      :ignore ->
        {:error, :ignore, conn}

      {:error, reason} ->
        # Suggested to repeat initialization after
        # 50 ms timeout.
        {:error, reason, 50, conn}
    end
  end

  def resource(%_{res: agent}), do: agent

  def parse(_conn, _data), do: {:error, :notimplemented}

  def methods!(_conn), do: [:get, :get_and_update, :update, :stop]

  def call(conn, method, fun \\ nil)

  def call(%_{res: pid} = conn, method, fun) when method in [:get, :get_and_update, :update] do
    if Process.alive?(pid) do
      {:reply, apply(Agent, method, [pid, fun]), conn}
    else
      {:error, :closed}
    end
  end

  def call(%_{res: pid} = conn, :stop, nil) do
    Agent.stop(pid)
    {:noreply, :closed, conn}
  end
end
