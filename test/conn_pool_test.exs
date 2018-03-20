defmodule ConnPoolTest do
  use ExUnit.Case
#  doctest Conn.Pool

  test "doc" do
      {:ok, pool} = Conn.Pool.start_link()
      {:ok, agent} = Agent.start_link(fn -> 42 end)

      {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      {:ok, info} = Conn.Pool.info(pool, id)
      Conn.Pool.update(pool, agent, & %{&1 | revive: :force})

      assert Process.alive?(agent) && not Conn.Pool.empty?(pool, agent)
      assert :ok == Conn.Pool.call(pool, agent, :stop)
      assert not Process.alive?(agent) && Conn.Pool.empty?(pool, agent)

      assert {:error, :dead, :infinity, info.conn} == Conn.init(info.conn)
      assert Conn.Pool.resources(pool) == []
  end
end
