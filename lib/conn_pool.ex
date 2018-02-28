defmodule Conn.Pool do
  use Agent

  @moduledoc """
  Connection pool. If many connections to the same resources exists and could be
  used concurrently, pool helps storing and sharing them. For example, if there
  exists remote API accessible via websocket, pool can provide shared access,
  putting calls to the queue. If connection is closed/expires/became invalid —
  pool will reinitialize or drop it.

  Start it via `start_link/1` or `start/1`. Add conns via `Conn.Pool.init/3` or
  `Conn.init/2` → `Conn.put/2` | `Conn.put/3`. Make calls from pool via
  `Conn.Pool.call/4` or `Conn.Pool.cast/4`.

  In the following examples, `%Conn.Agent{}` represents connection to some
  `Agent` that can be created separately or via `Conn.Agent.init/2`. Available
  methods of interaction are `:get, :get_and_update, :update` and `:stop` (see
  `Conn.methods/1`). This conns means to exist only as an example for doctests.
  More meaningful example would be `%Conn.Plug{}` wrapper.

      iex> pool = Conn.Pool.start()
      iex> conn = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> Agent.get Conn.resource(conn), & &1
      42
      # — resource for `conn` is the agent
      #
      iex> Conn.Pool.put pool, conn, type: :agent
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
      iex> Conn.Pool.call pool, agent, :stop
      :ok
      # this conn is closed and will be dropped by pool
      iex> Conn.Pool.call pool, agent, :get, & &1
      {:error, :resource}

  Also, `pop/2` could be used to pop `%Conn{}` struct from pool (after all calls
  in the queue are fulfilled).

      iex> pool = Conn.Pool.start_link()
      iex> conn = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> id = Conn.Pool.put pool, conn, type: :agent
      iex> Conn.Pool.call pool, Conn.resource(conn), :get, & &1
      {:ok, 42}
      #
      iex> struct = Conn.Pool.pop pool, id
      iex> struct.conn == conn
      true
      #
      iex> Conn.Pool.call pool, Conn.resource(conn), :unknown_method
      {:error, :unknownres}
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

  @type  id :: pos_integer
  @type  penalty :: (non_neg_integer -> non_neg_integer | :infinity)

  @doc """
  Starts pool as a linked process.

  Default penalty function is:

      fn 0 -> 50
         p when p < 4050 -> p*3
         p -> p
      end

  On the first error in series penalty will be 50 ms, after it grows as: `50,
  150, 450, 1350, 4050, 4050, …`

  Also, penalty could be setted to `:infinity` — this way it is treated by pool
  as closed.
  """
  @spec start_link( GenServer.options) :: GenServer.on_start
  @spec start_link( penalty, GenServer.options) :: GenServer.on_start
  def start_link( penalty \\ nil, opts) do
    __MODULE__.Server, penalty, opts
  end



  @doc """
  Starts pool.

  See `start_link/2` for details.
  """
  @spec start( GenServer.options) :: GenServer.on_start
  @spec start( penalty, GenServer.options) :: GenServer.on_start
  def start( penalty \\ nil, opts) do
    __MODULE__.Server, penalty, opts
  end

  @doc """
  Put connection to pool.

  Some of the conn methods can became `:invalid`. `Conn.state/2` == `:invalid`
  means that you are not capable to use selected method via `Conn.call/3`.

  You can still take connection if there are at least one method that is
  `:ready`.

  Pool respects order. Timestamps used as ids. So on any `*_one` call conns that
  injected earlier will be returned.

  Conns.Pool.info pool, id

  On a highly unlikely event, when `:id` param is given and there is already
  connection exists with such id runtime error would be raised.

  ## Params

  * `:spec` param can be given, see [corresponding section](#module-child-spec);
  * `:id` can be selected manually; `:pool` id can be used; `:timeout` can be
    given to restrict others to use this connection in any way during timeout
  * period. Timeout is encoded in *micro*seconds (=10^-6 sec).
  """
  @spec put( Conn.t, [timeout: timeout,
                      spec: Conn.spec,
                      id: Conn.id,
                      pool: id])
        :: Conn.id
  def put( conn, opts \\ [timeout: 0, spec: [], emit: true, pool: nil]) do
    opts = opts |> with_defaults()
                |> Keyword.put_new(:timeout, 0)
                |> Keyword.put_new(:spec, Conn.child_spec( conn))

    {:ok, id} = GenServer.call( opts[:pool],
                                {:put, conn, opts[:timeout], opts[:id]})

    if opts[:emit] do
      spawn( fn ->
        EventAction.emit(
          opts[:pool],
          {:put, {:ok, {id, conn}, opts[:timeout], opts[:spec]}})
      end)
    else
      id
    end
  end


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
    GenServer.call pool, id, :infinity
  end


  @doc """
  Makes `Conn.call/3` to given resource via given method of interaction.

  Optional `filter` param could be provided in form of `(%Conn{} -> boolean |
  priority)` callback, where `priority` is a `pos_integer`. So:

    * `false` means conn will not be used;
    * `true` | `p > 0` means conn can be used;

  Pool will use the least loaded conn with the least `p`.

  Pool respects refresh timeout value returned by `Conn.call/3`. After each call
  pool rewrites `:timeout` field of the corresponding `%Conn{}` struct.

  ## Returns

    * `{:error, :resource}` if there is no conns to given `resource`;
    * `{:error, :method}` if there exists conns to given `resource` but they does
    not provide given `method` of interaction;
    * `{:error, :filter}` if there is no conns satisfying `filter`;

    * `{:error, :timeout}` if `Conn.call/3` returned `{:error, :timeout, _, _}`
      and there is no other connection capable to make this call;
    * `{:error, :needauth}` if all the appropriate conns returned `{:error,
      :needauth, _, _}` as the result of the `Conn.call/3`;
    * and `{:error, reason}` in case of `Conn.call/3` returned arbitrary error.

    * `{:ok, reply}` in case of success.
  """
  @spec call( Conn.Pool.t, Conn.resource, Conn.method, any)
        :: {:ok, Conn.reply} | {:error, :resource | :method | :timeout | :needauth}
  @spec call( Conn.Pool.t, Conn.resource, Conn.method, filter, any)
        :: {:ok, Conn.reply} | {:error, :resource | :method | :filter}
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
  `:extra` field of `%Conn{}` is useful for filter conns used for call. Calling
  `extra/3` will change `:extra` field of connection with given `id`, while
  returning the old value in form of `{:ok, old extra}` or `:error` if pool
  don't known conn with such id.

  ## Example

      iex> pool = Conn.Pool.start()
      iex> {:ok, agent} = Agent.start fn -> 42 end
      iex> {:ok, id} = Conn.Pool.init pool, %Conn.Agent{}, agent: agent
      iex> Conn.Pool.extra pool, id, :extra
      nil
      iex> Conn.Pool.extra pool, id, :some
      :extra
      #
      # now let's use it to filter conns
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
  @spec extra( Conn.Pool.t, id, extra) :: {:ok, any} | :error
  def extra( pool, id, extra) do
    GenServer.call pool, {:extra, id, extra}
  end
end
