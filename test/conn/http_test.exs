defmodule ConnHTTPTest do
  use ExUnit.Case

#  doctest Conn.HTTP

  test "HTTP" do
    {:ok, conn} =
      Conn.init(%Conn.HTTP{}, res: :search,
                              url: "https://google.com")
    {:reply, resp, conn} =
      Conn.call(conn, :get, body: "", headers: [], follow_redirect: true)

    assert resp.body =~ "Google"

    #
    # Also this conn could be added to pool:
    {:ok, pool} = Conn.Pool.start_link()
    Conn.Pool.put!(pool, conn)

    {:ok, resp} = Conn.Pool.call(pool, :search, :get, follow_redirect: true)
    assert resp.body =~ "Google"
  end
end
