defmodule Conns.Pool do
  @moduledoc """
  Start connections pool via `start_link/1` function.
  It starts as a named service (`:"Conns.Pool"` used by
  default), but this can be configured by changing `POOL_NAME`
  attribute of application.

  More than one pool can be started by giving id argument
  to the `start_link/1` function.

  Connection can be choosen with `get_first/3` or `take_first/3`.
  Full list of connections satisfying given condition can be
  found using `lookup/4` function. Later, connection can be used
  via `Conn.call/3`. Moreover, connection with known id can be
  used directly from pool process via `cast/4` and `call/4`
  functions. This procedure can be combined in `cast_first/4`
  and `call_first/4` calls.

  Interaction with pool divided into three steps:

  1. choose connection;
  2. take choosen connection from pool or use `get/2` function
  to retrive a copy by id.
  3. make `call/4` using connection;
  4. return connection if it was taken or setup timeout in case of error.

  Pool can be populated with connections through
  `put( Conn.init( MyConn, ARGS))` or ``.

  There are two main use-paths:

  * `lookup/4` → choose connection → `get/2` or `take/2` → `Conn.call/3`
  → return updated conn back if it was `take/2`en (with `put/2` or
  `put_with_timeout/3`);
  * `take_first/3` or `get_first/3` → 
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
  @spec take_first( source, method_s, id) :: {:ok, Conn.t} | {:error, :notfound}
  def take_first( source, method_s, filter \\ fn _ -> true end, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:take_first, {source, method_s, filter}})
  end


  @doc """
  Get first Lookup for connections to given source, that are capable of given
  type interaction. Returns back copy of the first connection that is satisfing
  if it's possible.
  """
  @spec get_first( source, method_s, fun, id) :: {:ok, {Conn.id, Conn.t}} | {:error, :notfound}
  def get_first( source, method_s, filter \\ fn _ -> true end, pool_id \\ nil) do
    Server.name( pool_id)
    |> GenServer.call( {:get_first, {source, method_s, filter}})
  end


  @doc """
  Makes `Conn.call/3` to connection with given id.

  If happend, timeout encoded in microseconds.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, {id, _conn}} = Pool.get_first( source, [:say, :listen])
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
      iex> {:ok, {id, _conn}} = Pool.get_first( source, [:say, :listen])
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
    with {:ok, {id,_}}=ret <- get_first( source, method, pool_id) do
      cast( id, method, pool_id, specs)
      ret
    end
  end
end
