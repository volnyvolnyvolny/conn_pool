defmodule(TextConn, do: defstruct([:res]))

defimpl Conn, for: TextConn do
  def init(conn, pid) do
    if Process.alive?(pid) do
      # take available methods
      {_, conn} = Conn.methods(conn)
      {:ok, %{conn | res: pid}}
    else
      {:error, :dead, :infinity, conn}
    end
  end

  def resource(%_{res: pid}), do: pid

  def methods(%_{res: pid}) do
    unless Process.alive?(pid) do
      :error
    else
      send(pid, {self(), ":COMMANDS;"})

      receive do
        "ok:" <> cmds ->
          String.split(cmds, ",")

          # after 5000 -> :error # — no need, pool will handle this.
      end
    end
  end

  def call(%_{res: pid} = c, cmd, args \\ "") do
    unless Process.alive?(pid) do
      {:error, :closed}
    else
      send(pid, {self(), if(args == "", do: ":#{cmd};", else: ":#{cmd}:#{args};")})

      receive do
        "ok;" ->
          {:ok, 0, c}

        "ok:" <> reply ->
          {:ok, reply, 0, c}

        # Suggests timeout 50 ms.
        "err:notsupported" ->
          {:error, :notsupported, 50, c}

        "err:" <> reason ->
          {:error, reason, 50, c}
      after
        5000 ->
          {:error, :timeout, 0, c}
      end
    end
  end

  def parse(_conn, ""), do: :ok
  def parse(_conn, ":COMMANDS;" <> rest), do: {:ok, :methods, rest}

  def parse(_conn, ":" <> data) do
    case Regex.named_captures(~r[(?<cmd>.*)(:(?<args>.*))?;(?<rest>.*)], data) do
      %{"cmd" => cmd, "args" => args, "rest" => rest} ->
        {:ok, {:call, cmd, args}, rest}

      nil ->
        {:error, :needmoredata}
    end
  end

  def parse(_conn, malformed) do
    case String.split(malformed, ";") do
      [malformed, rest] ->
        {:error, {:parse, malformed}, rest}

      _ ->
        {:error, :needmoredata}
    end
  end
end
