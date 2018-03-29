defmodule ConnPoolTest do
  use ExUnit.Case
#  doctest Conn.Pool
#  doctest Conn

  test "doc" do
      {:ok, pool} = Conn.Pool.start_link()
      {:ok, agent} = Agent.start_link(fn -> 42 end)
      {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      Conn.Pool.update(pool, agent, & %{&1 | ttl: 50})
      {:ok, info} = Conn.Pool.info(pool, id)
      assert 50 == info.ttl
      assert {:ok, 42} == Conn.Pool.call(pool, agent, :get, & &1)
      :timer.sleep(50)
      #
      # Next call will fail because all the conns are expired and conn
      # will not be revived (%Conn{}.revive == false).
      assert {:error, :resource} == Conn.Pool.call(pool, agent, :get, & &1)
      assert [] == Conn.Pool.resources(pool)
      Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      Conn.Pool.update(pool, agent, & %{&1 | ttl: 10, revive: true})
      :timer.sleep(10)
      assert {:ok, 43} == Conn.Pool.call(pool, agent, :get, & &1+1)
  end
end
