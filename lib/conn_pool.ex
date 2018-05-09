defmodule Conn.Pool do
  require Logger

  @moduledoc """
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
  as an example for doctests. More meaningful example would be `Conn.HTTP`
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
      iex> Conn.Pool.call(pool, agent, :badmethod, :payload)
      {:error, :method}
      iex> Conn.Pool.call(pool, :badres, :badmethod, :payload)
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
  """

  @type t :: GenServer.t()
  @type id :: pos_integer
  @type reason :: any
  @type filter :: (Conn.info() -> as_boolean(term()))

  @doc """
  Returns a specification to start a Conn.Pool under a supervisor. See
  `Supervisor`.
  """
  def child_spec(opts) do
    %{
      id: Conn.Pool,
      start: {Conn.Pool, :start_link, [opts]}
    }
  end

  # Generate uniq id.
  defp gen_id, do: now()

  # Current monotonic time.
  defp now(), do: System.monotonic_time()

  @doc """
  Starts pool as a linked process.
  """
  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ []), do: AgentMap.start_link(opts)

  @doc """
  Starts pool. See `start_link/2` for details.
  """
  @spec start(GenServer.options()) :: GenServer.on_start()
  def start(opts \\ []), do: AgentMap.start(opts)

  @doc """
  Initialize connection in a separate `Task` and use `put!/2` to add connection
  that is wrapped in `%Conn{}`.

  By default, init time is limited by `5000` ms and pool will revive closed
  connection using `init_args` provided.

  You can safely raise inside `init/2`. `Conn.Pool` will handle this as `init/2`
  returns `{:error, {:exit, raise}, conn}` tuple.

  ## Returns

    * `{:ok, id}` in case of `Conn.init/2` returns `{:ok, conn}`, where `id` is
      the identifier that can be used to refer `conn`;
    * `{:error, :timeout}` if `Conn.init/2` returns `{:ok, :timeout}`;
    * `{:error, reason}` in case `Conn.init/2` returns an arbitrary error.
  """
  @spec init(Conn.Pool.t(), Conn.t() | Conn.info(), any) ::
          {:ok, id} | {:error, :timeout | reason}

  def init(pool, info_or_conn, init_args \\ [])

  def init(pool, %Conn{conn: conn} = info, init_args) do
    task =
      Task.async(fn ->
        Conn.init(conn, init_args)
      end)

    case Task.yield(task, :infinity) || Task.shutdown(task) do
      {:ok, {:ok, conn}} ->
        {:ok, put!(pool, %{info | conn: conn, init_args: init_args})}

      {:ok, err} ->
        err

      nil ->
        {:error, :timeout}
    end
  end

  def init(pool, conn, init_args) do
    init(pool, %Conn{conn: conn}, init_args)
  end

  # Add conn to pool.
  defp add(pool, %{last_init: :never} = info) do
    add(pool, %{info | last_init: now()})
  end

  defp add(pool, info) do
    id = gen_id()
    AgentMap.put(pool, {:conn, id}, info)

    r = Conn.resource(info.conn)

    AgentMap.update(pool, {:res, r}, fn
      nil -> [id]
      ids -> [id | ids]
    end)

    id
  end

  defp add_methods!(info) do
    if info.methods && is_list(info.methods) do
      info
    else
      case Conn.methods!(info.conn) do
        {methods, conn} when is_list(methods) ->
          %{info | methods: methods, conn: conn}

        methods when is_list(methods) ->
          %{info | methods: methods}

        ret ->
          raise("""
            Conn.methods!/1 call expected to return [method]
            or {[method], updated conn}, but instead #{inspect(ret)} returned.
          """)
      end
    end
  end

  @doc """
  Adds given `%Conn{}` to pool, returning id to refer it later.
  This call always refresh data cached in `%Conn{}.methods`.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> ttl = 100 # ms
      iex> info = %Conn{
      ...>   conn: conn,
      ...>   extra: :extra,
      ...>   ttl: ttl
      ...> }
      iex> id = Conn.Pool.put!(pool, info)
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> ^ttl = info.ttl
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.extra
      :extra
      #
      # let's make some tweak
      #
      iex> {:ok, info} = Conn.Pool.pop(pool, id)
      iex> id = Conn.Pool.put!(pool, %{info| ttl: :infinity})
      iex> {:ok, info} = Conn.Pool.info(pool, id)
      iex> info.ttl
      :infinity
  """
  @spec put!(Conn.Pool.t(), Conn.info()) :: id
  def put!(pool, info) do
    add(pool, add_methods!(info))
  end

  defp delete(pool, id) do
    case info(pool, id) do
      {:ok, info} ->
        AgentMap.delete(pool, {:conn, id})

        AgentMap.cast(
          pool,
          fn
            [[^id]] ->
              :drop

            [ids] ->
              [List.delete(ids, id)]

            [nil] ->
              :id
          end,
          [{:res, Conn.resource(info.conn)}]
        )

      :error ->
        :ignore
    end
  end

  @doc """
  Deletes connection and returns corresponding `%Conn{}` struct.

  Returns only after all calls awaiting execution on this conn are made.

  ## Returns

    * `{:ok, Conn struct}` in case conn with such id exists;
    * `:error` — otherwise.

  ## Examples

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:ok, 42}
      iex> {:ok, %Conn{conn: conn}} = Conn.Pool.pop(pool, id)
      iex> Conn.Pool.pop(pool, id)
      :error
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:error, :resource}
      # But, still:
      iex> Agent.get(Conn.resource(conn), & &1)
      42

  Also, you can pop only those connections that satisfy the specified filter.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
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
      iex> :timer.sleep(10)
      iex> Conn.Pool.empty?(pool, agent)
      true

  Also, see example for `put!/2`.
  """
  @spec pop(Conn.Pool.t(), Conn.id()) :: {:ok, Conn.info()} | :error
  def pop(pool, id) when is_integer(id) do
    AgentMap.get_and_update(pool, {:conn, id}, fn
      nil ->
        {:error}

      info ->
        delete(pool, id)
        {{:ok, info}, nil}
    end)
  end

  @doc """
  Pops conns to `resource` that satisfy `filter`.
  """
  @spec pop(Conn.Pool.t(), Conn.resource(), filter) :: [Conn.info()]
  def pop(pool, resource, filter) when is_function(filter, 1) do
    pool = AgentMap.new(pool)
    ids = pool[{:res, resource}] || []

    for id <- ids, filter.(pool[{:conn, id}]) do
      pop(pool, id)
    end
  end

  @doc """
  Applies given `fun` to every `resource` conn.
  """
  @spec map(Conn.Pool.t(), Conn.resource(), (Conn.info() -> a)) :: [a] when a: var
  def map(pool, resource, fun) when is_function(fun, 1) do
    pool = AgentMap.new(pool)
    ids = pool[{:res, resource}] || []

    for id <- ids, do: fun.(pool[{:conn, id}])
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
  Updates connections to `resource` that satisfy given `filter`. This function
  always returns `:ok`.

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
  @spec update(Conn.Pool.t(), Conn.resource(), filter, (Conn.info() -> Conn.info())) :: :ok
  def update(pool, resource, filter, fun) when is_function(fun, 1) and is_function(filter, 1) do
    pool = AgentMap.new(pool)
    ids = pool[{:res, resource}] || []

    self = self()

    for id <- ids do
      AgentMap.update(pool, {:conn, id}, fn info ->
        if filter.(info) do
          try do
            add_methods!(fun.(info))
          rescue
            e ->
              Process.exit(self, """
              Error while making Conn.methods!/1 call on #{inspect(info.conn)}:
              #{inspect(Exception.message(e))}.
              """)

              info
          end
        else
          info
        end
      end)
    end

    :ok
  end

  @doc """
  Is `pool` has conns to the given `resource`?
  """
  @spec empty?(Conn.Pool.t(), Conn.resource()) :: boolean
  def empty?(pool, resource) do
    not AgentMap.has_key?(pool, {:res, resource})
  end

  @doc """
  Returns all the known resources.
  """
  @spec resources(Conn.Pool.t()) :: [Conn.resource()]
  def resources(pool) do
    Enum.flat_map(AgentMap.keys(pool), fn
      {:res, r} -> [r]
      _ -> []
    end)
  end

  # Returns {:ok, ids} | {:error, :resources} | {:error, method}
  # | {:error, filter}.
  defp filter(pool, resource, method, filter, except: except) when is_function(filter, 1) do
    pool = AgentMap.new(pool)
    ids = pool[{:res, resource}] || []
    import Enum

    ids =
      for id <- ids -- except do
        {id, pool[{:conn, id}]}
      end

    with {_, [_ | _] = ids} <- {:r, filter(ids, fn {_, c} -> not c.closed end)},
         {_, [_ | _] = ids} <- {:m, filter(ids, fn {_, c} -> method in c.methods end)},
         {_, [_ | _] = ids} <- {:f, filter(ids, fn {_, c} -> filter.(c) end)} do
      {:ok, for({id, _} <- ids, do: id)}
    else
      {:r, []} -> {:error, :resource}
      {:m, []} -> {:error, :method}
      {:f, []} -> {:error, :filter}
    end
  end

  defp _revive(pool, id, info) do
    case Conn.init(info.conn, info.init_args) do
      {:ok, conn} ->
        res = Conn.resource(conn)

        AgentMap.cast(pool, {:res, res}, fn
          nil -> [id]
          ids -> [id | ids]
        end)

        %{
          info
          | conn: conn,
            closed: false,
            last_init: now(),
            last_call: :never,
            timeout: 0
        }

      {:error, reason, :infinity, conn} ->
        info = %{info | conn: conn}

        Logger.error("""
        Failed to reinitialize connection.
        Reason: #{inspect(reason)}.
        Connection info: #{inspect(info)}.
        Stop trying.
        """)

        delete(pool, id)
        nil

      {:error, reason, timeout, conn} ->
        info = %{info | conn: conn}

        Logger.warn("""
        Failed to reinitialize connection with id #{id}.
        Reason: #{inspect(reason)}.
        Connection info: #{inspect(info)}.
        Will try again in #{to_ms(timeout)} ms.
        """)

        Process.sleep(timeout)
        _revive(pool, id, info)
    end
  end

  defp revive(pool, id, info) do
    AgentMap.cast(pool, {:conn, id}, fn nil ->
      _revive(pool, id, info)
    end)
  end

  # Estimated time to wait until call can be made on this id.
  defp waiting_time(pool, id) do
    with {:ok, info} <- AgentMap.fetch(pool, {:conn, id}) do
      {sum, n} =
        Enum.reduce(info.stats, {0, 0}, fn {_key, {avg, num}}, {sum, n} ->
          {sum + avg * num, n + num}
        end)

      if n == 0 do
        {:ok, info.timeout}
      else
        {:ok, sum / n * AgentMap.queue_len(pool, {:conn, id}) + info.timeout}
      end
    end
  end

  # Select the best conn.
  defp select(pool, resource, method, filter, opts \\ [except: []]) do
    with {:ok, ids} <- filter(pool, resource, method, filter, opts) do
      {:ok, Enum.min_by(ids, &waiting_time(pool, &1))}
    end
  end

  defp update_stats(info, method, start) do
    stop = System.monotonic_time()

    update_in(info.stats[method], fn
      nil -> {stop - start, 1}
      {avg, num} -> {(avg * num + stop - start) / (num + 1), num + 1}
    end)
  end

  defp to_ms(native) do
    System.convert_time_unit(native, :native, :milliseconds)
  end

  defp to_native(ms) do
    System.convert_time_unit(ms, :milliseconds, :native)
  end

  defp expired?(%{ttl: :infinity}), do: false

  defp expired?(info) do
    info.last_init + to_native(info.ttl) < now()
  end

  defp merge(info, conn, t \\ 0) do
    %{info | conn: conn, last_call: now(), timeout: t}
  end

  defp close(info, pool, status \\ :ok) do
    {:conn, id} = Process.get(:"$key")

    delete(pool, id)

    if info.revive == :force || (status != :ok && info.revive) do
      revive(pool, id, info)
    end

    %{info | closed: true, timeout: :infinity}
  end

  defp _call(%{closed: true} = info, {pool, resource, method, filter, _payload} = args) do
    {:conn, id} = Process.get(:"$key")

    case select(pool, resource, method, filter, except: [id]) do
      {:ok, id} ->
        key = {:conn, id}
        fun = &_call(&1, args)
        # Make chain call while not changing conn.
        {:chain, {key, fun}, info}

      err ->
        # Return an error while not changing conn.
        {err}
    end
  end

  defp _call(info, {pool, resource, method, filter, payload} = args) do
    {:conn, id} = Process.get(:"$key")

    if expired?(info) do
      delete(pool, id)
      if info.revive, do: revive(pool, id, info)
      _call(%{info | closed: true}, args)
    else
      start = now()
      timeout = to_native(info.timeout)

      # Time to wait.
      last_call = info.last_call

      ttw = (last_call == :never && 0) || last_call + timeout - start

      if to_ms(ttw) < 50 do
        if ttw > 0 do
          Process.sleep(to_ms(ttw))
        end

        try do
          case Conn.call(info.conn, method, payload) do
            {:noreply, conn} ->
              {:ok, merge(info, conn) |> update_stats(method, start)}

            {:noreply, t, conn} when t in [:infinity, :closed] ->
              {:ok,
               info
               |> merge(conn, :infinity)
               |> update_stats(method, start)
               |> close(pool)}

            {:noreply, timeout, conn} ->
              {:ok,
               info
               |> merge(conn, timeout)
               |> update_stats(method, start)}

            {:reply, r, conn} ->
              {{:ok, r}, merge(info, conn) |> update_stats(method, start)}

            {:reply, r, t, conn} when t in [:infinity, :closed] ->
              {{:ok, r},
               info
               |> merge(conn, :infinity)
               |> update_stats(method, start)
               |> close(pool)}

            {:reply, r, timeout, conn} ->
              {{:ok, r},
               info
               |> merge(conn, timeout)
               |> update_stats(method, start)}

            {:error, :closed} ->
              delete(pool, id)
              if info.revive, do: revive(pool, id, info)
              _call(%{info | closed: true}, args)

            {:error, reason, conn} ->
              {{:error, reason}, merge(info, conn)}

            {:error, reason, t, conn} when t in [:infinity, :closed] ->
              {{:error, reason},
               info
               |> merge(conn, :infinity)
               |> close(pool, :error)}

            {:error, reason, timeout, conn} ->
              {{:error, reason}, merge(info, conn, timeout)}

            err ->
              Logger.warn("Conn.call returned unexpected: #{inspect(err)}.")
              {err}
          end
        rescue
          e ->
            if info.unsafe do
              raise e
            else
              {:error, e}
            end
        end
      else
        # ttw > 50 ms.
        with {:ok, id} <- select(pool, resource, method, filter, except: [id]),
             {:ok, potential_ttw} <- waiting_time(pool, id),
             true <- ttw > potential_ttw do
          key = {:conn, id}
          fun = &_call(&1, args)
          {:chain, {key, fun}, info}
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

    * `{:error, :timeout}` if `Conn.call/3` returned `{:error, :timeout, _}`
      and there is no other connection capable to make this call;
    * and `{:error, reason}` in case of `Conn.call/3` returned arbitrary error.

  In case of `Conn.call/3` returns `{:error, :timeout | reason, _}`, `Conn.Pool`
  will use time penalties series, defined per pool (see `start_link/2`) or per
  connection (see `%Conn{} :penalties` field).

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
    with {:ok, id} <- select(pool, resource, method, filter) do
      key = {:conn, id}
      fun = &_call(&1, {pool, resource, method, filter, payload})
      AgentMap.get_and_update(pool, key, fun)
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
      AgentMap.put(pool, {:conn, id}, %{info | extra: extra})
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
    AgentMap.fetch(pool, {:conn, id})
  end
end
