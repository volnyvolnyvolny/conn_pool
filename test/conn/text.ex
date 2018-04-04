defmodule(TextConn, do: defstruct([:res, timeout: 0]))

defimpl Conn, for: TextConn do
  def init(conn, pid) do
    if Process.alive?(pid) do
      {:ok, %TextConn{res: pid}}
    else
      {:error, :dead, %{conn | timeout: :infinity}}
    end
  end

  def resource(%_{res: pid}), do: pid

  def methods!(%_{res: pid}) do
    send(pid, {self(), ":COMMANDS"})

    receive do
      "ok:" <> cmds ->
        String.split(cmds, ",")
    end
  end

  def timeout(conn), do: conn.timeout

  def call(%_{res: pid} = conn, cmd, args \\ "") do
    if Process.alive?(pid) do
      conn = %{conn | timeout: 0}

      send(pid, {self(), (args && ":#{cmd}:#{args}") || ":#{cmd}"})

      receive do
        "ok" ->
          {:ok, conn}

        "ok:" <> reply ->
          {:ok, reply, conn}

        "err:notsupported" ->
          {:error, :notsupported, %{conn | timeout: 50}}

        "err:" <> reason ->
          {:error, reason, %{conn | timeout: 50}}
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
    case Regex.named_captures(~r[(?<cmd>.*)(:(?<args>.*))?], data) do
      %{"cmd" => cmd, "args" => args} ->
        {:ok, {:call, cmd, args}, ""}

      nil ->
        {:error, {:parse, data}, ""}
    end
  end

  def parse(_conn, malformed) do
    {:error, {:parse, malformed}, ""}
  end
end
