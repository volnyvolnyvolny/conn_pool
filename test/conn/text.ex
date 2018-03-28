defmodule(TextConn, do: defstruct([:res]))

defimpl Conn, for: TextConn do
  def init(conn, pid) do
    if Process.alive?(pid) do
      {:ok, %{conn | res: pid}}
    else
      {:error, :dead, :infinity, conn}
    end
  end

  def resource(%_{res: pid}), do: pid

  def methods!(%_{res: pid}) do
    send(pid, {self(), ":COMMANDS"})

    receive do
      "ok:" <> cmds ->
        String.split(cmds, ",")

      _ ->
        :error
    end
  end

  def call(%_{res: pid} = c, cmd, args \\ "") do
    if Process.alive?(pid) do
      send(pid, {self(), args && ":#{cmd}:#{args}" || ":#{cmd}"})

      receive do
        "ok" ->
          {:ok, 0, c}

        "ok:" <> reply ->
          {:ok, reply, 0, c}

        "err:notsupported" ->
          {:error, :notsupported, 50, c}

        "err:" <> reason ->
          {:error, reason, 50, c}
      after
        5000 ->
          {:error, :timeout, 0, c}
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
