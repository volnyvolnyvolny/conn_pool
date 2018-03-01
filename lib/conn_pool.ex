defmodule Conn.Pool do
  use Agent

  @moduledoc """
  Connection pool helps storing, sharing and using connections. It also make it
  possible to use the same connection concurrently. For example, if there exists
  remote API accessible via websocket, pool can provide shared access, putting
  calls to the queue. If connection is closed/expires — pool will reinitialize
  or drop it and awaiting calls will be moved to another connection queue.

  Start pool via `start_link/1` or `start/1`. Add connections via `init/3` or
  `Conn.init/2` → `put/2` | `put/3`. Make calls from pool via `call/4` or
  `cast/4`.

  In the following examples, `%Conn.Agent{}` represents connection to some
  `Agent` that can be created separately or via `Conn.init/2`. Available methods
  of interaction with `Agent` are `:get`, `:get_and_update`, `:update` and
  `:stop` (see `Conn.methods/1`). This type of connection means to exist only as
  an example for doctests. More meaningful example would be `%Conn.Plug{}`, that
  is a wrapper. Also, see `Conn` docs for detailed example on `Conn` protocol
  implementation and using.

      iex> pool = Conn.Pool.start()
      iex> conn = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> Agent.get Conn.resource(conn), & &1 # here `Conn.resource(conn)` is the agent pid
      42
      #
      iex> id = Conn.Pool.put pool, conn, type: :agent
      iex> agent = Conn.resource conn
      iex> Conn.Pool.call pool, agent, :get, & &1
      {:ok, 42}
      iex> Conn.Pool.cast pool, agent, :update, & &1+1
      iex> Conn.Pool.call pool, agent, :get, & &1
      {:ok, 43}
      iex> Conn.Pool.call pool, agent, :some_method
      {:error, :method}
      iex> Conn.Pool.call pool, :some_res, :some_method
      {:error, :resource}
      iex> (Conn.Pool.info pool, id).extra
      [type: :agent]
      #
      iex> Conn.Pool.call pool, agent, :stop
      :ok
      # this conn is `:closed` and will be dropped by pool
      iex> Conn.Pool.call pool, agent, :get, & &1
      {:error, :resource}
      iex> Conn.Pool.info pool, id
      :error

  In the above example connection will not be reinitialized, because it was
  added to pool via `put/3`. In the following example

  Also, `pop/2` could be used to pop `%Conn{}` struct from pool (after all calls
  in the queue are fulfilled).

      iex> pool = Conn.Pool.start_link()
      iex> id = Conn.Pool.init pool, %Conn.Agent{}, fn -> 42 end
      iex> info = Conn.Pool.pop pool, id
      iex> put_in 
      iex> Conn.Pool.put
      iex> Conn.Pool.call pool, Conn.resource(info.conn), :get, & &1
      {:ok, 42}
      #
      iex> Conn.Pool.call pool, Conn.resource(info.conn), :some_method
      {:error, :method}
      iex> Conn.Pool.call pool, Conn.resource(info.conn), :some_method
      {:error, :method}
      # as conn was deleted
      iex> struct.tags
      [type: :agent]
      iex> struct.methods
      [:get, :get_and_update, :update, :stop]
      iex> struct.timeout
      0
      # as there is no need to wait until make call again
      iex> struct.penalty
      0
      # as there was no errors while making call
      iex> struct.init_args
      nil
      iex> struct.recreate
      false
      iex> %{get: %{avg: _native, used: num, errors: 0}} = struct.stats
      iex> num
      1
      # as it was used only once
      #
      # return conn back to pool with `Conns.Pool.put/3`
      iex> _newid = Conns.Pool.put pool, struct

  Pool takes care of connections it holding. Connection that became `:closed`
  will be removed or recreated if `init_args` where given via `put/4`.

      iex> pool = Conn.Pool.start_link()
      iex> init_args = fn -> 42 end
      iex> conn = Conn.init %Conn.Agent{}, init_args
      iex> id = Conn.Pool.put pool, conn, init_args, type: :agent
      iex> Conn.Pool.call pool, Conn.resource(conn), :get, & &1
      {:ok, 42}
      #
      iex> Conn.Pool.call pool, Conn.resource(conn), :stop
      {:ok, :ok}
      # server will recreate connection
      iex> Conn.Pool.call pool, Conn.resource(conn), :get, & &1
      {:ok, 42}

  ## Name registration

  An `Conn.Pool` is bound to the same name registration rules as `GenServer`s.
  Read more about it in the `GenServer` docs.
  """

  @type  t :: GenServer.t
  @type  id :: pos_integer
  @type  reason :: any
  @type  penalty :: non_neg_integer | :infinity
  @type  filter :: (%Conn{} -> boolean | non_neg_integer)

  @penalties [50, 100, 500, 1000, 2000, 5000]


  @doc """
  Starts pool as a linked process.

  As an init argument, penalties list in ms could be provided. By default it's
  `[50, 100, 500, 1000, 2000, 5000]`, which means that every connection, by
  default, after the first error will wait 50 ms until used again. If error
  happenes again after retry, time penalty grows as `50 ms, 100 ms, …, 5000 ms,
  5000 ms, 5000 ms` and so on. Also, `[…, :infinity]` means that after a few
  tryies conn would be treated by pool as closed (it will be deleted or
  reinited).
  """
  @spec start_link([penalty], GenServer.options) :: GenServer.on_start
  def start_link( penalties \\ @penalties, opts) do
    GenServer.start_link __MODULE__.Server, penalties, opts
  end


  @doc """
  Starts pool. See `start_link/2` for details.
  """
  @spec start([penalty], GenServer.options) :: GenServer.on_start
  def start( penalties \\ @penalties, opts) do
    GenServer.start __MODULE__.Server, penalties, opts
  end

  # @doc """
  # Put connection to pool.

  # Some of the conn methods can became `:invalid`. `Conn.state/2` == `:invalid`
  # means that you are not capable to use selected method via `Conn.call/3`.

  # You can still take connection if there are at least one method that is
  # `:ready`.

  # Pool respects order. Timestamps used as ids. So on any `*_one` call conns that
  # injected earlier will be returned.

  # Conns.Pool.info pool, id

  # On a highly unlikely event, when `:id` param is given and there is already
  # connection exists with such id runtime error would be raised.

  # ## Params

  # * `:spec` param can be given, see [corresponding section](#module-child-spec);
  # * `:id` can be selected manually; `:pool` id can be used; `:timeout` can be
  #   given to restrict others to use this connection in any way during timeout
  # * period. Timeout is encoded in *micro*seconds (=10^-6 sec).
  # """
  # @spec put( Conn.t, [timeout: timeout,
  #                     spec: Conn.spec,
  #                     id: Conn.id,
  #                     pool: id])
  #       :: Conn.id
  # def put( conn, opts \\ [timeout: 0, spec: [], emit: true, pool: nil]) do
  #   opts = opts |> with_defaults()
  #               |> Keyword.put_new(:timeout, 0)
  #               |> Keyword.put_new(:spec, Conn.child_spec( conn))

  #   {:ok, id} = GenServer.call( opts[:pool],
  #                               {:put, conn, opts[:timeout], opts[:id]})

  #   if opts[:emit] do
  #     spawn( fn ->
  #       EventAction.emit(
  #         opts[:pool],
  #         {:put, {:ok, {id, conn}, opts[:timeout], opts[:spec]}})
  #     end)
  #   else
  #     id
  #   end
  # end


  @doc """
  Pop connection with given id from pool.

  Conn is returned only after after all calls in the queue of the conn with
  given id are fulfilled.

  ## Returns

      * `{:ok, conn struct}` in case conn with such id exists;
      * `:error` — otherwise.

  ## Example

      iex> pool = Conns.Pool.start_link()
      iex> id = Conns.Pool.init pool, %Conn.Agent{}, fn -> 42 end
      iex> Conns.Pool.tags pool, id, type: :agent
      nil
      iex> {:ok, struct} = Conns.Pool.pop pool, id
      iex> struct.tags
      [type: agent]
      iex> Conns.Pool.pop pool, id
      :error

  This method could be used to make advanced tune of the conn added to pool.
  """
  @spec pop( Conns.Pool.t, Conn.id) :: {:ok, %Conn{}}  | :error
  def pop( pool, id) do
    GenServer.call pool, {:pop, id}, :infinity
  end


  @doc """
  Select one of the connections to given `resource` and make `Conn.call/3` via
  given `method` of interaction.

  Optional `filter` param could be provided in form of `(%Conn{} -> boolean |
  priority)` callback, where `priority` is a `non_neg_integer`. Callback may return

    * `false | nil`, specifying that conn will not be used;
    * `true | p ≥ 0`, meaning that tested conn can be used.

  Connections for which `true` or `p ≥ 0` returned are sorted and pool will
  select the `Enum.min/1` value. O Pool will use the conn with the least `p`.

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
  def call( pool, resource, method, payload \\ nil) do
    GenServer.call pool, {:call, resource, method, fn _ -> true end, payload}
  end
  def call( pool, resource, method, filter, payload) do
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
  @spec cast( Conn.Pool.t, Conn.resource, Conn.method, any)
        :: :ok | {:error, :resource | :method}
  @spec cast( Conn.Pool.t, Conn.resource, Conn.method, filter, any)
        :: :ok | {:error, :resource | :method | :filter}
  def cast( pool, resource, method, payload \\ nil) do
    GenServer.call pool, {:cast, resource, method, fn _ -> true end, payload}
  end
  def cast( pool, resource, method, filter, payload) do
    GenServer.call pool, {:cast, resource, method, filter, payload}
  end


  @doc """
  `:extra` field of `%Conn{}` is intended for filtering conns while making call.
  Calling `extra/3` will change `:extra` field of connection with given `id`,
  while returning the old value in form of `{:ok, old extra}` or `:error` if
  pool don't known conn with such id.

  ## Example

      iex> pool = Conn.Pool.start()
      iex> {:ok, agent} = Agent.start fn -> 42 end
      iex> {:ok, id} = Conn.Pool.init pool, %Conn.Agent{}, agent: agent
      iex> Conn.Pool.extra pool, id, :extra
      nil
      iex> Conn.Pool.extra pool, id, :some
      :extra
      #
      iex> filter = fn
      ...>   %Conn{extra: :extra} -> true
      ...>   _ -> false
      ...> end
      iex> Conn.Pool.call pool, agent, :get, filter, & &1
      {:error, :filter}
      #
      # but:
      #
      iex> Conn.Pool.call pool, agent, :get, fn
      ...>   %Conn{extra: :some} -> true
      ...> end, & &1
      {:ok, 42}
  """
  @spec extra( Conn.Pool.t, id, any) :: {:ok, any} | :error
  def extra( pool, id, extra) do
    GenServer.call pool, {:extra, id, extra}
  end
end
