defmodule Conn.Defaults do
  @moduledoc """
  Default implementations of optional callbacks of `Conn` protocol:
  `Conn.undo/3`, `Conn.set_auth/3`. All of them are overridable, and by default
  return `{:error, :notsupported}` or `:notsupported`.

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
  @spec authenticate(Conn.t, Conn.auth) :: {:ok, Conn.t}
                                         | {:error, reason, Conn.t}
  def authenticate(conn, auth) do
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


  # @doc """
  # Execute `Conn.fix/3` for every method such that `Conn.state/2`
  # returns `:invalid`.
  # """
  # @spec fix(Conn.t, keyword) :: {:ok, Conn.t}
  #                             | {:error, Conn.error, Conn.t}
  #                             | {:error, Conn.error}
  # def fix(conn, init_args) do
  #   Conn.methods( conn)
  #   |> Enum.reduce( conn, fn
  #        method, {:ok, conn} ->
  #          if Conn.state( conn, method) == :invalid do
  #            Conn.fix( conn, method, init_args)
  #          else
  #            {:ok, conn}
  #          end

  #        _, error -> error
  #      end)
  # end

  @spec call!(Conn.t, Conn.method, any) :: {:ok, reply, timeout, Conn.t}
                                         | {:error, :needauth | reason, timeout, Conn.t}
  def call!(conn, method, payload \\ nil) do
    case call(conn, method, payload) do
       :ok ->
         {:ok, nil, 0, conn}
      {:ok, conn}
      {:error, :notsupported} ->
        raise "Method #{inspect method} is not supported by conn #{inspect conn}."
    end
  end


  defmacro __using__(_) do
    quote do

      def child_spec(_conn), do: []
#      def fix( conn,_method, init_args), do: Conn.init( conn, init_args)
      def init( conn,_args), do: {:ok, conn}

      def close(_conn), do: {:error, :notsupported}

      def parse(_conn,_data), do: {:error, :notsupported}

      def undo(_conn,_method,_specs), do: {:error, :notsupported}
      def set_auth(_conn, _method, _auth), do: {:error, :notsupported}

      defoverridable [child_spec: 1, init: 2, fix: 3,
                      parse: 2,
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

    # * `fix/3` — try to fix connection that returns `state/2` == `:invalid`
       for some method;
    # * `child_spec/1` — child spec by analogy with `Supervisor`s childs;

    * `parse/2` — parse data in respect of connection context;

    * `set_auth/3` — authenticate connection;

    * `undo/3` — support Sagas-transactions.
  """

  @type  t :: %_{}
  @type  id :: non_neg_integer

  @type  method :: any
  @type  auth :: any
  @type  resource :: any
  @type  reply :: any
  @type  reason :: any

  # @type  state :: :ready | :invalid | :closed
  # @type  action :: :fix | :panic | :poolrestart | (Conn.t -> :ok) | :close | :reinit
  # @type  spec :: [{method | :_, {:onbecame, state, action}
  #                             | {:onerror, action}}]

  defdelegate call!(conn, method, payload), to: Conn.Defaults
  defdelegate fix(conn, init_args), to: Conn.Defaults
  defdelegate warnings(conn), to: Conn.Defaults
  defdelegate invalid?(conn), to: Conn.Defaults
  defdelegate healthy?(conn), to: Conn.Defaults
  defdelegate authenticate(conn, method, auth), to: Conn.Defaults


  # @doc """
  # Child spec (by analogy with `Supervisor` childs).

  # Module `Conn.Defaults` has default implementation of `child_spec/1`.
  # It returns: :normal_strategy.
  # """
  # @spec child_spec( Conn.t) :: spec
  # def child_spec( conn)


  @doc """
  Init connection. Options could be provided. For example, as init argument
  `Conns.Pool` provides at least `[resource: resource]`.

  Using this function you can make clean copy of connection:

      clean_conn = Conn.init( conn)

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

  ## Returns

      * `{:ok, timeout, conn}`, where `timeout` is the number of milliseconds
      *suggested* to wait until `call/3` again.
      * `{:ok, reply, timeout, conn}`, where `reply` is the response data;

      * `{:error, :needauth, timeout, conn}` means that given action needs
      authentication;
      * `{:error, reason, timeout, conn}` in case of arbitrary error.

  ## Examples

      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, state, 0, ^conn} = Conn.call conn, :get, & &1
      iex> state
      42
      iex> {:ok, 0, conn} == Conn.call conn, :stop
      true
      iex> {:error, :closed, 0, conn} == Conn.call conn, :get, & &1
      true
  """
  @spec call(Conn.t, Conn.method, any) :: {:ok,        0 | timeout, Conn.t}
                                        | {:ok, reply, 0 | timeout, Conn.t}
                                        | {:error, :needauth | reason, 0 | timeout, Conn.t}
  def call(conn, method, payload \\ nil)


  # @doc """
  # Undo changes that were maded by `Conn.call/3`. This used in
  # Sagas-transactions.

  # If you don't use transactions over multiple connections, use default
  # implementation provided by `Conn.Defaults` that returns `{:error,
  # :unsupported}` tuple for every conn, method and payload given as an argument.

  # ## Examples

  # {:ok, conn} = Pool.take_one( resource, [:say, :listen])
  # {:ok, conn} = Conn.call( conn, :say, what: "Hi!", name: "Louie")

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

      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, c} = Conn.init %Conn.Agent{}, agent: Conn.resource(conn)

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
  @spec set_auth(Conn.t, auth)
        :: {:ok, Conn.t}
         | {:ok, :already}
         | {:ok, :already, Conn.t}

         | {:error, :notsupported | reason}
         | {:error, :notsupported | reason, Conn.t}

         | {:ok, :already, timeout}
         | {:ok, :already, timeout, Conn.t}

         | {:ok, timeout}
         | {:ok, timeout, Conn.t}

         | {:error, :notsupported | reason, timeout}
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

      iex> {:ok, agent} = Agent.start_link fn -> 42 end
      iex> Conn.methods %Conn.Agent{resource: agent}
      [:get, :get_and_update, :update, :stop]
  """
  @spec methods(Conn.t) :: [method] | {[method], Conn.t}
  def methods(conn)


  @doc """
  Parse data in context of given connection. On success returns `{{method,
  payload}, rest of the data}`.

  On parse error returns `{{:parse, data piece with error}, rest of data}` or
  `{{:notsupported, method, data piece with error}, rest of data}` if used
  method is not supported. Finally, it can return arbitrary error with `{:error,
  error}`.

  Use `Conn.Defaults` to define function `parse/2` to make this function always
  return `{:error, :notsupported}`.
  """
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


  @spec parse( Conn.t, data) :: {:ok, {method, data | {:auth, auth}
                                                    | {{:auth, auth}, data}, data}}
                              | {:error, {{:parse, data}, data}}
                              | {:error, {{:notsupported, method, data}, data}}
                              | {:error, :notsupported | error}
                              | {:error, :needmoredata}
  def parse(_conn, data)


  @doc """
  Connection state for given method of interaction.

  ## Returns

    * `:ready` — ready for given method interaction;
    * `:invalid` — connection is broken for this method of interaction;
    * `:closed` — connection is closed, so there can be no interactions;
    * `:notsupported` — not in the `methods/1` list.
  """
  @spec state(Conn.t, method) :: :invalid | :closed | :ready | :notsupported
  def state(conn, method)

end
