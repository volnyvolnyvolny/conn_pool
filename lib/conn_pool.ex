defmodule Conn.Pool do
  use Agent

  @moduledoc """
  Connection pool helps storing, sharing and using connections. It also make it
  possible to use the same connection concurrently. For example, if there exists
  remote API accessible via websocket, pool can provide shared access, making
  queues of calls. If connection is closed/expires — pool will reinitialize or
  drop it and awaiting calls will be moved to another connection queue.

  Start pool via `start_link/1` or `start/1`. Add connections via `init/3` or
  `Conn.init/2` → `put/2`. Make calls from pool via `call/4` or `cast/4`.

  In the following examples, `%Conn.Agent{}` represents connection to some
  `Agent` that can be created separately or via `Conn.init/2`. Available methods
  of interaction with `Agent` are `:get`, `:get_and_update`, `:update` and
  `:stop` (see `Conn.methods/1`). This type of connection means to exist only as
  an example for doctests. More meaningful example would be `Conn.Plug` wrapper.
  Also, see `Conn` docs for detailed example on `Conn` protocol implementation
  and use.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link fn -> 42 end
      iex> {:ok, id} = Conn.Pool.init %Conn.Agent{}, res: agent # `agent` is the resource for `Conn.Agent`
      iex> Conn.Pool.extra pool, id, type: :agent # add `extra` info
      nil
      iex> info = Conn.Pool.info pool, id # pool wraps conn into `%Conn{}` struct
      iex> info.extra
      [type: :agent]
      iex> agent == Conn.resource info.conn
      true
      #
      iex> Conn.Pool.call pool, agent, :get, & &1
      {:ok, 42}
      iex> Conn.Pool.call pool, agent, :get, fn info ->
      ...>   info.extra[:type] != :agent
      ...> end, & &1
      {:error, :filter}
      #
      iex> Conn.Pool.cast pool, agent, :update, & &1+1
      iex> Conn.Pool.call pool, agent, :get, & &1
      {:ok, 43}
      iex> Conn.Pool.call pool, agent, :badmethod
      {:error, :method}
      iex> Conn.Pool.call pool, :badres, :badmethod
      {:error, :resource}

  In the above example connection was initialized and used directly from pool.
  `%Conn{}.extra` information that was given via `Conn.Pool.extra/3` was used to
  filter conn to be selected in `Conn.Pool.call/5` call.

  In the following example connection will be added via `put/2`.

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, c} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> pid = c.res
      iex> info = %Conn{conn: c, init_args: [res: pid], revive: true} # wrap
      iex> id = Conn.Pool.put pool, info # may return `:error` if
      iex> Conn.Pool.info(pool, id).methods
      [:get, :get_and_update, :update, :stop]
      # `put/2` and `put/3` are making `Conn.methods/1` call, writing results
      #
      # let's close conn:
      iex> Process.alive?(pid) && not Conn.Pool.empty?(pool, pid)
      true
      # there are conns for resource `pid` in this pool
      iex> Conn.Pool.call pool, pid, :stop
      :ok
      iex> not Process.alive?(pid) && Conn.Pool.empty?(pool, pid)
      true
      # now conn is `:closed` and will be reinitialized by pool
      # but
      iex> {:error, :dead, :infinity, info.conn} == Conn.init %Conn.Agent{}, res: c.res
      true
      # `Conn.init/2` suggests to never reinitialize again (`:infinity` timeout)
      # so pool will just drop this conn
      iex> Conn.Pool.resources pool
      []

  ## Name registration

  An `Conn.Pool` is bound to the same name registration rules as `GenServer`s.
  Read more about it in the `GenServer` docs.
  """

  @type  t :: GenServer.t
  @type  id :: pos_integer
  @type  reason :: any
  @type  filter :: (%Conn{} -> boolean | non_neg_integer | nil)
  @type  conn_info :: %Conn{}

  @doc """
  Starts pool as a linked process.
  """
  @spec start_link(GenServer.options) :: GenServer.on_start
  def start_link(opts) do
    GenServer.start_link __MODULE__.Server, nil, opts
  end


  @doc """
  Starts pool. See `start_link/2` for details.
  """
  @spec start(GenServer.options) :: GenServer.on_start
  def start(opts) do
    GenServer.start __MODULE__.Server, nil, opts
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

  @spec init( Conn.Pool.t, Conn.t, any)
        :: {:ok, id} | {:error, :timeout | :methods | reason}
  @spec init( Conn.Pool.t, conn_info, any)
        :: {:ok, id} | {:error, :timeout | :methods | reason}

  def init( pool, info_or_conn, init_args \\ nil)
  def init( pool, %Conn{conn: conn}=info, init_args) do
    task = Task.async fn ->
      Conn.init conn, init_args
    end
    case Task.yield(task, info.init_timeout) || Task.shutdown task do
      {:ok, {:ok, conn}} ->
        info = %{info | conn: conn}
        put pool, Map.put_new(info, :init_args, init_args)
      {:ok, err} ->
        err
      nil ->
        {:error, :timeout, 0, conn}
    end
  end
  def init( pool, conn, init_args) do
    init pool, %Conn{conn: conn}, init_args
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
      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> at = System.system_time()+System.convert_time_unit(5, :second, :native)
      iex> info = %Conn{
      ...>   conn: conn,
      ...>   extra: :extra,
      ...>   expires: at
      ...> }
      iex> {:ok, id} = Conn.Pool.put pool, info
      iex> ^at = Conn.Pool.info(pool, id).expires
      iex> Conn.Pool.info(pool, id).extra
      :extra
      #
      # let's make some tweak
      #
      iex> {:ok, info} = Conn.Pool.pop info, id
      iex> {:ok, id} = Conn.Pool.put pool, %{info| expires: nil}
      iex> Conn.Pool.info(pool, id).expires
      nil
  """
  @spec put(Conn.Pool.t, conn_info)
        :: {:ok, id}  | {:error, :methods | :timeout}

  def put(pool, %Conn{conn: conn}=info) do
    task = Task.async fn ->
      Conn.methods conn
    end
    case Task.yield(task, info.init_timeout) || Task.shutdown task do
      {:ok, {methods, conn}} ->
        {:ok, GenServer.call(pool, {:put, %{info | methods: methods, conn: conn}})}
      {:ok, :error} ->
        {:error, :methods}
      {:ok, methods} ->
        {:ok, GenServer.call(pool, {:put, %{info | methods: methods}})}
      nil ->
        {:error, :timeout}
    end
  end


  @doc """
  Pop `%Conn{}` that wraps connection with given `id` from pool.

  Conn is returned only after all calls in the corresponding queue are
  fulfilled.

  ## Returns

    * `{:ok, Conn struct}` in case conn with such id exists;
    * `:error` — otherwise.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start_link fn -> 42 end
      iex> {:ok, id} = Conn.Pool.init pool, %Conn.Agent{}, res: agent
      iex> %Conn{conn: c} = Conn.Pool.pop pool, id
      iex> Agent.get Conn.resource(c), & &1
      42
      iex> Conn.Pool.pop pool, id
      :error
      iex> {:ok, id1} = Conn.Pool.init pool, %Conn.Agent{}, res: agent
      iex> {:ok, id2} = Conn.Pool.init pool, %Conn.Agent{}, res: agent
      iex> {:ok, id3} = Conn.Pool.init pool, %Conn.Agent{}, res: agent
      iex> Conn.Pool.extra pool, id1, :takeme
      nil
      iex> Conn.Pool.extra pool, id3, :takeme
      iex> [info1, info3] = Conn.Pool.pop pool, fn
      ...>   %{extra: :takeme} -> true
      ...>   _ -> false
      ...> end
      iex> Conn.Pool.empty? pool, agent
      false
      iex> Conn.Pool.pop pool, id2
      iex> Conn.Pool.empty? pool, agent
      true

  Also, see example for `put/2`.
  """
  @spec pop(Conn.Pool.t, Conn.id) :: {:ok, conn_info} | :error
  def pop(pool, id) do
    GenServer.call pool, {:pop, id}, :infinity
  end

  @doc """
  Pop conns to `resource` that satisfy `filter`.
  """
  @spec pop(Conn.Pool.t, Conn.resource, (conn_info -> boolean)) :: [conn_info]
  def pop(pool, resource, filter) do
    GenServer.call pool, {:pop, resource, filter}, :infinity
  end


  @doc """
  Is there exists conns to given `resource`?
  """
  @spec empty?(Conn.Pool.t, Conn.resource) :: boolean
  def empty?(pool, resource), do: :TODO


  @doc """
  Is there exists conns to given `resource`?
  """
  @spec empty?(Conn.Pool.t, Conn.resource) :: boolean
  def resources(pool), do: GenServer.call pool, :resources


  @doc """
  Select one of the connections to given `resource` and make `Conn.call/3` via
  given `method` of interaction.

  Optional `filter` param could be provided in form of `(%Conn{} -> boolean |
  priority | nil)` callback, where `priority` is a `non_neg_integer`. Callback
  may return

    * `false | nil`, specifying that conn cannot be used;
    * `true`, means that conn is `preferred` to use;
    * `p ≥ 0`, means that if conns for which `true` returns are unavailable,
      conns with `p == 0` will be used and so on…

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
  @spec call( Conn.Pool.t, Conn.resource, Conn.method, any)
        :: :ok | {:ok, Conn.reply} | {:error, :resource | :method | :timeout | reason}
  @spec call( Conn.Pool.t, Conn.resource, Conn.method, filter, any)
        :: :ok | {:ok, Conn.reply} | {:error, :resource | :method | :filter | :timeout | reason}
  def call(pool, resource, method, payload \\ nil) do
    call pool, resource, method, fn _ -> true end, payload
  end
  def call(pool, resource, method, filter, payload) do
    GenServer.call pool, {:call, resource, method, filter, payload}
  end


  @doc """
  `cast/4` is a "call and forget" and returns `:ok` immediately if there is a
  connection capable to interact with given resource via given method, or
  `{:error, :resource} | {:error, :method}` otherwise.

  Optional `filter` param could be provided in this case, also, `{:error,
  :filter}` could be returned.

  See `call/4` for details.
  """
  @spec cast(Conn.Pool.t, Conn.resource, Conn.method, any)
        :: :ok | {:error, :resource | :method}
  @spec cast(Conn.Pool.t, Conn.resource, Conn.method, filter, any)
        :: :ok | {:error, :resource | :method | :filter}
  def cast(pool, resource, method, payload \\ nil) do
    cast pool, resource, method, fn _ -> true end, payload
  end
  def cast(pool, resource, method, filter, payload) do
    GenServer.call pool, {:cast, resource, method, filter, payload}
  end


  @doc """
  `:extra` field of `%Conn{}` is intended for filtering conns while making call.
  Calling `extra/3` will change `:extra` field of connection with given `id`,
  while returning the old value in form of `{:ok, old extra}` or `:error` if
  pool don't known conn with such id.

  ## Example

      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> {:ok, agent} = Agent.start fn -> 42 end
      iex> {:ok, id} = Conn.Pool.init pool, %Conn.Agent{}, res: agent
      iex> Conn.Pool.extra pool, id, :extra
      {:ok, nil}
      iex> Conn.Pool.extra pool, id, :some
      {:ok, :extra}
      iex> Conn.Pool.extra pool, :badid, :some
      :error
      #
      iex> filter = fn
      ...>   %Conn{extra: :extra} -> true
      ...>   _ -> false
      ...> end
      iex> Conn.Pool.call pool, agent, :get, filter, & &1
      {:error, :filter}
      #
      # but:
      iex> Conn.Pool.call pool, agent, :get, fn
      ...>   %Conn{extra: :some} -> true
      ...>   _ -> false
      ...> end, & &1
      {:ok, 42}
  """
  @spec extra(Conn.Pool.t, id, any) :: {:ok, any} | :error
  def extra(pool, id, extra) do
    GenServer.call pool, {:extra, id, extra}
  end
end
