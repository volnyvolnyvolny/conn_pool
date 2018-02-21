defmodule Conn.Defaults do
  @moduledoc """
  Default implementations of optional callbacks of `Conn` protocol:
<<<<<<< HEAD
  `Conn.undo/3`, `Conn.set_auth/3`. All of them are overridable, and by default
  return `{:error, :notsupported}` or `:notsupported`.
=======
  `Conn.add_tag/2`, `Conn.delete_tag/2`, `Conn.tags/1`, `Conn.undo/3`,
  `Conn.set_auth/3`, `Conn.close/1`, `Conn.child_spec/1` and `Conn.fix/3`.
  All of them are overridable, and by default return `{:error, :notsupported}` or
  `:notsupported`.
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

  Use it like this:

      defimpl Conn, for: MyConn do
        use Conn.Defaults

        # Callbacks:
        def resource(_), do: …
        def state(_, _), do: …
        def call(_, _, _), do: …
        def methods(_), do: …

        # Optional callbacks:
        def init(_, _), do: …
        def set_auth(_, _, _), do: …
        def undo(_, _, _), do: …
        def close(_), do: …
        def child_spec(_), do: …

        def fix(_,_,_), do: …

        def parse(_,_), do: …
      end
  """

  @doc """
  Connection is healthy if there is no method for which `Conn.state/2` function
  returns `:invalid`.
  """
  @spec healthy?(Conn.t) :: boolean
  def healthy?(conn) do
    Enum.all?(Conn.methods(conn),
              &Conn.state(conn, &1) != :invalid)
  end


  @doc """
  Connection is invalid if for every method provided by `Conn.methods/1`,
  `Conn.state/2` function returns `:invalid`.
  """
  @spec invalid?(Conn.t) :: boolean
  def invalid?( conn) do
    Enum.all?(Conn.methods(conn),
              &Conn.state(conn, &1) == :invalid)
  end


  @doc """
  Connection warnings is a list with pairs
  `{method, timeout | :invalid | :closed}`. See `Conn.state/2`
  function.

  ## Examples

      Conn.warnings( conn) = [ask: :invalid, say: 65536]
  """
  @spec warnings( Conn.t) :: [{Conn.method, timeout | :invalid | :closed}]
  def warnings( conn) do
     Conn.methods( conn)
  |> Enum.map( fn method -> {method, Conn.state( conn, method)} end)
  |> Enum.filter( fn {_,state} -> state != :ready end)
  end


  @doc """
  Authenticate connection. Easy to use version of `Conn.set_auth/3`
  function. Returns `{:ok, conn}` or `{:error, conn}`, where `conn`
  is an updated version of connection.
  """
  @spec authenticate( Conn.t, Conn.method, Conn.auth) :: {:ok | :error, Conn.t}
  def authenticate( conn, method, auth) do
    case Conn.set_auth( conn, method, auth) do
      {:ok, conn} -> {:ok, conn}
      {status, _} -> {status, conn}
      {status, _, updated_conn} -> {status, updated_conn}
    end
  end


  @doc """
  Authenticate all methods of connection for which `set_auth` returns . Easy to
  use version of `Conn.set_auth/3` function.

  Returns `{:ok, updated conn}` or `{:error, reason, updated conn}` of
  connection.
  """
  @spec authenticate( Conn.t, Conn.auth) :: {:ok, Conn.t}
                                          | {:error, reason, Conn.t}
  def authenticate( conn, auth) do
    methods = Conn.methods conn
    Enum.reduce methods, {conn, methods}, fn
      _, {conn,[]} -> conn
      method, {conn, methods} when method not in methods ->
        {conn,methods}
      method, {conn, methods} ->
        case Conn.set_auth conn, method do
          {:ok, :already} ->
            {conn, methods--[method]}
          {:ok, :already, conn}
            {conn, methods--[methods]}
          {:ok, conn} ->
            {conn, methods--[methods]}
          {:ok, meths, conn} ->
            {conn, methods--meths}

          {:error, reason} ->
            {}
        end
        {conn,methods}
    end
  end


  @doc """
  Execute `Conn.fix/3` for every method such that `Conn.state/2`
  returns `:invalid`.
  """
  @spec fix( Conn.t, keyword) :: {:ok, Conn.t}
                               | {:error, Conn.error, Conn.t}
                               | {:error, Conn.error}
  def fix( conn, init_args) do
    Conn.methods( conn)
    |> Enum.reduce( conn, fn
         method, {:ok, conn} ->
           if Conn.state( conn, method) == :invalid do
             Conn.fix( conn, method, init_args)
           else
             {:ok, conn}
           end

         _, error -> error
       end)
  end

  defmacro __using__(_) do
    quote do

      def child_spec(_conn), do: []
#      def fix( conn,_method, init_args), do: Conn.init( conn, init_args)
      def init( conn,_args), do: {:ok, conn}
<<<<<<< HEAD
#      def close(_conn), do: {:error, :notsupported}
=======

      def close(_conn), do: {:error, :notsupported}

      def parse(_conn,_data), do: {:error, :notsupported}

>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0
      def undo(_conn,_method,_specs), do: {:error, :notsupported}
      def set_auth(_conn, _method, _auth), do: {:error, :notsupported}

<<<<<<< HEAD
      defoverridable [child_spec: 1, init: 2, fix: 3, # close: 1,
=======
      def set_auth(_conn, _method \\ :__all__, _auth), do: {:error, :notsupported}

      defoverridable [child_spec: 1, init: 2, fix: 3, close: 1,
                      add_tag: 2, delete_tag: 2, tags: 2,
                      parse: 2,
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0
                      undo: 3,
                      set_auth: 3]
    end
  end
end


defprotocol Conn do
  @moduledoc """
  `Conns.Pool` managable connections. It's a high level
  abstraction. Implementations can use any transport to connect to
  any remote or VM-local resources, such as `Agent`s, `GenServer`s,
  different APIs and, of course, any http-resources.

  # Callbacks

    * `resource/1` — resource for corresponding connection. *You can
    also return list of resources*;
    * `methods/1` — methods supported in connection calls;
    * `state/2` — state of connection in respect of method
      (`:ready` for interaction; `:invalid` — need to `Conn.fix/3` it
      before use; has local timeout; was `:closed`);
    * `call/3` — interact via selected method.

  ## Optional callbacks

    * `init/2` — initialize connection with given arguments;
    * `fix/3` — try to fix connection that returns `state/2` == `:invalid`
       for some method;

    * `child_spec/1` — child spec by analogy with `Supervisor`s childs;
    * `parse/2` — parse data in respect of connection context;

    * `set_auth/3` — authenticate connection;

    * `close/1` — close connection;

    * `undo/3` — support Sagas-transactions.
  """

  @type  t :: %_{}
  @type  id :: non_neg_integer
  @type  method :: not_list

  @type  not_list :: term

  @type  auth :: any
  @type  resource :: atom | String.t
  @type  error :: any
  @type  reply :: any

  @type  reason :: any

  @type  state :: :ready | :invalid | :closed
  @type  action :: :fix | :panic | :poolrestart | (Conn.t -> :ok) | :close | :reinit
  @type  spec :: [{method | :_, {:onbecame, state, action}
                              | {:onerror, action}}]


<<<<<<< HEAD
  # ## Timeouts
=======
  defdelegate fix( conn, init_args), to: Conn.Defaults
  defdelegate warnings( conn), to: Conn.Defaults
  defdelegate invalid?( conn), to: Conn.Defaults
  defdelegate healthy?( conn), to: Conn.Defaults
  defdelegate authenticate( conn, method \\ :__all__, auth), to: Conn.Defaults


  @doc """
  Child spec (by analogy with `Supervisor` childs).

  Module `Conn.Defaults` has default implementation of `child_spec/1`.
  It returns: :normal_strategy.
  """
  @spec child_spec( Conn.t) :: spec
  def child_spec( conn)


  @doc """
  Init connection. Options could be provided. For example,
  as init argument `Conns.Pool` provides at least `[source: source]`.

  Using this function you can make clean copy of connection:

      clean_conn = xConn.init( conn)

  Module `Conn.Defaults` has default implementation of `init/2` that
  just returns given conn ignoring args. *Probably you would want
  to override it.*
  """
  @spec init( Conn.t, keyword) :: {:ok, Conn.t} | {:error, error}
  def init(_conn, args \\ [])
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

  # System has two timeouts: (1) refresh rate that prevents from using
  # connection too frequently; (2) pool timeout that can be setted by user,
  #   for example, in case of error happend. Pool will never give you access
  # to invalid connection (see `invalid?/1`), connection with nonzero
  # timeout and connection in state `:closed`. To bypass (access to invalid
  #   or timeout conn) use `Conns.Pool.lookup/4` and `Conns.Pool.grab/2`.


  @doc """
<<<<<<< HEAD
  Init connection. Options could be provided. For example, as init argument
  `Conns.Pool` provides at least `[resource: resource]`.
=======
  Try to repair given method of conn interaction.
  Options used in `init/2` should be provided as
  the last argument.
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

  Module `Conn.Defaults` has default implementation of `init/2` that just
  returns given conn ignoring args. *Probably you would want to override it.*
  """
  @spec init(Conn.t, any) :: {:ok, Conn.t}
                           | {:ok, timeout, Conn.t}
                           | {:error, error}
  def init(_conn, args \\ nil)


  # @doc """
  # Try to repair given method of conn interaction. As a the argument provide
  # options used in `init/2`.

  # Use `Conn.Defaults` to define `fix/2` that just calls `init/2` with provided
  # arguments.
  # """
  # @spec fix(Conn.t, method, keyword) :: {:ok, Conn.t}
  #                                     | {:error, reason, Conn.t}
  #                                     | {:error, reason}
  # def fix(conn, method, init_args)


  @doc """
  Interact using given connection and method.

  For example, you can use this function with `Plug.Conn` to make http-requests:

      Conn.call conn, :get, "http://example.com"

  ## Examples

      resource = %JSON_API{url: "http://example.com/api/v1"}

      # choose and take conn from pool that is capable of handle
      # interaction with both :say and :listen methods
<<<<<<< HEAD
      {:ok, conn} = Pool.take_first resource, [:say, :listen]
      {:ok, conn} = Conn.call conn, :say, what: "Hi!", name: "Louie"
      {:ok, "Hi Louie!"} = Conn.call conn, :listen
      {:ok, _id} = Pool.put conn #returns connection back to pool

      Or:

      {:ok, conn} = Pool.take_first resource, [:say, :listen]
      {:ok, {conn, dialog_id}} = Conn.call conn, :say, what: "Hi!", name: "Louie", new_dialog: true
      {:ok, {conn, "Hi Louie!"}} = Conn.call conn, :listen, dialog_id: dialog_id
      {:ok, conn} = Conn.call conn, :say, what: "How are U?", dialog_id: dialog_id
      Pool.put conn, id: 1
      {:ok, ^conn} = Pool.take 1
      {:ok, "Fine, tnx!"} = Conn.call conn, :listen, dialog_id: dialog_id
=======
      {:ok, conn} = Pool.take_one( resource, [:say, :listen])
      {:ok, conn} = Conn.call( conn, :say, what: "Hi!", name: "Louie")
      {:ok, "Hi Louie!"} = Conn.call( conn, :listen)
      {:ok, _id} = Pool.put( conn) #returns connection back to pool

      Or:

      {:ok, conn} = Pool.take_one( resource, [:say, :listen])
      {:ok, {conn, dialog_id}} = Conn.call( conn, :say, what: "Hi!", name: "Louie", new_dialog: true)
      {:ok, {conn, "Hi Louie!"}} = Conn.call( conn, :listen, dialog_id: dialog_id)
      {:ok, conn} = Conn.call( conn, :say, what: "How are U?", dialog_id: dialog_id)
      Pool.put( conn, id: 1)
      {:ok, ^conn} = Pool.take( 1)
      {:ok, "Fine, tnx!"} = Conn.call( conn, :listen, dialog_id: dialog_id)
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0
  """
  @spec call(Conn.t, Conn.method, any)
        :: :ok
        | {:ok, reply}
        | {:ok, reply, Conn.t}

        | {:ok, reply, timeout}
        | {:ok, reply, timeout, Conn.t}

        | {:error, :needauth | reason}
        | {:error, :needauth | reason, Conn.t}

        | {:error, :needauth | reason, timeout}
        | {:error, :needauth | reason, timeout, Conn.t}
  def call(conn, method, payload \\ nil)


  # @doc """
  # Undo changes that were maded by `Conn.call/3`. This used in
  # Sagas-transactions.

  # If you don't use transactions over multiple connections, use default
  # implementation provided by `Conn.Defaults` that returns `{:error,
  # :unsupported}` tuple for every conn, method and payload given as an argument.

<<<<<<< HEAD
  # ## Examples
=======
      {:ok, conn} = Pool.take_one( resource, [:say, :listen])
      {:ok, conn} = Conn.call( conn, :say, what: "Hi!", name: "Louie")
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

  #     resource = %JSON_API{url: "http://example.com/api/v1"}

  #     {:ok, conn} = Pool.take_first( resource, [:say, :listen])
  #     {:ok, conn} = Conn.call( conn, :say, what: "Hi!", name: "Louie")

  #     :ok = Conn.undo( conn, :say, what: "Hi!", name: "Louie")

  #     # or, maybe, simply:
  #     # :ok = Conn.undo( conn, :say) #as payload doesn't matters here
  #     {:ok, _id} = Pool.put( conn) #return connection to pool
  # """
  # @spec undo(Conn.t, method, keyword) :: :ok
  #                                      | {:ok, Conn.t}

  #                                      | {:error, reason, Conn.t}
  #                                      | {:error, :unsupported}
  # def undo(conn, method, payload_used \\ [])


  @doc """
  Resource to which interaction is made.

  ## Examples

<<<<<<< HEAD
      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, c} = Conn.init %Conn.Agent{}, agent: Conn.resource(conn)
=======
      resource = %JSON_API{url: "http://example.com/api/v1"}
      {:ok, conn} = Pool.take_one( resource, :info)
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

      iex> {:ok, agent} = Agent.start_link fn -> 42 end
      iex> ^agent == Conn.resource %Conn.Agent{resource: agent}
      true
  """
  @spec resource(Conn.t) :: resource | [resource]
  def resource(conn)


  @doc """
  Authenticate connection for given method interaction.

  As a side effect calling this may authenticate connection for other methods,
  in this case return `{:ok, methods that became authenticated, updated conn}`.

  Use `authenticate/3` wrapper-function instead.

  ## Returns

  * `{:ok, updated conn}` — authentication succeed, return updated connection;
  * `{:ok, methods that became authenticated, updated conn}` — authentication
  succeed, return updated connection;
  * `{:ok, :already}` — if connection is already authenticated;
  * `{:ok, :already, updated conn}` — if connection is already authenticated
  and it is changed while being tested;

  * `{:error, :notsupported}`, if authentification is not supported for this
  connection and method.
  * `{:error, other error}`, if there was error while making auth;
  * `{:error, error, updated connection}`, if there was error while
  making auth that changes connection.

  Module `Conn.Defaults` has default implementation of `set_auth/3` that
  constantly returns `{:error, :notsupported}`.
  """
  @spec set_auth(Conn.t, method, auth)
        :: {:ok, Conn.t}
         | {:ok, [method], Conn.t}

#         | {:ok, :already}
         | {:ok, :already, Conn.t}

#         | {:error, :notsupported | reason}
         | {:error, :notsupported | reason, Conn.t}


#         | {:ok, :already, timeout}
         | {:ok, :already, timeout, Conn.t}

#         | {:ok, timeout}
         | {:ok, timeout, Conn.t}

#         | {:ok, [method], timeout}
         | {:ok, [method], timeout, Conn.t}

#         | {:error, :notsupported | reason, timeout}
         | {:error, :notsupported | reason, timeout, Conn.t}
  def set_auth(conn, method, auth)


  @doc """
  Methods of interactions available for connection. Can be http-methods: `:get`,
  `:put`, `:post`, etc., or user defined arbitrary terms `:info`, `:say`,
  `:ask`, `{:method, 1}` and so on. They represents types of interactions can be
  done using given connection.

  ## Returns

  * list of methods available for `call/3`;
  * list of methods available for `call/3` and `updated conn`.

  ## Examples

<<<<<<< HEAD
      iex> {:ok, agent} = Agent.start_link fn -> 42 end
      iex> Conn.methods %Conn.Agent{resource: agent}
      [:get, :get_and_update, :update, :stop]
=======
      resource = %JSON_API{url: "http://example.com/api/v1"}
      {:ok, conn} = Pool.take_one( resource, :info)

      # now:
      :info in Conn.methods( conn)
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0
  """
  @spec methods(Conn.t) :: [method] | {[method], Conn.t}
  def methods(conn)


  @doc """
  Parse data in context of given connection. On success returns `{{method,
  payload}, rest of the data}`.

<<<<<<< HEAD
  On parse error returns `{{:parse, data piece with error}, rest of data}` or
  `{{:notsupported, method, data piece with error}, rest of data}` if used
  method is not supported. Finally, it can return arbitrary error with `{:error,
  error}`.
=======
  On parse error returns `{{:parse, data piece with error}, rest of data}`
  or `{{:notsupported, method, data piece with error}, rest of data}` if
  used method is not supported. Finally, it can return arbitrary
  error with `{:error, error}`. Error `{:error, :needmoredata}` mean
  that given amount of data is not enough for parsing.
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

  Use `Conn.Defaults` to define function `parse/2` to make this function always
  return `{:error, :notsupported}`.
  """
<<<<<<< HEAD
  @spec parse(Conn.t, data) :: {:ok, {{method, data
                                             | auth
                                             | {auth, data}}, data}}
                             | {:error, {{:parse, data}, data}}
                             | {:error, {{:notsupported, method, data}, data}}
                             | {:error, :notsupported | reason}
  def parse(_conn, data)


#  defdelegate fix(conn, init_args), to: Conn.Defaults

  defdelegate warnings(conn), to: Conn.Defaults
  defdelegate invalid?(conn), to: Conn.Defaults
  defdelegate healthy?(conn), to: Conn.Defaults

  defdelegate authenticate(conn, method, auth), to: Conn.Defaults
  defdelegate authenticate(conn, auth), to: Conn.Defaults


=======
  @spec parse( Conn.t, data) :: {:ok, {method, data | {:auth, auth}
                                                    | {{:auth, auth}, data}, data}}
                              | {:error, {{:parse, data}, data}}
                              | {:error, {{:notsupported, method, data}, data}}
                              | {:error, :notsupported | error}
                              | {:error, :needmoredata}
  def parse(_conn, data)


>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0
  @doc """
  Connection state for given method of interaction.

  ## Returns

    * `:ready` — ready for given method interaction;
    * `:invalid` — connection is broken for this method of interaction.
    You can try to `fix/3` it manually or set up pool trigger that will
    do that automagically — see `Conns.Pool.put/2` and [Spec section](#module-child-spec);
    * `:closed` — connection is closed, so there can be no after interactions;
    * `:notsupported` — not in the `methods/1` list.
  """
  @spec state(Conn.t, method) :: :invalid | :closed | :ready | :notsupported
  def state(conn, method)

<<<<<<< HEAD
=======
  @doc """
  Add tag to given connection so later it can be filtered
  with `tags/1` and any pool's function that supports specific
  filter argument.
>>>>>>> f9e2e4e61071a785a47907ebb83a028a35d660d0

  # @doc """
  # Close connection. There can be no after interactions as state `:closed` is
  # the final.

  # Connection that is closed should return `:closed` for all the `methods/1`.

  # Normally, connection with `state/2` == `:closed` would be removed from pool,
  # but this can be tweaked, see `Conn.Pool` docs.

  # Use `Conn.Defaults` to define function `close/1` that always returns `{:error,
  # :notsupported}`.

  # ## Examples


  # """
  # @spec close(Conn.t) :: :ok | {:error, :notsupported}
  #                            | {:error, reason}
  #                            | {:error, reason, Conn.t}
  # def close(conn)

end
