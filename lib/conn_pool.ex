defmodule Conns.Pool do
  @moduledoc """
  `Conn`s manager. To start one or more pools use `start_link/1`.
  Now:

  **Step 1. Provide pool with connections**

  Use `Conn.init/2` and `put/2`:

      Conn.init( MyConn, resource: %JSON_API{url: "http://example.com/api/v1"})
      |> Conns.Pool.put()

      # or

      Conns.init( resource)
      |> Enum.each(&Conns.Pool.put/2)

  the latter requires `Conns` protocol to be implemented for the given
  resource.

  If you provide `start_link/1` with param `:resource` — it will initialize
  pool with `Enum.flat_map( opts[:resource], &Conns.init/1)` conns.

  **Step 2a. Choose and use connection**

  Use `Conns.Pool.choose_and_call/4` or `Conns.Pool.choose_and_cast/4` to select
  connection that is capable to interact via given method and make `Conn.call/3`
  from process spawned by pool.

      {:ok, conn} = Conns.Pool.choose_and_call( resource, :say, fn conn ->
                      # use filter to select preferred conn
                      :reserved in Conn.tags( conn)
                    end,
                    name: "Louie", what: "Hi!")

  Cast is a call & forget and returns `:ok` immediatly on choose success.

  **Step 2,3,4b. Choose → take → use and return connection**

  Use `Conns.Pool.choose_and_take/4` to take connection that is capable
  to interact via given methods:

      {:ok, conn} = Conns.Pool.choose_and_take( resource, [:say, :listen], fn conn ->
                      # use filter to select preferred conn
                      :reserved in Conn.tags( conn)
                    end)

  Use `Conn.call/3` on choosed connection:

      :ok = Conn.call conn, :say, what: "Hi!", name: "Louie"

  Connection can be returned using `put/2`. In case of error, timeout
  can be provided to prevent using connection by others (conn still
  could be `grab/2`ed).

  ## Unsafe

  Connections could be selected via `lookup/4` function.

      resource = %JSON_API{url: "http://example.com/api/v1"}

      Conns.Pool.lookup( resource, [:say, :listen], fn conn ->
        Enum.all? [:tag1, :tag2], & &1 in Conn.tags( conn)
      end)

  this selects connections to resource that are capable to interact
  via both `:say` and `:listen` methods and satisfy given condition
  (has both tags `:tag1` and `:tag2`).

  First argument of `lookup/4` could be `:_`. That literally
  means "any resource". So, the full list of connections (except closed)
  can be retrived as easy as:

      Conns.Pool.lookup(:_, [])

  It's *highly advised* to use `choose_and_take/4`, `choose_and_call/4` or
  `choose_and_cast/4` functions instead, as they respects timeouts and
  `:invalid` `Conn.state/2`s.

  Connection with known id can be `take/2`n from pool. Thats
  clearly prevents others from using it:

      {:ok, conn} = Conns.Pool.take( conn_id)

  If connection with id has timeout, closed or if it's `Conn.invalid?/1`
  — error returns. You can bypass this behaviour by using `grab/2`
  function. But use it carefully as it brokes designed usage flow.



  Be aware, that every function in `Pool` supports `pool: id` param.
  This way different pools can be used:

      import Conns.Pool, only: [name: 2]

      Conns.Pool.put( conn, pool: name( 1)) #add conn to pool #1
      Conns.Pool.put( conn, pool: name( 2)) #add conn to pool #2

  Also, you can use copies of the same connection concurently:

      conn_id = 1
      {:ok, conn, _} = Conns.Pool.take( conn_id)
      Conns.Pool.put( conn, id: conn_id)
      # use conn while it's still available
      # for others by the same id

  This is **not recommended**. Use it only if copies of conns don't
  share state!

  ## Transactions
  Sagas-transactions would be added in the next version of library.

  ## Health care

  By analogy with `Supervisor` module `Conns.Pool` treats connections as a
  childs. By default `Conns.Pool` will:

  1. delete conn if it's came to final, `:closed` state;
  2. try to `Conn.fix/2` connection if it's became `Conn.invalid?/1`;
  3. try to `Conn.fix/3` connection if it's `Conn.state/2` == `:invalid` for
  some of the `Conn.methods/1`;
  4. recreate connection with given args if it failed to make steps 2 or 3.

  To do so pool uses `EventAction` mechanism. It handles events and executes
  corresponding actions. Behaviours could be easilly tuned. All you need is
  to provide specs with different triggers and actions. For example, we can
  write delete if could not default
  behaviour is encoded as:

      [ fn {:state_changed, {id, conn}, method, {from, :invalid}} ->
          Conns.Pool.fix( )
        end,

        fn {:unable, :fix, {id, conn}, method} ->
          Conns.Pool.fix( )
        end,

        fn {:unable, :fix, {id, conn}, method} ->
          Conns.Pool.fix( )
        end,

        fn {:conn_closed, {id, conn}} ->
          Conns.Pool.drop( )
        end,

        fn {:conn_invalidated, {id, conn}} ->
          case Conn.fix( conn) do
            {:ok, conn} -> 
            {:error, error, conn} -> 
            {:error, error} -> 
          end
        end]

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
  """

  @type  id :: nil | atom | String.t | non_neg_integer
  @type  method_s :: Conn.method | [Conn.method] | :_
  @type  name :: term | {:global, term} | {:via, atom, term}

  @type  eventAction_spec :: {term, term}

  @name        System.get_env("POOL_NAME") || :"Conns.Pool"
  @name_schema System.get_env("POOL_NAME_SCHEMA") || &Conns.Pool.name_schema/2

  def name_schema( name, id), do: {name, id}


  @doc """
  Pool name for given id. This function helps when starting
  a lot of similar pools. It generates pool names based on
  id given.

  By default, `name( 123)` will give us `{:Conns.Pool, 123}`.
  This could be changed. Just add:

      config :conn_pool,
        POOL_NAME: :OtherName # → {:OtherName, pool_id}
      # or
        POOL_NAME: {:global, :OtherName} # → {:global, {:OtherName, pool_id}}
      # or
        POOL_NAME: {:via, Module, :OtherName} # → {:via, Module, {:OtherName, pool_id}}

      # or even

      defmodule Different do
        def name_schema name, pool_id, do: :"\#{name}\#{pool_id}"
      end

      config :conn_pool,
        POOL_NAME: {:via, Module, :OtherName}
        POOL_NAME_SCHEMA: &Different.name_schema/2
        # → {:via, Module, :"OtherName\#{pool_id}"}

  to your config file. Also, see [article](https://hexdocs.pm/elixir/GenServer.html#module-name-registration).

  Mostly, it used as:

      start_link( name: name( 123)) # by default it starts pool named {:Conns.Pool, 123}
      # or:
      start_link( name: name( :OtherName, 123)) # by default it starts pool named {:OtherName, 123}

      take( conn_id, pool: name( 123)) # take/2 conn with given id from pool {:Conns.Pool, 123}
  """
  def name( name_base \\ @name, pool_id) do
    case name_base do
      {:global, term} -> {:global, @name_schema.( term, pool_id)}
      {:via, module, term} -> {:via, module, @name_schema.( term, pool_id)}
      term -> @name_schema.( term, pool_id)
    end
  end


  @doc """
  Starts pool as a linked named process.

  By default pool is registered locally, under the
  name `:"Conns.Pool"`. This can be changed, add:

      config :conn_pool,
        POOL_NAME: :OtherName
        # or
        POOL_NAME: {:global, :OtherName}
        # or
        POOL_NAME: {:via, Module, :OtherName}

  to your config file or provide `:name` option:

      start_link( name: :OtherName)
      # or
      start_link( name: {:global, :OtherName})
      # or
      start_link( name: {:via, Module, :OtherName})

  If you want to start many similar pools, for example
  in multiuser app, use `name/2`.

  ## Specs
  Pool treats connections as childs, so every conn has
  `Conn.child_spec/1` function that returns what action
  should be taken for every significant event (such as
  conn close or invalidate). That represents health
  care mechanism.

  Pool uses `EventAction`. See [this](#module-health-care)
  """
  @spec start_link( [resources: [Conn.resource],
                     specs: [eventAction_spec],
                     name: name])
        :: GenServer.on_start

  def start_link( init_args \\ [resources: [], specs: [], name: @name]) do
    init_args = init_args |> Keyword.put_new(:name, @name)
                          |> Keyword.put_new(:resources, [])
                          |> Keyword.put_new(:specs, [])

    __MODULE__.Server.start_link( init_args)
  end


  # Setup defaults for :pool and :emit args
  defp with_defaults( opts) do
     Keyword.put_new( opts, :pool, @name)
  |> Keyword.put_new(       :emit, true)
  end

  # EventAction.emit
  defp emit( pool, conn_id, event) do
    spawn( fn -> EventAction.emit([pool, conn_id], event) end)
  end


  @doc """
  Take connection from pool. You can always give it back with
  `put/2`.

  ## Warnings

  Some of the conn methods can became `:invalid`. `Conn.state/2`
  == `:invalid` means that you are not capable to use selected
  method via `Conn.call/3`. Pool will [try to fix it for you](#module-health-care) on `put/2`.

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

  ## Events

  On success event `{:take, {:ok, {id, conn}, warnings}}` is
  `EventAction.emit/2`ed. On fail — `{:take, {:error, explained}}`.
  """
  @spec take( Conn.id, [emit: boolean, pool: name])
        :: {:ok, Conn.t, []}
         | {:ok, Conn.t, [{Conn.method, timeout | :invalid}]}
         | {:error, :notfound
                  | :invalid
                  | :closed
                  | {:timeout, timeout}}

  def take( id, opts \\ [emit: true, pool: @name]) do
    opts = opts |> with_defaults()
    pool = opts[:pool]

    #grab:)
    result = GenServer.call( pool, {:grab, id})
    # interpret grab results:
    result = with {:ok, conn, warnings} <- result,
                  nil <- warnings[:_] do

               {:ok, conn, warnings}
             else
               {:error,_explained}=err -> err

               expl -> # on error — return connection
                 GenServer.call( pool, {:put, if expl == :invalid do 0 else expl end, id})
                 {:error, expl}
             end

    if opts[:emit] do
      emit( pool, id, {:take, result})
    end

    result
  end


  @doc """
  Grab connection from pool. If connection with such id
  managed by pool — it will be returned with timeout value
  in *micro*seconds (normally zero).

  Use `Conn.state/2` to knew the actual state of returned
  connection.

  ## Events

  On success event `{:take, {:ok, {id, conn}, warnings}}` is
  `EventAction.emit/2`ed. On fail — `{:take, {:error, explained}}`.
  """
  @spec grab( Conn.id, [emit: boolean, pool: name])
        :: {:ok, Conn.t, [{Conn.method | :_, timeout | :invalid}]}
         | {:error, :notfound | :closed}

  def grab( id, opts \\ [emit: true, pool: @name]) do
    opts = opts |> with_defaults()
    result = GenServer.call( opts[:pool], {:grab, id})

    if opts[:emit] do
      emit( opts[:pool], id, {:take, result})
    end

    result
  end


  @doc """
  Take connection with aim to use it with specified method(s)
  of interaction. You can always give connection back with
  `put/2`.

  ## Errors

  Function will return:

  * `{:error, :invalid}` for connections that are `Conn.invalid?/1`;
  * `{:error, :closed}` for `Conn.close/1`d conns;
  * `{:error, :notfound}` if pool does not manage conn with such id;
  * `{:error, {:timeout, μs}}` — timeout in *micro*seconds (=10^-6 s)
  means that you should wait `μs` μs before connection can be *used
  for all the given methods of interactions*.

  ## Events

  On success event `{:take, {:ok, {id, conn}, warnings}}` is
  `EventAction.emit/2`ed. On fail — `{:take, {:error, explained}}`.
  """
  @spec take_for( Conn.id, method_s, [emit: boolean, pool: name])
        :: {:ok, Conn.t}
         | {:error, :notfound
                  | :invalid
                  | :closed
                  | {:timeout, timeout}}

  def take_for( id, method_s, opts \\ [emit: true, pool: @name]) do
    opts = opts |> with_defaults()
    result = take( id, opts)
    methods = List.wrap method_s

    # interpret grab results:
    result = with {:ok, conn, warnings} <- result,
                  [] <- (Enum.map( methods, & warnings[&1])
                      |> Enum.reject(& &1)) do

               {:ok, conn}
             else
               {:error,_explained}=err -> err

               expls ->
                 {:error, if :invalid in expls do
                             :invalid
                          else
                            {:timeout, Enum.max( expls)}
                          end}
             end

    if opts[:emit] do
      emit( opts[:pool], id, {:take, result})
    end

    result
  end


  @doc """
  Put connection to pool.

  Pool respects order. Timestamps used as ids. So on any
  `*_one` call conns that injected earlier will be returned.

  On a highly unlikely event, when `:id` param is given and
  there is already connection exists with such id runtime
  error would be raised.

  ## Params

  * `:spec` param can be given, see [corresponding section](#module-child-spec);
  * `:id` can be selected manually;
  * `:pool` id can be used;
  * `:timeout` can be given to restrict others to use this connection
  in any way during timeout period. Timeout is encoded in *micro*seconds
  (=10^-6 sec).
  """
  @spec put( Conn.t, [timeout: timeout,
                      spec: Conn.spec,
                      id: Conn.id,
                      emit: true, pool: id])
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


  # @doc """
  # Delete connection with given id from pool.
  # """
  # @spec drop( Conn.id, [pool: id]) :: :ok
  # def drop( id, opts \\ [pool: nil]) do
  #   _ = take( id, opts)

  #  :ok
  # end


  # @doc """
  # Lookup for connections that has given source and method(s) in their
  # `Conn.sources/1` and `Conn.methods/1` lists. Returns list of all
  # connections found. You can provide a `filter` indicator function.

  # Function returns list of connections ids with state marks: not spended
  # timeout in *micro*secs (normally, zero) or `:invalid` if so for any of
  # the given methods. Timeout means that you need to wait given amount
  # of time before conn can be used for *any* of the asked methods. `:invalid`
  # — that you need to `Conn.fix/3` it before use.

  # This function will never return `:closed` connections.

  # Note that as a source argument, `:_` (any) can be given and that
  # `Conn.sources/1` can be used in filter function (see examples).

  # ## Examples

  #     lookup(:_, []) #returns all connections
  #     lookup(:_, [:method1, :method2], & :source1 in Conn.sources(&1)
  #                                     && :source2 in Conn.sources(&1))
  #     #returns connections to both sources
  # """
  # @spec lookup( Conn.source | :_, method_s, (Conn.t -> boolean), [pool: id]) :: [{Conn.id, timeout
  #                                                                                        | :invalid}]

  # def lookup( source, method_s, filter \\ (fn _ -> true end), [pool: id] \\ [pool: nil]) do

  #   {filter, id} = if is_list( filter) do #params mess
  #                    {& &1, filter[:pool]}
  #                  else
  #                    {filter, id}
  #                  end

  #   filter = & resource in [:_ | Conn.resource(&1)]
  #              && ([] == List.wrap( method_s) -- Conn.methods(&1)) #methods in Conn.methods/1
  #              && filter.(&1)

  #   Server.name( id)
  #   |> GenServer.call( {:lookup, filter})
  # end


  # @doc """
  # Lookup for connections with `Conn.sources/1` == `[source]`, that are
  # capable to handle all given method(s) of interaction(s). Take the
  # first connection.

  # Be aware that:

  # 1. pool uses timestamps as ids;
  # 2. `lookup/3` and all functions suffixed with `_first` will return
  # connections in the order they were `put/2`ed.

  # ## Examples

  #     take_first(:_, :alert, & :s1 in Conn.sources(&1) && :s2 in Conn.sources(&1))
  # """
  # @spec take_first( Conn.source | :_, method_s, (Conn.t -> boolean), [pool: id]) :: {:ok, Conn.t}
  #                                                                                 | {:error, :notfound
  #                                                                                 | {:timeout, timeout}}
  # def take_first( source, method_s, filter \\ fn _ -> true end, [pool: id] \\ [pool: nil]) do
  #   {filter, id} = if is_list( filter) do #params mess
  #                    {& &1, filter[:pool]}
  #                  else
  #                    {filter, id}
  #                  end

  #   filter = & source in [:_ | Conn.sources(&1)]
  #              && ([] == List.wrap( method_s) -- Conn.methods(&1)) #methods in Conn.methods/1
  #              && filter.(&1)

  #   Server.name( id)
  #   |> GenServer.call( {:take_first, filter})
  # end


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

  #     resource = %JSON_API{url: "http://example.com/api/v1"}
  #     :ok = Pool.call_first( resource, :say, what: "Hi!")
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

  #     resource = %JSON_API{url: "http://example.com/api/v1"}
  #     :ok = Pool.cast_first( resource, :say, what: "Hi!")
  # """
  # @spec cast_first( resource | :_, Conn.method, id, keyword) :: {:ok, {Conn.id, Conn.t}}
  #                                                             | {:error, :notfound}
  # def cast_first( resource, method, pool_id, specs \\ []) do
  #   with {:ok, {id,_}}=ret <- fetch_first( source, method, pool_id) do
  #     cast( id, method, pool_id, specs)
  #     ret
  #   end
  # end
end
