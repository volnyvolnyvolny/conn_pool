defmodule Conn.Defaults do
  @moduledoc """
  Default implementations of optional callbacks of `Conn` protocol:
  `Conn.undo/3`, `Conn.set_auth/3`. All of them are overridable, and by default
  return `{:error, :notsupported}`.

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
        def set_auth(_, _), do: …
        def undo(_, _, _), do: …
        def child_spec(_), do: …

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
  Connection warnings is a list with pairs `{method, timeout | :invalid |
  :closed}`. See `Conn.state/2` function.

  ## Examples

      Conn.warnings( conn) = [ask: :invalid, say: 65536]
  """
  @spec warnings( Conn.t) :: [{Conn.method, timeout | :invalid | :closed}]
  def warnings( conn) do
     Conn.methods( conn)
  |> Enum.map( fn method -> {method, Conn.state( conn, method)} end)
  |> Enum.filter( fn {_,state} -> state != :ready end)
  end


  defmacro __using__(_) do
    quote do

#      def child_spec(_conn), do: []
#      def undo(_conn,_method,_specs), do: {:error, :notsupported}
      def init( conn,_args), do: {:ok, conn}
      def parse(_conn,_data), do: {:error, :notsupported}
      def set_auth(_conn, _auth), do: {:error, :notsupported}

      defoverridable [#child_spec: 1,
                      init: 2,
                      parse: 2,
                      undo: 3,
                      set_auth: 3]
    end
  end
end


defprotocol Conn do
  @moduledoc """
  High level abstraction that represents connection in the most common sense.
  Implementation can use any transport to connect to any remote or VM-local
  resources, such as `Agent`s, `GenServer`s, different APIs and, any
  http-resources.

  ## Callbacks

    * `resource/1` — resource for corresponding connection. *You can also return
    list of resources*;
    * `methods/1` — methods supported in connection calls;
    * `state/2` — state of connection in respect of method (`:ready` for
    interaction; `:invalid`; was `:closed`; `:notsupported`);
    * `call/3` — interact via selected method.

  ## Optional callbacks

    * `init/2` — initialize connection with given arguments;
    * `child_spec/1` — child spec by analogy with `Supervisor`s childs;
    * `parse/2` — parse data in respect of connection context;
    * `set_auth/2` — authenticate connection;
    * `undo/3` — support Sagas-transactions.
  """

  @type  t :: term
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

  # @doc """
  # Child spec (by analogy with `Supervisor` childs).

  # Module `Conn.Defaults` has default implementation of `child_spec/1`.
  # It returns: :normal_strategy.
  # """
  # @spec child_spec( Conn.t) :: spec
  # def child_spec( conn)


  @doc """
  Initialize connection, args could be provided.

  Module `Conn.Defaults` has default implementation of `init/2` that just
  returns given conn, ignoring args. *Probably you would like to override it.*

  ## Examples

      iex> {:ok, conn1} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, conn2} = Conn.init %Conn.Agent{},
      ...>                          resource: Conn.resource(conn1)
      iex> conn1 == conn2
      true
  """
  @spec init(Conn.t, any) :: {:ok, Conn.t} | {:error, reason}
  def init(_conn, args \\ nil)


  @doc """
  Interact using given connection, method and data.

  ## Returns

    * `{:ok, timeout, conn}`, where `timeout` is the number of milliseconds
    *suggested* to wait until `call/3` again (or `:infinity` to suggest to never
    *call again).
    * `{:ok, reply, timeout, conn}`, where `reply` is the response data;

    * `{:error, :closed}` if connection is closed;
    * `{:error, :needauth, timeout, conn}` means that given action needs
      authentication;
    * `{:error, reason, timeout, conn}` in case of arbitrary error.

  ## Examples

      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, reply, 0, ^conn} = Conn.call conn, :get, & &1
      iex> reply
      42
      iex> {:ok, 0, conn} == Conn.call conn, :stop
      true
      iex> for method <- Conn.methods conn,
      ...> do: Conn.state conn, method
      [:closed, :closed, :closed, :closed]
      iex> Conn.call conn, :get, & &1
      {:error, :closed}
  """
  @spec call(Conn.t, Conn.method, any) :: {:ok,        0 | timeout, Conn.t}
                                        | {:ok, reply, 0 | timeout, Conn.t}
                                        | {:error, :closed}
                                        | {:error, :needauth | reason, 0 | timeout, Conn.t}
  def call(conn, method, payload \\ nil)


  # @doc """
  # Undo changes that were made by `Conn.call/3`. This used in
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

      iex> {:ok, conn1} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, conn2} = Conn.init %Conn.Agent{}, agent: Conn.resource(conn)
      iex> Conn.resource conn1 == Conn.resource conn2
      true
  """
  @spec resource(Conn.t) :: resource | [resource]
  def resource(conn)


  @doc """
  Authenticate connection.

  It's suggested to use `Conn.set_auth(conn, nil)` as a syntax for dropping
  connection.

  ## Returns

    * `{:ok, conn}` — authentication succeed, return updated connection;
    * `{:ok, :already, conn}` — conn is already authenticated;

    * `{:error, :closed}` — connection was closed;
    * `{:error, :notsupported}`, if authentification is not supported;
    * `{:error, reason, conn}`, if error happend while making auth.

  Module `Conn.Defaults` has default implementation of `set_auth/3` that
  just returns `{:error, :notsupported}`.
  """
  @spec set_auth(Conn.t, auth | nil)
        :: {:ok, Conn.t}
         | {:ok, :already, Conn.t}

         | {:error, :closed | :notsupported}
         | {:error, reason, Conn.t}
  def set_auth(conn, auth)


  @doc """
  Methods of interactions available for connection. Can be http-methods: `:get`,
  `:put`, `:post`, etc., or user defined arbitrary terms `:info`, `:say`,
  `:ask`, `{:method, 1}` and so on. They represents types of interactions can be
  done using given connection.

  ## Returns

    * list of methods available for `call/3`;
    * list of methods available for `call/3` and `updated conn`.

  ## Examples

      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> Conn.methods conn
      [:get, :get_and_update, :update, :stop]
  """
  @spec methods(Conn.t) :: [method] | {[method], Conn.t}
  def methods(conn)


  @type data :: any
  @type rest :: data

  @doc """
  Parse data in context of given connection.

  ## Returns

    * On success, `{:ok, {:call, method, payload}, rest of the data}`;
    * or `{:ok, {:set_auth, auth}, rest}` is returned.

    * On error — `{:error, :notsupported}` if parse is not supported;
    * `{:error, :notsupported, {{:call, method, data}, rest}}` if method is not
      supported;

    * `{:error, :needmoredata}` if parsing needs more data;
    * `{:error, {:parse, data that is malformed}}`;
    * `{:error, reason}` for any other error while parsing.

  Use `Conn.Defaults` to define function `parse/2` that is always returns
  `{:error, :notsupported}`.
  """
  @spec parse(Conn.t, data)
        :: {:ok, {:call, method, data}, rest}
         | {:ok, {:set_auth, auth}, rest}
#         | {:ok, {:undo, method, data}, rest}

         | {:error, :notsupported, {{:call, method, data}, rest}}
         | {:error, :notsupported}

         | {:error, {:parse, data}}
         | {:error, :needmoredata}

         | {:error, reason}
  def parse(conn, data)

  defdelegate warnings(conn), to: Conn.Defaults
  defdelegate invalid?(conn), to: Conn.Defaults
  defdelegate healthy?(conn), to: Conn.Defaults


  @doc """
  Connection state for given method of interaction.

  ## Returns

    * `:ready` — ready for given method interaction;
    * `:invalid` — connection is broken for this method of interaction;
    * `:closed` — connection is closed, so there can be no interactions;
    * `:notsupported` — not in the `methods/1` list.

  ## Example

      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> Conn.state conn, :get
      :ready
      iex> Conn.call conn, :stop
      iex> Conn.state conn, :get
      :closed
      iex> for method <- Conn.methods conn,
      ...> do: Conn.state conn, method
      [:closed, :closed, :closed, :closed]
      iex> Conn.state conn, :unknown
      :notsupported
  """
  @spec state(Conn.t, method) :: :ready | :invalid | :closed | :notsupported
  def state(conn, method)

end
