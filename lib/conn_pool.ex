defmodule Conn.Pool do
  use Agent

  require Logger

  @moduledoc """
  Connection pool helps storing, sharing and using connections. It also make its
  possible to use the same connection concurrently. For example, if there exists
  remote API accessible via websocket, pool can provide shared access, making
  queues of calls. If connection is closed/expires — pool will reinitialize or
  drop it and awaiting calls will be moved to another connection queue.

  Start pool via `start_link/1` or `start/1`. Add connections via `init/3` or
  `Conn.init/2` → `put/2`. Make calls from pool via `call/4`.

  In the following examples, `%Conn.Agent{}` represents connection to some
  `Agent` that can be created separately or via `Conn.init/2`. Available methods
  of interaction with `Agent` are `:get`, `:get_and_update`, `:update` and
  `:stop` (see `Conn.methods/1`). This type of connection means to exist only as
  an example for doctests. More meaningful example would be `Conn.Plug` wrapper.
  Also, see `Conn` docs for detailed example on `Conn` protocol implementation
  and use.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.extra(pool, id, type: :agent) # add `extra` info
      {:ok, nil}
      # Pool wraps conn into `%Conn{}` struct.
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.extra
      [type: :agent]
      iex> info.methods
      [:get, :get_and_update, :update, :stop]
      iex> agent == Conn.resource(info.conn)
      true
      #
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:ok, 42}
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
      iex> Conn.Pool.put(pool, %Conn{conn: conn, revive: true})
      iex> Process.alive?(agent) && not Conn.Pool.empty?(pool, agent)
      true
      # There are conns for resource `agent` in this pool.
      iex> Conn.Pool.call(pool, agent, :stop)
      :ok
      iex> not Process.alive?(agent) && Conn.Pool.empty?(pool, agent)
      true
      # Now conn is `:closed` and will be reinitialized by pool,
      # but:
      iex> {:error, :dead, :infinity, conn} == Conn.init(conn)
      true
      # `Conn.init/2` suggests to never reinitialize again (`:infinity` timeout)
      # so pool will just drop this conn.
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
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:error, :resource}
      iex> Conn.Pool.resources(pool)
      []
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.update(pool, agent, & %{&1 | ttl: 10, revive: true})
      iex> :timer.sleep(10)
      iex> Conn.Pool.call(pool, agent, :get, & &1+1)
      {:ok, 43}

  ## Name registration

  An `Conn.Pool` is bound to the same name registration rules as `GenServer`s.
  Read more about it in the `GenServer` docs.
  """

  @type t :: GenServer.t()
  @type id :: pos_integer
  @type reason :: any
  @type filter :: (Conn.info() -> as_boolean(term()))

  # Generate uniq id
  defp gen_id, do: System.system_time()

  @doc """
  Starts pool as a linked process.
  """
  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    conns_f = fn -> AgentMap.new() end
    AgentMap.start_link([conns: conns_f, resources: fn -> %{} end] ++ opts)
  end

  @doc """
  Starts pool. See `start_link/2` for details.
  """
  @spec start(GenServer.options()) :: GenServer.on_start()
  def start(opts \\ []) do
    conns_f = fn -> AgentMap.new() end
    AgentMap.start([conns: conns_f, resources: fn -> %{} end] ++ opts)
  end

  @doc """
  Initialize connection in a separate `Task` and use `put/2` to add connection
  that is wrapped in `%Conn{}`.

  By default, init time is limited by `5000` ms and pool will revive closed
  connection using `init_args` provided.

  ## Returns

    * `{:ok, id}` in case of `Conn.init/2` returns `{:ok, conn}`, where `id` is
      the identifier that can be used to refer `conn`;
    * `{:error, :timeout}` if `Conn.init/2` returns `{:ok, :timeout}` or
      initialization spended more than `%Conn{}.init_timeout` ms.
    * `{:error, :methods}` if `Conn.methods/1` returns `:error`.
    * `{:error, reason}` in case `Conn.init/2` returns arbitrary error.
  """
  @spec init(Conn.Pool.t(), Conn.t() | Conn.info(), any) ::
          {:ok, id} | {:error, :timeout | :methods | reason}

  def init(pool, info_or_conn, init_args \\ nil)

  def init(pool, %Conn{conn: conn} = info, init_args) do
    task =
      Task.async(fn ->
        Conn.init(conn, init_args)
      end)

    case Task.yield(task, :infinity) || Task.shutdown(task) do
      {:ok, {:ok, conn}} ->
        put(pool, %{info | conn: conn, init_args: init_args})

      {:ok, err} ->
        err

      nil ->
        {:error, :timeout}
    end
  end

  def init(pool, conn, init_args) do
    init(pool, %Conn{conn: conn}, init_args)
  end

  # add conn to pool
  defp add(pool, info) do
    conns = AgentMap.get(pool, :conns)

    id = gen_id()

    AgentMap.put(conns, id, info)

    res = Conn.resource(info.conn)

    AgentMap.update(pool, :resources, fn map ->
      Map.update(map, res, [id], &[id | &1])
    end)

    id
  end

  @doc """
  Adds given `%Conn{}` to pool, returning id to refer `info.conn` in future.

  Put will refresh data in `%Conn{}.methods` with `Conn.methods/1` call.

  ## Returns

    * `{:ok, id}`;
    * `{:error, :methods}` if `Conn.methods/1` call returned `:error`;
    * `{:error, :timeout}` if execution of `Conn.methods/1` took more than
      `%Conn{}.init_timeout` ms.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> ttl = 100 # ms
      iex> info = %Conn{
      ...>   conn: conn,
      ...>   extra: :extra,
      ...>   ttl: ttl
      ...> }
      iex> {:ok, id} = Conn.Pool.put(pool, info)
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> ^ttl = info.ttl
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.extra
      :extra
      #
      # let's make some tweak
      #
      iex> {:ok, info} = Conn.Pool.pop(pool, id)
      iex> {:ok, id} = Conn.Pool.put(pool, %{info| ttl: :infinity})
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.ttl
      :infinity
  """
  @spec put(Conn.Pool.t(), Conn.info()) :: {:ok, id} | {:error, :methods | :timeout}
  def put(pool, %Conn{conn: conn} = info) do
    case Conn.methods(conn) do
      :error ->
        {:error, :methods}

      {:error, _} ->
        {:error, :methods}

      {methods, conn} ->
        info = %{info | methods: methods, conn: conn}
        {:ok, add(pool, info)}

      methods ->
        info = %{info | methods: methods}
        {:ok, add(pool, info)}
    end
  end

  defp delete(pool, id), do: pop(pool, id)

  @doc """
  Works as `info/2`, but also deletes connection.

  Connection wrapper is returned only after all calls in the corresponding queue
  are fulfilled.

  ## Returns

    * `{:ok, Conn struct}` in case conn with such id exists;
    * `:error` — otherwise.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> {:ok, %Conn{conn: conn}} = Conn.Pool.pop(pool, id)
      iex> Agent.get(Conn.resource(conn), & &1)
      42
      iex> Conn.Pool.pop(pool, id)
      :error
      iex> {:ok, id1} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> {:ok, id2} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> {:ok, id3} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.extra(pool, id1, :takeme)
      {:ok, nil}
      iex> Conn.Pool.extra(pool, id3, :takeme)
      iex> Conn.Pool.pop(pool, agent, & &1.extra == :takeme)
      iex> Conn.Pool.empty?(pool, agent)
      false
      iex> Conn.Pool.pop(pool, id2)
      iex> Conn.Pool.empty?(pool, agent)
      true

  Also, see example for `put/2`.
  """
  @spec pop(Conn.Pool.t(), Conn.id()) :: {:ok, Conn.info()} | :error
  def pop(pool, id) when is_integer(id) do
    conns = AgentMap.get(pool, :conns)
    info = conns[id]

    if info do
      res = Conn.resource(info.conn)
      AgentMap.delete(conns, id)

      AgentMap.cast(pool, :resources, fn map ->
        case Map.fetch(map, res) do
          {:ok, [^id]} ->
            Map.delete(map, res)

          {:ok, ids} ->
            ids = List.delete(ids, id)
            Map.put(map, res, ids)

          :error ->
            map
        end
      end)

      {:ok, info}
    else
      :error
    end
  end

  @doc """
  Pop conns to `resource` that satisfy `filter`.
  """
  @spec pop(Conn.Pool.t(), Conn.resource(), (Conn.info() -> boolean)) :: [Conn.info()]
  def pop(pool, resource, filter) when is_function(filter, 1) do
    conns = AgentMap.get(pool, :conns)
    resources = AgentMap.get(pool, :resources, & &1)
    ids = resources[resource]

    if ids do
      for id <- ids, filter.(conns[id]) do
        pop(pool, id)
      end
    else
      []
    end
  end

  @doc """
  Apply given `fun` to every conn to `resource`.
  Returns list of results.
  """
  @spec map(Conn.Pool.t(), Conn.resource(), (Conn.info() -> a)) :: [a] when a: var
  def map(pool, resource, fun) when is_function(fun, 1) do
    conns = AgentMap.get(pool, :conns)
    resources = AgentMap.get(pool, :resources, & &1)
    ids = resources[resource]

    if ids do
      for id <- ids do
        fun.(conns[id])
      end
    else
      []
    end
  end

  @doc """
  Update every conn to `resource` with `fun`.
  This function always returns `:ok`.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start(fn -> 42 end)
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.call(pool, agent, :get, & &1.extra == :extra, & &1)
      {:error, :filter}
      #
      iex> Conn.Pool.update(pool, agent, & %{&1 | extra: :extra})
      :ok
      iex> Conn.Pool.call(pool, agent, :get, & &1.extra == :extra, & &1)
      {:ok, 42}
  """
  @spec update(Conn.Pool.t(), Conn.resource(), (Conn.info() -> Conn.info())) :: :ok
  def update(pool, resource, fun) when is_function(fun, 1) do
    update(pool, resource, fn _ -> true end, fun)
  end

  @doc """
  Update every conn to `resource`, satisfying given `filter` with `fun`. This
  function always returns `:ok`.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start(fn -> 42 end)
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> filter = & &1.extra == :extra
      iex> Conn.Pool.call(pool, agent, :get, filter, & &1)
      {:error, :filter}
      #
      iex> Conn.Pool.update(pool, agent, & %{&1 | extra: :extra})
      :ok
      iex> Conn.Pool.call(pool, agent, :get, filter, & &1)
      {:ok, 42}
      iex> Conn.Pool.update(pool, agent, filter, &Map.put(&1, :extra, nil))
      iex> Conn.Pool.call(pool, agent, :get, filter, & &1)
      {:error, :filter}
  """
  @spec update(
          Conn.Pool.t(),
          Conn.resource(),
          (Conn.info() -> boolean),
          (Conn.info() -> Conn.info())
        ) :: :ok
  def update(pool, resource, filter, fun) when is_function(fun, 1) and is_function(filter, 1) do
    conns = AgentMap.get(pool, :conns)
    resources = AgentMap.get(pool, :resources, & &1)
    ids = resources[resource]

    if ids do
      for id <- ids do
        AgentMap.update(conns, id, fn info ->
          if filter.(info) do
            info = fun.(info)

            if info.methods && is_list(info.methods) do
              info
            else
              case Conn.methods(info.conn) do
                :error ->
                  raise "Update fun mailformed :methods key. While fixing, `Conn.methods/1` returned :error."

                {:error, _} = err ->
                  raise "Update fun mailformed :methods key. While fixing, `Conn.methods/1` returned #{
                          inspect(err)
                        }."

                {methods, conn} ->
                  %{info | methods: methods, conn: conn}

                methods ->
                  %{info | methods: methods}
              end
            end
          else
            info
          end
        end)
      end
    end

    :ok
  end

  @doc """
  Is `pool` has conns to the given `resource`?
  """
  @spec empty?(Conn.Pool.t(), Conn.resource()) :: boolean
  def empty?(pool, resource) do
    resources = AgentMap.get(pool, :resources, & &1)

    case resources[resource] do
      nil -> true
      [] -> true
      _ -> false
    end
  end

  @doc """
  Returns all the known resources.
  """
  @spec resources(Conn.Pool.t()) :: [Conn.resource()]
  def resources(pool) do
    pool
    |> AgentMap.get(:resources, & &1)
    |> Map.keys()
  end

  # Returns {:ok, ids} | {:error, :resources} | {:error, method}
  # | {:error, filter}
  defp filter(pool, resource, method, filter) when is_function(filter, 1) do
    conns = AgentMap.get(pool, :conns)
    resources = AgentMap.get(pool, :resources, & &1)
    ids = resources[resource]

    if ids do
      ids_and_infos =
        for id <- ids, info = conns[id], not info.closed, method in info.methods do
          {id, info}
        end

      if ids_and_infos == [] do
        {:error, :method}
      else
        ids =
          for {id, info} <- ids_and_infos, p = filter.(info), p do
            id
          end

        if ids == [] do
          {:error, :filter}
        else
          {:ok, ids}
        end
      end
    else
      {:error, :resource}
    end
  end

  defp _revive(pool, id, info) do
    case Conn.init(info.conn, info.init_args) do
      {:ok, conn} ->
        res = Conn.resource(conn)

        AgentMap.cast(pool, :resources, fn map ->
          Map.update(map, res, [id], &[id | &1])
        end)

        %{info | conn: conn, closed: false, last_init: System.system_time()}

      {:error, reason, :infinity, conn} ->
        info = %{info | conn: conn}

        Logger.error(
          "Failed to reinitialize connection. Reason: #{inspect(reason)}. Connection info: #{
            inspect(info)
          }.\n\nStop trying."
        )

        delete(pool, id)
        nil

      {:error, reason, timeout, conn} ->
        info = %{info | conn: conn}

        Logger.warn(
          "Failed to reinitialize connection with id #{id}. Reason: #{inspect(reason)}. Connection info: #{
            inspect(info)
          }.\n\nWill try again in #{to_ms(timeout)} ms."
        )

        Process.sleep(timeout)
        _revive(pool, id, info)
    end
  end

  defp revive(pool, id, info) do
    conns = AgentMap.get(pool, :conns)

    AgentMap.cast(conns, id, fn nil ->
      _revive(pool, id, info)
    end)
  end

  # Estimated time to wait until call can be made on this id.
  defp waiting_time(conns, id) do
    with {:ok, info} <- AgentMap.fetch(conns, id) do
      {sum, n} =
        Enum.reduce(info.stats, {0, 0}, fn {_key, {avg, num}}, {sum, n} ->
          {sum + avg * num, n + num}
        end)

      if n == 0 do
        {:ok, info.timeout}
      else
        {:ok, sum / n * AgentMap.queue_len(conns, id) + info.timeout}
      end
    end
  end

  # Select the best conn.
  defp select(pool, resource, method, filter) do
    conns = AgentMap.get(pool, :conns)

    with {:ok, ids} <- filter(pool, resource, method, filter) do
      {:ok, Enum.min_by(ids, &waiting_time(conns, &1))}
    end
  end

  defp update_stats(info, method, start) do
    stop = System.system_time()

    update_in(info.stats[method], fn
      nil -> {stop - start, 1}
      {avg, num} -> {(avg * num + stop - start) / (num + 1), num + 1}
    end)
  end

  defp to_ms(native), do: System.convert_time_unit(native, :native, :milliseconds)
  defp to_native(ms), do: System.convert_time_unit(ms, :milliseconds, :native)

  defp expired?(%{ttl: :infinity}), do: false
  defp expired?(info), do: IO.inspect(info.last_init) + IO.inspect(to_native(info.ttl)) < IO.inspect(System.system_time())

  defp _call(%{closed: true} = info, {pool, resource, method, filter, _payload} = args) do
    case select(pool, resource, method, filter) do
      {:ok, id} ->
        fun = &_call(&1, args)
        # Make chain call while not changing conn.
        {:chain, {id, fun}, info}

      err ->
        # Return an error while not changing conn.
        {err}
    end
  end

  defp _call(info, {pool, resource, method, filter, payload} = args) do
    id = Process.get(:"$key")

    if expired?(info) do
      info = %{info | closed: true}
      IO.inspect(info)
      delete(pool, id)
      if info.revive, do: revive(pool, id, info)
      _call(info, args)
    else
      start = System.system_time()
      timeout = to_native(info.timeout)

      # Time to wait.
      ttw = info.last_call + timeout - start

      if to_ms(ttw) < 50 do
        Process.sleep(if ttw < 0, do: 0, else: ttw)

        case Conn.call(info.conn, method, payload) do
          {:ok, :closed, conn} ->
            delete(pool, id)
            info = update_stats(info, method, start)
            info = %{info | conn: conn, closed: true}
            if info.revive == :force, do: revive(pool, id, info)
            {:ok, info}

          {:ok, reply, :closed, conn} ->
            delete(pool, id)
            info = %{info | conn: conn, closed: true}
            info = update_stats(info, method, start)
            if info.revive == :force, do: revive(pool, id, info)
            {{:ok, reply}, info}

          {:ok, timeout, conn} ->
            info = update_stats(info, method, start)
            info = %{info | conn: conn, timeout: timeout}
            {:ok, info}

          {:ok, reply, timeout, conn} ->
            info = update_stats(info, method, start)
            info = %{info | conn: conn, timeout: timeout}
            {{:ok, reply}, info}

          {:error, :closed} ->
            delete(pool, id)
            info = %{info | closed: true}

            case select(pool, resource, method, filter) do
              {:ok, id} ->
                fun = &_call(&1, args)
                if info.revive, do: revive(pool, id, info)

                # Make chain call while not changing conn.
                {:chain, {id, fun}, info}

              err ->
                # Return an error while not changing conn.
                {err, info}
            end

          {:error, reason, :closed, conn} ->
            delete(pool, id)
            info = %{info | conn: conn, closed: true}
            if info.revive, do: revive(pool, id, info)
            {{:error, reason}, info}

          {:error, reason, timeout, conn} ->
            info = %{info | conn: conn, timeout: timeout}
            {{:error, reason}, info}

          err ->
            Logger.warn("Conn.call returned unexpected: #{inspect(err)}.")
            {err}
        end
      else
        # ttw > 50 ms.
        with {:ok, id} <- select(pool, resource, method, filter),
             conns = AgentMap.get(pool, :conns),
             {:ok, potential_ttw} <- waiting_time(conns, id),
             true <- ttw > potential_ttw do
          fun = &_call(&1, args)
          {:chain, {id, fun}, info}
        else
          _ ->
            Process.sleep(20)
            _call(info, args)
        end
      end
    end
  end

  @doc """
  Select one of the connections to given `resource` and make `Conn.call/3` via
  given `method` of interaction.

  Optional `filter` param could be provided in form of `(%Conn{} ->
  as_boolean(term()))` callback.

  Pool respects refresh timeout value returned by `Conn.call/3`. After each call
  `:timeout` field of the corresponding `%Conn{}` struct is rewrited.

  ## Returns

    * `{:error, :resource}` if there is no conns to given `resource`;
    * `{:error, :method}` if there exists conns to given `resource` but they does
    not provide given `method` of interaction;
    * `{:error, :filter}` if there is no conns satisfying `filter`;

    * `{:error, :timeout}` if `Conn.call/3` returned `{:error, :timeout, _, _}`
      and there is no other connection capable to make this call;
    * and `{:error, reason}` in case of `Conn.call/3` returned arbitrary error.

  In case of `Conn.call/3` returns `{:error, :timeout | reason, _, _}`,
  `Conn.Pool` will use time penalties series, defined per pool (see
  `start_link/2`) or per connection (see `%Conn{} :penalties` field).

    * `{:ok, reply} | :ok` in case of success.
  """
  @spec call(Conn.Pool.t(), Conn.resource(), Conn.method(), any) ::
          :ok | {:ok, Conn.reply()} | {:error, :resource | :method | :timeout | reason}
  @spec call(Conn.Pool.t(), Conn.resource(), Conn.method(), filter, any) ::
          :ok | {:ok, Conn.reply()} | {:error, :resource | :method | :filter | :timeout | reason}
  def call(pool, resource, method, payload \\ nil) do
    call(pool, resource, method, fn _ -> true end, payload)
  end

  def call(pool, resource, method, filter, payload) when is_function(filter, 1) do
    conns = AgentMap.get(pool, :conns)

    with {:ok, id} <- select(pool, resource, method, filter) do
      AgentMap.get_and_update(conns, id, &_call(&1, {pool, resource, method, filter, payload}))
    end
  end

  @doc """
  `:extra` field of `%Conn{}` is intended for filtering conns while making call.
  Calling `extra/3` will change `:extra` field of connection with given `id`,
  while returning the old value in form of `{:ok, old extra}` or `:error` if
  pool don't known conn with such id.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start(fn -> 42 end)
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.extra(pool, id, :extra)
      {:ok, nil}
      iex> Conn.Pool.extra(pool, id, :some)
      {:ok, :extra}
      iex> badid = -1
      iex> Conn.Pool.extra(pool, badid, :some)
      :error
      #
      iex> filter = & &1.extra == :extra
      iex> Conn.Pool.call(pool, agent, :get, filter, & &1)
      {:error, :filter}
      #
      # but:
      iex> Conn.Pool.call(pool, agent, :get, & &1.extra == :some, & &1)
      {:ok, 42}
  """
  @spec extra(Conn.Pool.t(), id, any) :: {:ok, any} | :error
  def extra(pool, id, extra) do
    with {:ok, info} <- info(pool, id) do
      conns = AgentMap.get(pool, :conns)
      AgentMap.put(conns, id, %{info | extra: extra})
      {:ok, info.extra}
    end
  end

  @doc """
  Retrives connection wraped in a `%Conn{}`.
  Returns `{:ok, Conn.info}` or `:error`.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, fn -> 42 end)
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.extra
      nil
      iex> Conn.Pool.extra(pool, id, :extra)
      {:ok, nil}
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.extra
      :extra
  """
  @spec info(Conn.Pool.t(), id) :: {:ok, %Conn{}} | :error
  def info(pool, id) when is_integer(id) do
    conns = AgentMap.get(pool, :conns)

    AgentMap.get(conns, id, fn
      nil -> :error
      info -> {:ok, info}
    end)
  end
end
