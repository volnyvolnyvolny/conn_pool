# ConnPool

  Connection pool helps storing, sharing and using connections. It also make its
  possible to use the same connection concurrently. For example, if there exists
  remote API accessible via websocket, pool can provide shared access, making
  queues of calls. If connection is closed/expires — pool will reinitialize or
  drop it and awaiting calls will be moved to another connection queue.

  Start pool via `start_link/1` or `start/1`. Add connections via `init/3` or
  `Conn.init/2` → `put!/2`. Make calls from pool via `call/4`.

  In the following examples, `%Conn.Agent{}` represents connection to some
  `Agent` that can be created separately or via `Conn.init/2`. Available methods
  of interaction with `Agent` are `:get`, `:get_and_update`, `:update` and
  `:stop` (see `Conn.methods!/1`). This type of connection means to exist only
  as an example for doctests. More meaningful example would be `Conn.Plug`
  wrapper. Also, see `Conn` docs for detailed example on `Conn` protocol
  implementation and use.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.extra(pool, id, type: :agent) # add `extra` info
      {:ok, nil}
      #
      # Pool wraps conn into `%Conn{}` struct.
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.extra
      [type: :agent]
      iex> info.methods
      [:get, :get_and_update, :update, :stop]
      iex> ^agent = Conn.resource(info.conn)
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:ok, 42}
      #
      # Now we use filter (& &1.extra[:type] != :agent).
      iex> Conn.Pool.call(pool, agent, :get, & &1.extra[:type] != :agent, & &1)
      {:error, :filter}
      #
      iex> Conn.Pool.call(pool, agent, :badmethod)
      {:error, :method}
      iex> Conn.Pool.call(pool, :badres, :badmethod)
      {:error, :resource}

  In the above example connection was initialized and used directly from pool.
  `%Conn{}.extra` information that was given via `Conn.Pool.extra/3` was used to
  filter conn to be selected in `Conn.Pool.call/5` call.

  In the following example connection will be added via `put/2`.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, res: agent)
      iex> Conn.Pool.put!(pool, %Conn{conn: conn, revive: true})
      iex> Process.alive?(agent) && not Conn.Pool.empty?(pool, agent)
      true
      # There are conns for resource `agent` in this pool.
      iex> Conn.Pool.call(pool, agent, :stop)
      :ok
      iex> not Process.alive?(agent)
      true
      iex> :timer.sleep(10)
      iex> Conn.Pool.empty?(pool, agent)
      true
      # Now conn is `:closed` and will be reinitialized by pool,
      # but:
      iex> {:error, :dead, :infinity, conn} == Conn.init(conn)
      true
      # `Conn.init/2` suggests to never reinitialize again
      # (`:infinity` timeout) so pool will just drop this conn.
      iex> Conn.Pool.resources(pool)
      []

  Also, TTL value could be provided. By default expired connection is revived.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.update(pool, agent, & %{&1 | ttl: 50})
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.ttl
      50
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:ok, 42}
      iex> :timer.sleep(50)
      :ok
      #
      # Next call will fail because all the conns are expired and conn
      # will not be revived (%Conn{}.revive == false).
      #
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:error, :resource}
      iex> Conn.Pool.resources(pool)
      []
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.call(pool, agent, :get, & &1+1)
      {:ok, 43}
      # That's because conn that is alive exists.
      #
      iex> Conn.Pool.update(pool, agent, & %{&1 | ttl: 10, revive: true})
      iex> :timer.sleep(10)
      iex> Conn.Pool.call(pool, agent, :get, & &1+1)
      {:error, :resource}

  ## Name registration

  An `Conn.Pool` is bound to the same name registration rules as `GenServer`s.
  Read more about it in the `GenServer` docs.

## Installation

Add `conn_pool` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:conn_pool, "~> 0.2.1"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/conn_pool](https://hexdocs.pm/conn_pool).

