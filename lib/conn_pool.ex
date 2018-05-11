defmodule Conn.Pool do
  import Conn.Pool.Helpers, except: [pop: 2]

  require Logger

  @moduledoc """
  Connection pool helps storing and sharing connections. It also make its
  possible to use the same connection concurrently. For example, if there are
  many similar APIs, the pool can provide shared concurrent access, making call
  queues, if necessary. If any of conns became closed/expires — pool will
  reinitialize or drop defective connection and awaiting calls will be moved to
  the queue of another connection.

  Start pool via `start_link/1` or `start/1`. Initialize connection externally
  via `Conn.init/2` and add it to the pool with `put!/3`. Make calls directly
  from pool via `call/4`. For example:

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, conn} =
      ...>   Conn.init(%Conn.HTTP{}, res: :search,
      ...>                           url: "https://google.com")
      iex> Conn.Pool.put!(pool, conn)
      :ok
      iex> {:ok, resp} = Conn.Pool.call(pool, :search, :get)
      iex> resp.body =~ "Google"
      true

  After initialization of HTTP connection (here it's simply returns
  `%Conn.HTTP{res: :search, url: "https://google.com", mirrors: []}`) we
  transfer control of it to `pool`, so when `Conn.Pool.call/3` call made, `pool`
  decides which conn to be used for call (with resource and method identifiers).

  It's possible to interact not only with HTTP resources. Any abstract resource
  can be used. In the following examples, `%Conn.Agent{}` represents connection
  to some `Agent` that can be created with `Conn.init/2`. Available methods of
  interaction are `:get`, `:get_and_update`, `:update` and `:stop` (see
  `Conn.methods!/1`). This type of connection means to exist only as an example,
  see `Conn` protocol for details.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, res: agent)
      iex> Conn.Pool.put!(pool, conn, extra: [type: :agent])
      :ok
      iex> Conn.Pool.info(pool, agent, :extra)
      [[type: :agent]]
      iex> Conn.Pool.info(pool, agent, :methods)
      [:get, :get_and_update, :update, :stop]
      iex> [[^conn]] = Conn.Pool.info(pool, agent, :conn)
      iex> ^agent = Conn.resource(conn)
      ...>
      ...> # Now we make call to the resource `agent`:
      iex> Conn.Pool.call(pool, agent, :get, & &1)
      {:ok, 42}

  See corresponding methods for details. What if in the last example we'll stop
  `agent`

  In the following example connection will be added via `put!/2`.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, res: agent)
      iex> Conn.Pool.put!(pool, %Conn{conn: conn, revive: true})
      iex> Process.alive?(agent) && Conn.Pool.has_conns?(pool, agent)
      true
      # There are conns for resource `agent` in this pool.
      iex> Conn.Pool.call(pool, agent, :stop)
      :ok
      iex> Process.alive?(agent)
      false
      iex> :timer.sleep(10)
      iex> Conn.Pool.has_conns?(pool, agent)
      false
      # Now conn is `:closed` and will be revived by pool,
      # but:
      iex> {:error, :dead, :infinity, conn} = Conn.init(conn)
      ...>
      ...> # `Conn.init/2` suggests to never reinitialize again
      ...> # (`:infinity` timeout) so pool will just drop this conn.
      ...> # — this suggests to never revive conn again.
      iex> Conn.Pool.resources(pool)
      []

  Also, TTL value could be provided. By default, expired connection will be
  revived.

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
  @type id :: non_neg_integer
  @type t :: GenServer.t()
  @type reason :: any
  @type filter :: (Conn.info() -> as_boolean(term()))
  @type prop ::
          :conn
          | :stats
          | :extra
          | :ttl
          | :timeout
          | :force_timeout
          | :revive
          | :closed
          | :unsafe
          | :only
          | :methods
          | :init_args

  @opts [
    :ttl,
    :timeout,
    :force_timeout,
    :revive,
    :closed,
    :only,
    :methods,
    :init_args,
    :unsafe
  ]

  @props [:conn, :stats, @opts]

  @type opts :: [
          ttl: timeout,
          init_args: any | [],
          extra: any | nil,
          #          closed: boolean,
          revive: boolean | :force,
          methods: [Conn.method()],
          only: [Conn.method()],
          timeout: timeout,
          force_timeout: timeout,
          revive: boolean | :force,
          unsafe: boolean
        ]

  @doc """
  Returns a specification to start a `Conn.Pool` under a supervisor. See
  `Supervisor`.
  """
  def child_spec(opts) do
    %{
      id: Conn.Pool,
      start: {Conn.Pool, :start_link, [opts]}
    }
  end

  @doc """
  Starts pool as a linked process. The same options as for
  `GenServer.start_link/3` could be provided.
  """
  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ []), do: AgentMap.start_link(opts)

  @doc """
  Starts pool. See `start_link/2` for details.
  """
  @spec start(GenServer.options()) :: GenServer.on_start()
  def start(opts \\ []), do: AgentMap.start(opts)

  @doc """
  Changes options of connection with given `id`.

  This call returns given `id` without changes and raise if there is no
  connection with such `id`.

  It is an eqivalent of the:

      {}

  ## Returns

    * id
    * `{:ok, id}` in case of `Conn.init/2` returns `{:ok, conn}`, where `id` is
      the identifier that can be used to refer `conn`;
    * `{:error, :timeout}` if `Conn.init/2` returns `{:ok, :timeout}`;
    * `{:error, reason}` in case `Conn.init/2` returns an arbitrary error.

  ## Examples

  Updates every conn to `resource` with `fun`.
  This function always returns `:ok`.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start(fn -> 42 end)
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
      iex> Conn.Pool.call(pool, agent, :get, & &1[:extra] == :extra, & &1)
      {:error, :filter}
      #
      iex> Conn.Pool.update(pool, agent, & %{&1 | extra: :extra})
      :ok
      iex> Conn.Pool.call(pool, agent, :get, & &1.extra == :extra, & &1)
      {:ok, 42}


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

  # ## Example

  #     iex> {:ok, pool} = Conn.Pool.start_link()
  #     iex> {:ok, agent} = Agent.start(fn -> 42 end)
  #     iex> {:ok, id} = Conn.Pool.init(pool, %Conn.Agent{}, res: agent)
  #     iex> Conn.Pool.extra(pool, id, :extra)
  #     {:ok, nil}
  #     iex> Conn.Pool.extra(pool, id, :some)
  #     {:ok, :extra}
  #     iex> badid = -1
  #     iex> Conn.Pool.extra(pool, badid, :some)
  #     :error
  #     #
  #     iex> filter = & &1.extra == :extra
  #     iex> Conn.Pool.call(pool, agent, :get, filter, & &1)
  #     {:error, :filter}
  #     #
  #     # but:
  #     iex> Conn.Pool.call(pool, agent, :get, & &1.extra == :some, & &1)
  #     {:ok, 42}
  """
  @spec tweak(Conn.Pool.t(), Conn.resource(), filter, opts) :: :ok
  @spec tweak(Conn.Pool.t(), Conn.resource(), filter, (opts -> opts)) :: :ok
  def tweak(pool, res, filter \\ fn _ -> true end, opts_or_upd)

  def tweak(pool, res, filter, opts) when is_list(opts) do
    tweak(pool, res, filter, &Keyword.merge(&1, opts))
  end

  def tweak(pool, res, filter, upd) do
    for id <- find(pool, res, filter) do
      AgentMap.cast(
        pool,
        fn
          [nil] ->
            :id

          [info] ->
            props = Map.from_struct(info)

            if filter.(props) do
              struct(info, upd.(props))
            else
              info
            end
        end,
        [{:conn, id}],
        !: true
      )
    end

    :ok
  end

  @doc """
  Adds `conn` to the `pool`. Returns `:ok`, no matter what.

  Makes single `Conn.method!/1` call and caches returned list in a prop named
  `:methods`. This list can be bounded, see `:only` option.

  ## Options

    * `extra` (`nil`) — extra info used to filter and identify `conn`;
    * `ttl` (`:infinity`) — time (in ms) before `conn` became expired and
      marked as closed;
    * `force_timeout` (`0` ms) — minimal timeout between any two `Conn.call/3`
      happend;
    * `revive` (`true`) — should this conn be revived if became expired or
      closed? Could be `true`, `false` or `:force`. The last makes revive
      happend even in case of error;
    * `unsafe` (`false`) — by default, all `Conn.call/3` executions happend on
      `pool` are wrapped to prevent unhandled error to violate `pool`
      functioning. This can be turned off;
    * `only` (`:all`) — list of methods to be used;
    * `init_args` (`[]`) — arguments used for `conn` initialization during
    * revive; `closed` (`false`) — if enabled, `conn` will have `closed` marked
      that prevents it to be used. Revive happens after `timeout` number of ms;
    * `timeout` (`0`) — timeout before `conn` could be used. This value will be
      rewrited with the first call.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> Conn.Pool.put!(pool, conn, extra: :secret, ttl: 100)
      :ok
      iex> res = Conn.resource(conn)
      iex> Conn.Pool.info(pool, res, :extra)
      %{extra: [:secret]}
      iex> Conn.Pool.info(pool, res, :ttl)
      %{ttl: [100]}
      iex> Conn.Pool.info(pool, res, :methods)
      %{methods: [[:get, :get_and_update, :update, :stop]]}
  """
  @spec put!(Conn.Pool.t(), Conn.t(), opts) :: :ok
  def put!(pool, conn, opts \\ []) do
    info = struct(%Conn.Info{conn: conn, last_init: now()}, opts)

    info =
      unless opts[:methods] do
        sync_methods!(info)
      end || info

    id = gen_id()

    AgentMap.update(
      pool,
      fn
        [nil, nil] ->
          [info, [id]]

        [nil, ids] ->
          [info, [id | ids]]
      end,
      [
        {:conn, id},
        {:res, Conn.resource(conn)}
      ]
    )

    :ok
  end

  def pop(pool, id) do
    Conn.Pool.Helpers.pop(pool, id)
  end

  @doc """
  Pops conns to `resource` that satisfy `filter`.

  Deletes connection with given `id` from `pool` and returns it and
  corresponding opts.

  Returns only after all calls that use this conn are executed.

  ## Returns

    * `{:ok, {conn, opts}}` in case conn with such `id` exists;
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
      iex> Conn.Pool.pop(pool, agent, & &1[:extra] == :takeme)
      iex> Conn.Pool.empty?(pool, agent)
      false
      iex> Conn.Pool.pop(pool, id2)
      iex> :timer.sleep(10)
      iex> Conn.Pool.empty?(pool, agent)
      true

  Also, see example for `put!/2`.
  """
  @spec pop(Conn.Pool.t(), Conn.resource(), filter) :: [{Conn.t(), opts}]
  def pop(pool, res, filter \\ fn _ -> true end) do
    pool
    |> find(res, filter)
    |> Enum.flat_map(fn id ->
      info = pop(pool, id)

      if info do
        [{info.conn, Map.take(info, @opts)}]
      else
        []
      end
    end)
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

        pop(pool, id)
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

  defp merge(info, conn, t \\ 0) do
    %{info | conn: conn, last_call: now(), timeout: t}
  end

  defp close(info, pool, status \\ :ok) do
    {:conn, id} = Process.get(:"$key")

    pop(pool, id)

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
      pop(pool, id)
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
              pop(pool, id)
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


        #
      # Now we'll use filter (& &1.extra[:type] != :agent).
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
  Retrives info about `prop`erty of conn with given `id`.

  Returns `{:ok, info}` if `pool` has conn with such `id`, or `:error`
  otherwise.

  ## Properties

    See `put!/3`, plus:

    * `stats` — statistics on method use in form of `%{method => {avg duration
      of call in ms, number of calls}}`;

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, res: agent)
      iex> Conn.Pool.info(pool, agent, :extra)
      %{extra: [nil]}
      iex> Conn.Pool.tweak(pool, agent, extra: :secret)
      iex> Conn.Pool.info(pool, agent, :extra)
      %{extra: [:secret]}
  """
  @spec info(Conn.Pool.t(), Conn.resource(), filter, [prop] | prop) :: %{
          optional(:extra) => [any | nil],
          optional(:ttl) => [timeout],
          optional(:timeout) => [timeout],
          optional(:force_timeout) => [timeout],
          optional(:revive) => [boolean | :force],
          optional(:closed) => [boolean],
          optional(:unsafe) => [boolean],
          optional(:methods) => [[Conn.method()]],
          optional(:stats) => [%{}],
          optional(:init_args) => [any | nil]
        }

  def info(pool, res, filter \\ fn _ -> true end, prop_s)

  def info(pool, res, filter, props) when is_list(props) do
    Enum.reduce(find(pool, res, filter), Enum.into(@props, %{}, &{&1, []}), fn id, res ->
      case AgentMap.fetch(pool, {:conn, id}) do
        {:ok, info} ->
          info = Map.from_struct(info)

          Map.merge(res, info, fn _k, vs, v ->
            [v | vs]
          end)

        _err ->
          res
      end
    end)
    |> Map.take(props)
    |> Enum.into(%{}, fn {p, vs} ->
      {p, Enum.reverse(vs)}
    end)
  end

  def info(pool, res, filter, prop) do
    info(pool, res, filter, [prop])
  end

  @doc """
  Returns all the resources known by `pool`.
  """
  @spec resources(Conn.Pool.t()) :: [Conn.resource()]
  def resources(pool) do
    pool
    |> AgentMap.keys()
    |> Enum.flat_map(fn
      {:res, r} -> [r]
      _ -> []
    end)
  end

  @doc """
  Is `pool` has conns to the given `resource`?

  Also, filter argument could be provided. Filter is a fun that takes opts as an
  argument and returns boolean value.
  """
  @spec has_conns?(Conn.Pool.t(), Conn.resource()) :: boolean
  def has_conns?(pool, res, filter \\ fn _ -> true end) do
    not Enum.empty?(find(pool, res, filter))
  end
end
