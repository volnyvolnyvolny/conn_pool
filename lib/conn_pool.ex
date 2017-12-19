defmodule Conns.Pool do
  @moduledoc """
  Connection pool is a tool for managing `Conn`'s. It supports
  functions for searching connections, requesting, taking or
  directly using them from pool and returning back/updating.
  Timeout can be set to prevent using connection for specific
  period of time.

  Start connections pool via `start_link/1` function.
  It starts as a local named service (`:"Conns.Pool"`, by
  default), but this can be configured giving different
  value for `POOL_NAME` attribute of application.

  More than one pool can be started by giving id argument
  to the `start_link/1` function.

  Interaction with pool usually divided into five steps:

  ## 0. initialize pool connections
  For this, `put/2` function is used.

      source = %JSON_API{url: "http://example.com/api/v1"}

      Conn.init( MyConn, source: source)
      |> Conns.Pool.put()

      # or

      Conns.init( source)
      |> Enum.each(&Conns.Pool.put/1)

  For latter use, `Conns` protocol should be implemented.

  If you provide `start_link/1` function with arguments
  `{POOL_ID, source_list}` or `source_list`, pool will
  be initialized with connections produced by
  `Enum.flat_map( source_list, &Conns.init/1)`.

  ## 1. choose connection
  Connection can be choosen using `lookup/4` function.

      source = %JSON_API{url: "http://example.com/api/v1"}

      Conns.Pool.lookup( source, [:say, :listen], fn conn ->
        Enum.all? [:tag1, :tag2], & &1 in Conn.tags( conn)
      end)

  this selects connections to a given source that are capable
  to interact via both `:say` and `:listen` methods and satisfy given
  condition (has both `:tag1` and `:tag2` tags).

  As the first argument of `lookup/4` you can provide `:_` atom. That
  literally means "connections to any source". So, full list of
  connections can be taken by using formula:

      Conns.Pool.lookup(:_, [])
      # which is the same as:
      Conns.Pool.lookup_all_sources([])

  It's *highly advised* to use instead of `lookup/4` combined
  functions `take_first/4` and `fetch_first/4` as they returns
  only connections with zero timeout that are valid
  for specified methods.

  ## 2. request or take connection from pool

  Connection copy can be `fetch/2`'d from pool:

      {:ok, conn} = Conns.Pool.fetch( conn_id)

  if connection with given id has timeout or if it's
  `Conn.invalid?/1`, then `fetch/2` function returns error tuple.

  There is an analog of `fetch/2` named `take/2`, which is equivalent
  to `fetch/2`, but in case of success takes connection
  from pool. That's clearly prevents others from using it.

  Moreover, there is a `grab/2` function that takes connection
  from pool even if it's `Conn.invalid?/1` or there is a timeout
  on it. Use it carefully as it brokes designed usage flow.


  This step can be combined with previous step functions:

      {:ok, conn} = Conns.Pool.take_first( source, [:say, :listen], fn conn ->
                      :reserved in Conn.tags( conn)
                    end)

  and

      {:ok, {conn_id, conn}} = Conns.Pool.fetch_first( source, [:say, :listen], fn conn ->
                                 :main in Conn.tags( conn)
                               end)

  using combined functions is a preferred way.

  ## 3. make `Conn.call/3`

  Connection can be easilly `Conn.call/3`'ed:

      {:ok, conn} = Conn.call( conn, :say, what: "hi!")

  Moreover, there are special functions `call_first/4`
  and `cast_first/4`, combining 1,2,3 step. Call or cast
  made directly from pool server, blocking it, so use
  it carefully. Cast represents asynchronious call immediately
  returns `:ok`.

  ## 4. return connection back to pool, update it, and/or setup timeout

  Connection can be returned using `put/2`. In case of error,
  to prevent using connection by others, timeout can be setted.
  This way it could be still `grab/2`'ed, but it would become
  untouchable by other functions.

  Connection changes can be integrated back to pool using
  `update/2` functions.

  ## Usage

  There are few main use-flows.

  1. Parallel use of copies of the same connection from pool:

      `fetch_first/4`
      → `Conn.call/3` | `state_of/2` | `update/2` | `set_timeout/2`
      [[→ `set_timeout/2`] → `update/2`];

  2. Blocking use of connection:

     `take_first/4` → `Conn.call/3` calls → `put/2` | `put_with_timeout/3`;

  3. Shared use of connection controlled by server process:

     `pcast_first/5` | `pcall_first/5`.

     or

     `fetch_first/4`
     → `Conn.call/3` | `state_of/2` | `update/2` | `set_timeout/2`
     [[→ `set_timeout/2`] → `update/2`].

  Be aware, that every function in `Pool` supports `POOL_ID` as the
  last argument. This way different pools can be used:

      Conns.Pool.put( conn, 0) #add conn to pool #1
      Conns.Pool.put( conn, 1) #add conn to pool #2

  ## Transactions

  Sagas-transactions would be added in next version of library.
  """

  @type  id :: atom | String.t | non_neg_integer
  @type  source :: any
  @type  auth_idx :: non_neg_integer
  @type  method_s :: Conn.method | [Conn.method] | :_


  alias Conns.Pool.Server


  @doc """
  Start connections pool. If variable `POOL_NAME` configured,
  pool process starts with given name. Otherwise default
  name used — `:"Conns.Pool"`. If `pool_id` argument is given — it
  starts as `POOL_NAME.POOL_ID` or `:Conns.Pool.POOL_ID`.
  """
  def start_link( pool_id \\ nil) do
    __MODULE__.Server.start_link( pool_id)
  end


  @doc """
  Gets connection copy from pool. It's still available
  for `getting` or `taking` by other consumers.

  If happend, timeout returned in microseconds.
  """
  @spec get( Conn.id, id) :: {:ok, Conn.t} | {:error, :notfound | {:timeout, timeout}}
  def get( id, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:get, id})
  end


  @doc """
  Takes connection from pool. You can always give it back
  to pool with `put` or `put_with_timeout`.

  If happend, timeout returned in microseconds.
  """
  @spec take( Conn.id, id) :: {:ok, Conn.t} | {:error, :notfound | {:timeout, timeout}}
  def take( id, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:take, id})
  end

  @doc """
  Put connection to pool.
  """
  @spec put( Conn.t, id) :: Conn.id
  def put( conn, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:put, conn})
  end


  @doc """
  Deletes connection with given id from pool.
  """
  @spec drop( Conn.id, id) :: id
  def drop( id, pool_id) do
    _ = take( id, pool_id)

    pool_id
  end


  @doc """
  Lookup for connections to given source, that are capable of given
  type interaction. Returns list of all connections found. Use `filter`
  as an indicator function.

  Function `lookup/4` return list of connections with
  state marks (not spended timeout in *micro*secs such
  as zero, or `:invalid`).
  """
  @spec lookup( source, method_s, (Conn.t -> boolean), id) :: [ {Conn.id, timeout, Conn.t}
                                                                | {Conn.id, :invalid}]
  def lookup( source, method_s, filter \\ fn _ -> true end, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:lookup, {source, method_s, filter}})
  end


  @doc """
  Lookup for all connections capable of given type interaction(s).
  Returns list of connections.
  """
  @spec lookup_all_sources( method_s, (Conn.t -> boolean), id) :: [ {Conn.id, timeout, Conn.t}
                                                                    | {Conn.id, :invalid}]
  def lookup_all_sources( method_s, filter \\ fn _ -> true end, pool_id \\ nil) do
    lookup(:_, method_s, filter, pool_id)
  end


  @doc """
  Change pool's copy of connection with given id.
  If there is no such connections — `put` it with given id.
  """
  @spec update_conn( Conn.id, Conn.t, id) :: Conn.t
  def update_conn( conn_id, conn, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.cast( {:update_conn, {conn_id, conn}})

    conn
  end



  @doc """
  Set timeout on all interactions for connection with given id.
  During timeout others cannot `take` or `get` it, but connection
  is still available for `update` through pool.

  Timeout encoded in microseconds.
  """
  @spec set_timeout( Conn.id, timeout, id) :: id
  def set_timeout( id, timeout, pool_id) do
    Server.name( pool_id)
    |> GenServer.cast( {:set_timeout, {id, timeout}})

    pool_id
  end

  @doc """
  Put connection back and restrict others to `take` or `get` it
  during timeout (it's still available for `update`).

  Timeout encoded in microseconds.
  """
  @spec put_with_timeout( Conn.t, timeout, id) :: id
  def put_with_timeout( conn, timeout, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.cast( {:put_with_timeout, {conn, timeout}})

    pool_id
  end


  @doc """
  Lookup for connections to given source, that are capable of given
  type interaction. Takes the first connection if it's possible.
  """
  @spec take_first( source, method_s, (Conn.t -> boolean), id) :: {:ok, Conn.t} | {:error, :notfound}
  def take_first( source, method_s, filter \\ fn _ -> true end, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:take_first, {source, method_s, filter}})
  end


  @doc """
  Get first Lookup for connections to given source, that are capable of given
  type interaction. Returns back copy of the first connection that is satisfing
  if it's possible.
  """
  @spec fetch_first( source, method_s, (Conn.t -> boolean), id) :: {:ok, {Conn.id, Conn.t}} | {:error, :notfound}
  def fetch_first( source, method_s, filter \\ fn _ -> true end, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:fetch_first, {source, method_s, filter}})
  end


  @doc """
  Makes `Conn.call/3` to connection with given id.

  If happend, timeout encoded in microseconds.

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
  Makes `Conn.call/3` to the first connection for specific source
  type of interactions.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> :ok = Pool.call_first( source, :say, what: "Hi!")
  """
  @spec call_first( source | :_, Conn.method, id, keyword) :: :ok
                                                             | {:ok, any}
                                                             | {:error, any | {:timeout, timeout}}
  def call_first( source, method, pool_id, specs \\ []) do
    Server.name( pool_id)
    |> GenServer.call( {:call_first, {source, method, specs}})
  end



  @doc """
  Asynchronious `Conn.call/3` to connection with given id. Always
  returns :ok.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, {id, _conn}} = Pool.fetch_first( source, [:say, :listen])
      iex> ^id = Pool.cast( id, :say, what: "Hi!")
  """
  @spec cast( Conn.id, Conn.method, id, keyword) :: Conn.id
  def cast( id, method, pool_id, specs \\ []) do
    Server.name( pool_id)
    |> GenServer.cast( {:cast, {id, method, specs}})

    id
  end


  @doc """
  Asynchronious `Conn.call/3` to the first given source connection for
  specific type of interactions. Always returns :ok.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> :ok = Pool.cast_first( source, :say, what: "Hi!")
  """
  @spec cast_first( source | :_, Conn.method, id, keyword) :: {:ok, {Conn.id, Conn.t}}
                                                              | {:error, :notfound}
  def cast_first( source, method, pool_id, specs \\ []) do
    with {:ok, {id,_}}=ret <- fetch_first( source, method, pool_id) do
      cast( id, method, pool_id, specs)
      ret
    end
  end
end
