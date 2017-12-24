defmodule Conns.Pool do
  @moduledoc """
  Connection pool is a tool for managing `Conn`s. It supports
  searching connections and taking/returning or directly using
  them from pool. Conn can be returned with timeout to prevent
  using it specific period of time.

  Start connections pool via `start_link/1` function.
  It starts as a local named service `:"Conns.Pool"`,
  but this can be changed, just configure `POOL_NAME`
  application attribute.

  More than one pool can be started by giving `:pool` param
  to the `start_link/1` function.

  Preferred and safe way of interacting with pool is:

  **2. initialize pool connections**

  For this `put/2` function is used:

      Conn.init( MyConn, sources: [%JSON_API{url: "http://example.com/api/v1"}])
      |> Conns.Pool.put()

      # or

      Conns.init( source)
      |> Enum.each(&Conns.Pool.put/2)

  the latter requires `Conns` protocol to be implemented for given
  source.

  Providing `start_link/1` with param `:sources`
  will make it to initialize pool using `Enum.flat_map( opts[:sources], &Conns.init/1)`.

  **2a. choose and take connection**


  This step can be combined with:

      {:ok, conn} = Conns.Pool.take_first( source, [:say, :listen], fn conn ->
                      :reserved in Conn.tags( conn)
                    end)

  using combined functions is *a preferred way*.
  **1b. choose and use connection**


  ## Unsafe

  Connection can be choosed using `lookup/4` function.

      source = %JSON_API{url: "http://example.com/api/v1"}

      Conns.Pool.lookup( source, [:say, :listen], fn conn ->
        Enum.all? [:tag1, :tag2], & &1 in Conn.tags( conn)
      end)

  this selects given source connections that are capable to interact
  via both `:say` and `:listen` methods and satisfy given condition
  (has both `:tag1` and `:tag2` tags).

  As the first argument of `lookup/4` you can provide `:_` atom. That
  literally means "connections to any source". So, the full list of
  connections can be retrived as easy as:

      Conns.Pool.lookup(:_, [])

  It's *highly advised* to use `take_first/4`, `call_first/4` or
  `cast_first/4` function instead of `lookup/4` and `take/3` as it
  respects timeouts and `:invalid` `Conn.state/2`s.

  Connection with known id can be `take/2`n from pool:

      {:ok, conn} = Conns.Pool.take( conn_id)

  In case of success connection is taken from pool and thats clearly
  prevents others from using it.

  If connection with given id has timeout or if it's
  `Conn.invalid?/1`, then `take/2` function returns error.

  Moreover, there is a `grab/2` function that takes connection
  from pool even if it's `Conn.invalid?/1` or there is a timeout
  on it. Use it carefully as it brokes designed usage flow.

  ## 3. use connection

  Connection can be easilly `Conn.call/3`'ed:

      {:ok, conn} = Conn.call( conn, :say, what: "hi!")

  Moreover, there are special functions `call_first/4` and
  `cast_first/4`, combining 1,2 step. Call or cast made directly
  from pool server in different process, prevents it from blocking.
  Cast is a call & forget and returns `:ok` immediately.

  ## 3. return connection back to pool

  Connection can be returned using `put/2`. In case of error,
  to prevent using connection by others, timeout can be setted.
  This way it could be only `grab/2`ed.

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

  Be aware, that every function in `Pool` supports `pool: id` param.
  This way different pools can be used:

      Conns.Pool.put( conn, pool: 0) #add conn to pool #1
      Conns.Pool.put( conn, pool: 1) #add conn to pool #2

  ## Transactions
  ## Child spec

  By analogy with `Supervisor` module `Conns.Pool` treats connections as a
  childs. By default `Conns.Pool` will:

  1. delete conn if it's came to final, `:closed` state;
  2. try to `Conn.fix/2` connection if it's became `Conn.invalid?/1`;
  3. try to `Conn.fix/3` connection if it's `Conn.state/2` == `:invalid` for
  some of the `Conn.methods/1`;
  4. recreate connection with given args if it failed to make steps 2 or 3.

  This behaviour is easy to tune. All you need is to provide specs with
  different triggers and actions. `Conns.Pool` has a builtin trigger&actions
  system. For example, default behaviour is encoded as:

      [__any__: [became(:invalid, do: :fix),
                 unable(:fix, do: :recreate),
                 became(:closed, do: :delete)],
       __all__:  became(:invalid, do: :fix)]

  The tuple element of the keyword has key `:__any__` (or `:_`) that means
  "any of the connection `Conn.methods/1`". As a value, list of triggers&actions
  were given. In this context, `became(:invalid, do: :fix)` means "if
  `Conn.state/2` became equal to `:invalid`, do
  `Conn.fix/3` — `Conn.fix( conn, method, init_args)`".

  Sometimes `Conn.fix/2` returns `{:error, _}` tuple, means we failed to fix
  connection. That's where `unable` macros became handy. In `:_` context,
  `unable(:fix, do: :recreate)` means "if `Conn.fix/3` failed, change
  connection with a fresh copy".

  In the `:__all__` context, `became(:invalid, do: fix)` means "if connection
  is `Conn.invalid?/1`, do `Conn.fix/2`".

  Contexts:

  * `:_` | `__any__` — trigger activated for any of the `Conn.methods/1`;
  * `__all__` — corresponds to situation when all the defined triggers are
  fired, for example `__all__: [became(:timeout, do: [{:log, "Timeout!"}, :panic]), became(:invalid, do: :fix)]` means that if *all* the `Conn.methods/1`
  of connection have timeout, pool will log the "Timeout!" message and
  after that execute `:panic` action. Second trigger would be used if
  conn became `Conn.invalid?/1`. This case `Conn.fix/2` would be called.

  Available actions:

  * `{:log, message}` — add log message;
  * `:delete` — delete connection from pool;
  * `:fix` — in `__all__` context call `Conn.fix/2` function, in all the
  other ones call `Conn.fix/3`;
  * `:recreate` — change connection with the a fresh version returned by
  `Conn.init/2`.
  * `({pool_id, conn_id, conn} -> [action])` — of course, in the `do block`
  arbitrary function can be given;
  * `[action]` — list of actions to make, for ex.: [:fix, :1]

  Triggers:

  * `became( new_state, do: action|actions)` — if given
  * `became( new_state, mark: atom, do block)` — if given
  * `tagged( new_tag, do block)`;
  * `untagged( deleted_tag, do block)`;
  * `unable( mark, do block)`.

  Sagas-transactions would be added in next version of library.

  ## Unsafe operations

  Concurrent use of copies of the same connection is unsafe.
  But if you are confident, you can always bypass:

      conn_id = 1
      {:ok, conn, _} = Conns.Pool.take( conn_id)
      Conns.Pool.put( conn, id: conn_id)
      # use conn while it's still available
      # for others by the same id
  """

  @type  id :: nil | atom | String.t | non_neg_integer
  @type  method_s :: Conn.method | [Conn.method] | :_

  alias Conns.Pool.Server


  @doc """
  Start connections pool. If variable `POOL_NAME` configured,
  pool process starts with the given name. Otherwise, default
  (local) name used — `:"Conns.Pool"`. If pool id provided,
  pool name would be `POOL_NAME.\#{:id}` or `:Conns.Pool.\#{:id}`.
  """
  @spec start_link( [sources: [Conn.source], pool: id]) :: GenServer.on_start
  def start_link( init_args \\ [sources: [], pool: nil]) do
    __MODULE__.Server.start_link( init_args)
  end


  @doc """
  Take connection from pool. You can always give it back with
  `put/2`.

  ## Warnings

  Some of the conn methods can became `:invalid`. `Conn.state/2`
  == `:invalid` means that you are not capable to use selected
  method via `Conn.call/3`. You can try to `Conn.fix/3` broken
  method or pool [can do this for you](#module-child-spec).

  You can still take connection if there are at least one method
  that is `:ready`. Pool will return you that connection and
  a list of all methods for which it is `:invalid` or `:timeout`ed.
  See corresponding typespec.

  ## Errors

  Function will return:

  * `{:error, :invalid}` for connections that are `Conn.invalid?/1`;
  * `{:error, :closed}` for `Conn.close/1`d conns;
  * `{:error, :notfound}` if pool does not manage conn with such id.
  * `{:error, {:timeout, μs}}` — timeout in *micro*seconds (=10^-6 s)
  means that you should wait `μs` μs before connection can be taken.
  """
  @spec take( Conn.id, [pool: id]) :: {:ok, Conn.t, []}
                                    | {:ok, Conn.t, [{Conn.method, timeout | :invalid}]}
                                    | {:error, :notfound
                                             | :invalid
                                             | :closed
                                             | {:timeout, timeout}}
  def take( id, opts \\ [pool: nil]) do
    opts = opts.put_new( opts, :pool, nil)

    Server.name( opts[:pool])
    |> GenServer.call( {:take, id})
  end


  @doc """
  Grad connection from pool. If connection with such id
  managed by pool — it will be returned with timeout value
  in *micro*seconds (normally zero).

  Use `Conn.state/2` to knew the actual state of returned
  connection.
  """
  @spec grab( Conn.id, [pool: id]) :: {:ok, Conn.t, {:timeout, timeout}}
                                    | {:error, :notfound}
  def grab( id, opts \\ [pool: nil]) do
    opts = opts.put_new( opts, :pool, nil)

    Server.name( opts[:pool])
    |> GenServer.call( {:grab, id})
  end


  @doc """
  Take connection to use it with specified method(s) of
  interaction. You can always give connection back with
  `put/2`.

  ## Errors

  Function will return:

  * `{:error, :invalid}` for connections that are `Conn.invalid?/1`;
  * `{:error, :closed}` for `Conn.close/1`d conns;
  * `{:error, :notfound}` if pool does not manage conn with such id;
  * `{:error, {:timeout, μs}}` — timeout in *micro*seconds (=10^-6 s)
  means that you should wait `μs` μs before connection can be *used
  for all the given methods of interactions*.
  """
  @spec take_for( Conn.id, method_s, id) :: {:ok, Conn.t}
                                          | {:error, :notfound
                                                   | :invalid
                                                   | :closed
                                                   | {:timeout, timeout}}
  def take_for( id, method_s, opts \\ [pool: nil]) do
    opts = opts.put_new( opts, :pool, nil)

    Server.name( opts[:pool])
    |> GenServer.call( {:take, id, method_s})
  end


  @doc """
  Put connection to pool.

  Pool respects order in which connections has been putted
  (timestamps are used as ids). So on any `*_first` call
  conns that injected earlier will be returned.

  ## Params

  * `:spec` param can be given, see [corresponding section](#module-child-spec);
  * `:id` can be selected manually;
  * `:pool` id can be used;
  * `:timeout` can be given to restrict others to use this
  connection in any way during timeout period. Timeout is
  encoded in *micro*seconds (=10^-6 sec).
  """
  @spec put( Conn.t, [spec: Conn.spec, pool: id, id: Conn.id]) :: Conn.id
  def put( conn, opts \\ [spec: [], pool: nil, timeout: 0]) do
    opts = opts.put_new( opts, :pool, nil)

    Server.name( opts[:pool])
    |> GenServer.call( {:put, conn, Keyword.delete( opts, :pool)})
  end


  @doc """
  Delete connection with given id from pool.
  """
  @spec drop( Conn.id, [pool: id]) :: :ok
  def drop( id, opts \\ [pool: nil]) do
    _ = take( id, opts)

   :ok
  end


  @doc """
  Lookup for connections that has given source and method(s) in their
  `Conn.sources/1` and `Conn.methods/1` lists. Returns list of all
  connections found. You can provide a `filter` indicator function.

  Function returns list of connections ids with state marks: not spended
  timeout in *micro*secs (normally, zero) or `:invalid` if so for any of
  the given methods. Timeout means that you need to wait given amount
  of time before conn can be used for *any* of the asked methods. `:invalid`
  — that you need to `Conn.fix/3` it before use.

  This function will never return `:closed` connections.

  Note that as a source argument, `:_` (any) can be given and that
  `Conn.sources/1` can be used in filter function (see examples).

  ## Examples

      lookup(:_, []) #returns all connections
      lookup(:_, [:method1, :method2], & :source1 in Conn.sources(&1)
                                      && :source2 in Conn.sources(&1))
      #returns connections to both sources
  """
  @spec lookup( Conn.source | :_, method_s, (Conn.t -> boolean), [pool: id]) :: [{Conn.id, timeout
                                                                                         | :invalid}]

  def lookup( source, method_s, filter \\ (fn _ -> true end), [pool: id] \\ [pool: nil]) do

    {filter, id} = if is_list( filter) do #params mess
                     {& &1, filter[:pool]}
                   else
                     {filter, id}
                   end

    filter = & source in [:_ | Conn.sources(&1)]
               && ([] == List.wrap( method_s) -- Conn.methods(&1)) #methods in Conn.methods/1
               && filter.(&1)

    Server.name( id)
    |> GenServer.call( {:lookup, filter})
  end


  @doc """
  Lookup for connections with `Conn.sources/1` == `[source]`, that are
  capable to handle all given method(s) of interaction(s). Take the
  first connection.

  Be aware that:

  1. pool uses timestamps as ids;
  2. `lookup/3` and all functions suffixed with `_first` will return
  connections in the order they were `put/2`ed.

  ## Examples

      take_first(:_, :alert, & :s1 in Conn.sources(&1) && :s2 in Conn.sources(&1))
  """
  @spec take_first( Conn.source | :_, method_s, (Conn.t -> boolean), [pool: id]) :: {:ok, Conn.t}
                                                                                  | {:error, :notfound
                                                                                  | {:timeout, timeout}}
  def take_first( source, method_s, filter \\ fn _ -> true end, [pool: id] \\ [pool: nil]) do
    {filter, id} = if is_list( filter) do #params mess
                     {& &1, filter[:pool]}
                   else
                     {filter, id}
                   end

    filter = & source in [:_ | Conn.sources(&1)]
               && ([] == List.wrap( method_s) -- Conn.methods(&1)) #methods in Conn.methods/1
               && filter.(&1)

    Server.name( id)
    |> GenServer.call( {:take_first, filter})
  end


  # @doc """
  # Makes `Conn.call/3` to connection with given id.

  # If happend, timeout encoded in microseconds.

  # ## Examples

  #     iex> source = %JSON_API{url: "http://example.com/api/v1"}
  #     iex> {:ok, {id, _conn}} = Pool.fetch_first( source, [:say, :listen])
  #     iex> :ok = Pool.call( id, :say, what: "Hi!")
  # """
  # @spec call( Conn.id, Conn.method, id, keyword) :: :ok
  #                                                  | {:ok, any}
  #                                                  | {:error, any | {:timeout, timeout}}
  # def call( id, method, pool_id, specs \\ []) do
  #   Server.name( pool_id)
  #   |> GenServer.call( {:call, {id, method, specs}})
  # end


  # @doc """
  # Makes `Conn.call/3` to the first connection for specific source
  # type of interactions.

  # ## Examples

  #     iex> source = %JSON_API{url: "http://example.com/api/v1"}
  #     iex> :ok = Pool.call_first( source, :say, what: "Hi!")
  # """
  # @spec call_first( source | :_, Conn.method, id, keyword) :: :ok
  #                                                            | {:ok, any}
  #                                                            | {:error, any | {:timeout, timeout}}
  # def call_first( source, method, pool_id, specs \\ []) do
  #   Server.name( pool_id)
  #   |> GenServer.call( {:call_first, {source, method, specs}})
  # end



  # @doc """
  # Asynchronious `Conn.call/3` to connection with given id. Always
  # returns :ok.

  # ## Examples

  #     iex> source = %JSON_API{url: "http://example.com/api/v1"}
  #     iex> {:ok, {id, _conn}} = Pool.fetch_first( source, [:say, :listen])
  #     iex> ^id = Pool.cast( id, :say, what: "Hi!")
  # """
  # @spec cast( Conn.id, Conn.method, id, keyword) :: Conn.id
  # def cast( id, method, pool_id, specs \\ []) do
  #   Server.name( pool_id)
  #   |> GenServer.cast( {:cast, {id, method, specs}})

  #   id
  # end


  # @doc """
  # Asynchronious `Conn.call/3` to the first given source connection for
  # specific type of interactions. Always returns :ok.

  # ## Examples

  #     iex> source = %JSON_API{url: "http://example.com/api/v1"}
  #     iex> :ok = Pool.cast_first( source, :say, what: "Hi!")
  # """
  # @spec cast_first( source | :_, Conn.method, id, keyword) :: {:ok, {Conn.id, Conn.t}}
  #                                                             | {:error, :notfound}
  # def cast_first( source, method, pool_id, specs \\ []) do
  #   with {:ok, {id,_}}=ret <- fetch_first( source, method, pool_id) do
  #     cast( id, method, pool_id, specs)
  #     ret
  #   end
  # end
end
