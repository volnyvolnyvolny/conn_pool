defmodule(TextConn, do: defstruct([:res]))

defimpl Conn, for: TextConn do
  def init(conn, server) do
    if Process.alive?(server) do
      {:ok, %TextConn{res: server}}
    else
      {:error, :dead, %{conn | timeout: :infinity}}
    end
  end

  def resource(%_{res: server}), do: server

  def methods!(%_{res: server}) do
    send(server, {self(), ":COMMANDS"})

    receive do
      "ok:" <> cmds ->
        String.split(cmds, ",")
    end
  end

  def call(%_{res: server} = conn, cmd, args \\ "") do
    if Process.alive?(server) do
      IO.inspect({self(), (args && ":#{cmd}:#{args}") || ":#{cmd}"})
      send(server, {self(), (args && ":#{cmd}:#{args}") || ":#{cmd}"})

      receive do
        "ok" ->
          {:noreply, conn}

        "ok:" <> reply ->
          {:reply, reply, conn}

        "err:notsupported" ->
          {:error, :notsupported, conn}

        "err:" <> reason ->
          {:error, reason, 50, conn}
      after
        5000 ->
          {:error, :timeout, conn}
      end
    else
      {:error, :closed}
    end
  end

  def parse(_conn, ""), do: :ok
  def parse(_conn, ":COMMANDS" <> _), do: {:ok, :methods, ""}

  def parse(_conn, ":" <> data) do
    case Regex.named_captures(~r/(?<cmd>[^:]+)(?::(?<args>.*))?/, data) do
      %{"cmd" => cmd, "args" => args} ->
        IO.inspect({cmd, args})
        {:ok, {:call, cmd, args}, ""}

      nil ->
        {:error, {:parse, data}, ""}
    end
  end

  def parse(_conn, malformed) do
    {:error, {:parse, malformed}, ""}
  end
end
