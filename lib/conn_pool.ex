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
  Makes `Conn.call/3` to connection with given id.

  Pool respects refresh timeout value returned by `Conn.call/3`.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, {id, _conn}} = Pool.fetch_first( source, [:say, :listen])
      iex> :ok = Pool.call( id, :say, what: "Hi!")
  """
  @spec call( Conn.id, Conn.method, id, keyword) :: :ok
                                                   | {:ok, any}
                                                   | {:error, any | {:timeout, timeout}}
  def call( id, method, pool_id, specs \\ []) do
    Server.name( pool_id)
    |> GenServer.call( {:call, {id, method, specs}})
  end


  @doc """
  `cast/4` is a "call and forget" and returns `:ok` immediately if there is a
  connection capable to make such call, or `{:error, :resource} | {:error,
  :method}` otherwise.

  See `call/4` for details.
  """
  @spec cast( Conn.Pool.t, Conn.resource, Conn.method, any)
        :: :ok | {:error, :resource | :method}
  def cast( pool, resource, method, payload) do
    GenServer.call pool, {:cast, resource, method, payload}
  end


  @doc """
  `:extra` field of `%Conn{}` is useful for filter conns used for call.

  It returns .

  ## Example

      iex> pool = Conn.Pool.start()
      iex> conn1 = Conn.init %Conn.Agent{}, fn -> 24 end
      iex> conn2 = Conn.init %Conn.Agent{}, fn -> 33 end
      iex> conn3 = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> id1 = Conn.Pool.put pool, conn1, :main
      iex> %Conn{conn: conn2, extra: :secondary}
      iex> id2 = Conn.Pool.put pool, conn2, :secondary

      iex> id2 = Conn.Pool.init %Conn.Agent{}, fn -> 43 end

      iex> Conn.Pool.extra pool, id1, :main
      nil
      iex> Conn.Pool.extra pool, id2, :secondary
      iex> Conn.Pool.call &1
  """
  @spec extra( Conn.Pool.t, id, extra) :: {:ok, any} | :error
  def extra( pool, id, extra) do
    GenServer.call pool, {:extra, id, extra}
  end


  # @doc """
  # Add tag to given connection so later it can be filtered
  # using `tags/1` with `Conns.Pool.lookup/4`, `Conns.Pool.take_first/4`
  # and any other pool's function that supports filter argument.

  # Use `Conn.Defaults` to define function `add_tag/2`, `delete_tag/2`
  # and `tags/1` to return `:notsupported`.
  # """
  # @spec add_tag( Conn.t, tag) :: Conn.t | :notsupported
  # def add_tag( conn, tag)


  # @doc """
  # Delete tag from given connection.

  # Use `Conn.Defaults` to define function `add_tag/2`, `delete_tag/2`
  # and `tags/1` to return `:notsupported`.
  # """
  # @spec delete_tag( Conn.t, tag) :: Conn.t | :notsupported
  # def delete_tag( conn, tag)


  # @doc """
  # All tags associated with given connection. Tags can be added via
  # `Conn.add_tag/2` function and deleted via `Conn.delete_tag/2`.

  # Use `Conn.Defaults` to define function `add_tag/2`, `delete_tag/2`
  # and `tags/1` to return `:notsupported`.
  # """
  # @spec tags( Conn.t) :: [tag] | :notsupported
  # def tags( conn)
end
