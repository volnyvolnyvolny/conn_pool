defmodule ConnPoolTest do
  use ExUnit.Case
  doctest Conn.Pool
  doctest Conn

  test "doc" do
    # {:ok, pool} = Conn.Pool.start_link()
    # {:ok, agent} = Agent.start_link(fn -> 42 end)
    # {:ok, conn} = Conn.init(%Conn.Agent{}, res: agent)
    # Conn.Pool.put!(pool, %Conn{conn: conn, revive: true})
    # assert Process.alive?(agent) && not Conn.Pool.empty?(pool, agent)
    # # There are conns for resource `agent` in this pool.
    # assert :ok == Conn.Pool.call(pool, agent, :stop)
    # assert not Process.alive?(agent)
    # assert Conn.Pool.empty?(pool, agent)
    # true
  end
end
