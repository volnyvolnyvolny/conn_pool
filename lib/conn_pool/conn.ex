defmodule Conn.Defaults do
  @moduledoc """
  Default implementations of optional callbacks of `Conn` protocol:
  `Conn.add_tag/2`, `Conn.delete_tag/2`, `Conn.tags/1`, `Conn.undo/3`,
  `Conn.set_auth/3`. All of them are overridable, and by default
  return `{:error, :notsupported}` or `:notsupported`.

  Use it like this:

      defimpl Conn, for: MyStruct do
        use Conn.Defaults

        # Callbacks:
        def init(_, _), do: …
        def source(_), do: …
        def state(_, _), do: …
        def call(_, _, _), do: …
        def methods(_), do: …

        # Optional callbacks:
        def set_auth(_, _, _), do: …
        def undo(_, _, _), do: …
        def tags(_), do: …
        def add_tag(_, _), do: …
        def delete_tag(_, _), do: …
      end
  """

  @doc """
  Connection is healthy if there is no method for which state function
  returns `:invalid`?
  """
  @spec healthy?( Conn.t) :: boolean
  def healthy?( conn) do
    Conn.methods( conn)
    |> Enum.all?(& Conn.state( conn, &1) != :invalid)
  end


  @doc """
  Connection is invalid if for every method provided by `Conn.methods/1`
  connection returns `:invalid`?
  """
  @spec invalid?( Conn.t) :: boolean
  def invalid?( conn) do
    Conn.methods( conn)
    |> Enum.all?(& Conn.state( conn, &1) == :invalid)
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


  defmacro __using__(_) do
    quote do

      def add_tag(_conn,_tag), do: :notsupported

      def delete_tag(_conn,_tag), do: :notsupported

      def tags(_conn), do: :notsupported

      def init( conn,_args), do: {:ok, conn}

      def close(_conn), do: {:error, :notsupported}

      def undo(_conn,_method,_specs), do: {:error, :notsupported}

      def set_auth(_conn, _method, _auth), do: {:error, :notsupported}

      defoverridable [add_tag: 2, delete_tag: 2, tags: 2, undo: 3, set_auth: 3]
    end
  end
end


defprotocol Conn do
  @moduledoc """
  Protocol represents abstract connection managed by `Conns.Pool`.

  # Callbacks

    * `call/3` — interact using given connection and specs;
    * `sources/1` — get connection sources. *Commonly, it's a list
    with a lonely single element*, but you can make connections that are
    handling more than one source;
    * `methods/1` — methods supported by connection;
    * `state/2` — state of connection in respect of method
      (`:ready` for interaction, `:invalid` and needs to be fixed,
      have local timeout and was `:closed`);

  ## Optional callbacks

    * `init/2` — initialize connection;
    * `fix/2` — try to fix connection that returns `state/2` == `:invalid`
       for specific method;
    * `tags/1` — tags associated with connection;
    * `add_tag/2` — associate tag with connection;
    * `delete_tag/2` — deassociate tag from connection;
    * `set_auth/3` — authenticate connection;

    * `undo/3` — support for Sagas-transaction mechanism.

  ## Child spec

  By analogy with `Supervisor` module, `Conns.Pool` treats connections as a
  childs. By default, `Conns.Pool` will:

  1. delete conn if it's came to final, `:closed` state;
  2. try to `fix/2` connection if it's became `invalid?/1`;
  3. try to `fix/3` connection if it's `state/2` == `:invalid` for
  some of the `methods/1`;
  4. recreate connection with given args if it failed to make steps 2 or 3.

  This behaviour is easy to tune. All you need is to provide specs with
  different triggers and actions. `Conns.Pool` has a builtin trigger&actions
  system. For example, default behaviour is encoded as:

      [__any__: [became(:invalid, do: :fix),
                 unable(:fix, do: :recreate),
                 became(:closed, do: :delete)],
       __all__:  became(:invalid, do: :fix)]

  The tuple element of the keyword has key `:__any__` (or `:_`) that means
  "any of the connection `methods/1`". As a value, list of triggers&actions
  were given. In this context, `became(:invalid, do: :fix)` means "if `state/2`
  became equal to `:invalid`, do `fix/3` — `Conn.fix( conn, method, init_args)`".

  Sometimes `fix/2` returns `{:error, _}` tuple, means we failed to fix
  connection. That's where `unable` macros became handy. In `:_` context,
  `unable(:fix, do: :recreate)` means "if `fix/3` failed, change connection
  with a fresh copy".

  In the `:__all__` context, `became(:invalid, do: fix)` means "if connection
  is `invalid?/1`, do `fix/2`".

  Contexts:

  * `:_` | `__any__` — trigger activated for any of the `methods/1`;
  * `__all__` — corresponds to situation when all the defined triggers are
  fired, for example `__all__: [became(:timeout, do: [{:log, "Timeout!"}, :panic]), became(:invalid, do: :fix)]` means that if *all* the `methods/1` of connection
  have timeout, pool will log the "Timeout!" message and after that
  execute `:panic` action. Second trigger would be used if conn became
  `invalid?/1`. This case `fix/2` would be called.

  Available actions:

  * `{:log, message}` — add log message;
  * `:delete` — delete connection from pool;
  * `:fix` — in `__all__` context call `fix/2` function, in all the other ones
  call `fix/3`;
  * `:recreate` — change connection with the a fresh version returned by
  `init/2`.
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

  @type  t :: any
  @type  id :: term
  @type  method :: any

  @type  not_list :: term

  @type  auth :: not_list
  @type  tag :: any
  @type  source :: atom | String.t
  @type  error :: any
  @type  data :: any

  @type  state :: :ready | :invalid | :closed | :timeout
  @type  action :: :fix | :panic | :poolrestart | (Conn.t -> :ok) | :close | :reinit
  @type  spec :: [{method | :_, {:onbecame, state, action}
                              | {:onerror, action}}]


  @doc """
  Init connection. Options can be provided.

  As init argument, connection pool provide at
  least `{:source, source}` tuple.
  """
  @spec init( Conn.t, keyword) :: {:ok, Conn.t} | {:error, error}
  def init(_conn, args \\ [])


  @doc """
  Fix connection. Options can be provided.

  As init argument, connection pool provide at
  least `{:source, source}` tuple.
  """
  @spec fix( Conn.t, method) :: {:ok, Conn.t} | {:error, Conn.t}
  def fix( conn, method)


  @doc """
  Send and receive data using given connection and method, where
  *method is arbitrary term except list*.

  For example you can use it to make http-connection with `Plug.Conn`:

      Conn.call( conn, :get, "http://example.com")

  ## Examples
      iex> source = %JSON_API{url: "http://example.com/api/v1"}

      iex> {:ok, conn} = Pool.take_first( source, [:say, :listen]) #takes conn from pool
      iex> {:ok, conn} = Conn.call( conn, :say, what: "Hi!", name: "Louie")
      iex> {:ok, "Hi Louie!"} = Conn.call( conn, :listen)
      iex> {:ok, _id} = Pool.put( conn) #returns connection back to pool

      Or:

      iex> {:ok, {id, conn}} = Pool.get_first( source, [:say, :listen])
      iex> {:ok, {conn, dialog_id}} = Conn.call( conn, :say, what: "Hi!", name: "Louie", opts: [:new_dialog])
      iex> {:ok, {conn, "Hi Louie!"}} = Conn.call( conn, :listen, dialog_id: dialog_id)
      iex> {:ok, conn} = Conn.call( conn, :say, what: "How are U?", dialog_id: dialog_id)
      iex> Pool.update( id, conn)
      iex> {:ok, ^conn} = Pool.fetch( id)
      iex> {:ok, "Fine, tnx!"} = Conn.call( conn, :listen, dialog_id: dialog_id)
  """
  @spec call( Conn.t, method, data) :: :ok | {:ok, data} | {:ok, data, Conn.t}
                                                         | {:ok, :noreply, Conn.t}
                                    | {:error, :needauth | error | {:timeout, timeout}}
                                    | {:error, :needauth | error, Conn.t}
  def call( conn, method, load \\ nil)



  @doc """
  Undo changes maded by `Conn.call/3`. This used in Sagas-transactions.
  If you don't use transactions over multiple connections use default
  implementation provided by `Conn.Defaults` which returns
  `{:error, :unsupported}` tuple for every conn, method and spec given
  as an argument.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}

      iex> {:ok, conn} = Pool.take_first( source, [:say, :listen]) #takes conn from pool
      iex> {:ok, conn} = Conn.call( conn, :say, %{what: "Hi!", name: "Louie"})
      iex> :ok = Conn.undo( conn, :say)
      iex> {:ok, _id} = Pool.put( conn) #return connection back to pool
  """
  @spec undo( Conn.t, method, keyword) :: :ok
                                       | {:ok, Conn.t}
                                       | {:error, any, Conn.t}
                                       | {:error, :unsupported}
                                       | {:error, {:timeout, timeout}}
  def undo( conn, method, specs \\ [])


  @doc """
  Given connection sources.

  Commonly, it’s a list with a lonely single element, `[single source]`,
  but you can make connections that are handling more than one source.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, conn} = Pool.take_first( source, :info)
      iex> Conn.source( conn).url
      "http://example.com/api/v1"
  """
  @spec sources( Conn.t) :: [source]
  def sources( conn)


  @doc """
  Authenticate connection for given method.

  It's easy to use it through `authenticate/3` function.

  ## Returns

    * `{:ok, updated conn}` — authentication succeed, return updated connection;
    * `{:ok, :already}` — connection is already authenticated. It was not
    changed, so no need to return it;
    * `{:ok, :already, updated conn}` — connection is already authenticated,
    and it was changed while tested;
    * `{:error, :notsupported}`, if authentification is not supported for this
    connection and method.
    * `{:error, other error}`, if there was error while authentificating
    and it's not affects connection.
    * `{:error, error, updated connection}`, if there was error while
    authentificating and it affects connection.

  Module `Conns.Defaults` has default implementation of `set_auth/3`, that
  return as a constant `{:error, :notsupported}` tuple for every conn, method
  and auth.
  """
  @spec set_auth( Conn.t, method, auth) :: {:ok, :already | Conn.t}
                                        |  {:ok, :already, Conn.t}
                                        |  {:error, :notsupported | error}
                                        |  {:error, :notsupported | error, Conn.t}
  def set_auth( conn, method, auth)


  @doc """
  Interaction methods provided by connection. Can be http-methods:
  :get, :put, :post, etc., or user defined :info, :say, :ask and
  so on. They represents types of interactions can be done using
  given connection.

  Moreover, every method can have it's own timeout and can separately
  become invalid — see `state/2`.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, {id, conn}} = Pool.get_first( source, :info)
      iex> :info in Conn.methods( conn)
      true
  """
  @spec methods( Conn.t) :: [method]
  def methods( conn)


  defdelegate invalid?( conn), to: Conn.Defaults
  defdelegate healthy?( conn), to: Conn.Defaults
  defdelegate authenticate( conn, method, auth), to: Conn.Defaults


  @doc """
  Connection state for given method of interaction.

  If method argument is not in the `methods/1` list then it's common to
  raise an runtime error.

  ## Return atoms:

    * `:ready` | `{:timeout, 0}` — ready for given method interaction;
    * `:invalid` — connection is broken for this method of interaction.
    You can try to `fix/2` it manually or set up pool trigger that will
    do that automagically — see `Conns.Pool.put/2` and [Spec section](#module-child-spec);
    * `:closed` — connection that was closed would be removed from pool
    as it's a final state;
    * `{:timeout, not spended}`  — timeout happend, return how long is
    it left to wait in microseconds.

  ## Timeouts

     System has two timeouts: (1) refresh rate, which prevents from using
     connection too frequently; (2) pool timeout, which can be setted by user,
     for example, in case of error happend. Pool will never give you access
     to invalid connection (see `invalid?/1`) or connection with nonzero
     timeout through `Conns.Pool.fetch/2` / `Conns.Pool.take/2` and
     `Conns.Pool.get_first/4` / `Conns.Pool.take_first/4` functions. To
     bypass, use `Conns.Pool.lookup/4` and `Conns.Pool.grab/2`.
  """
  @spec state( Conn.t, method) :: :invalid
                                | :closed
                                | :ready
                                | {:timeout, timeout}
  def state( conn, method)


  @doc """
  Close connection. This designed as a final state of conn. Connection
  in this state should return `:closed` for all `methods/1` and after
  successed close there can be no interactions.

  Connection with `state/2` == `:closed` would be removed from pool as
  soon as a pool find it. Trying to `put/2` such connection to pool
  results in `{:error, :closed}`.

  Use `Conns.Defaults` to define function `close/1` which always
  returns `{:error, :notsupported}`.
  """
  @spec close( Conn.t) :: :ok | {:error, error | :notsupported}
  def close( conn)


  @doc """
  Add tag to given connection so later it can be filtered
  using `tags/1` with `Conns.Pool.lookup/4` and
  `Conns.Pool.*_first/4` functions.

  Use `Conns.Defaults` to define function `add_tag/2`, `delete_tag/2`
  and `tags/1` which returns `:notsupported` atoms as a constant.
  """
  @spec add_tag( Conn.t, tag) :: Conn.t | :notsupported
  def add_tag( conn, tag)


  @doc """
  Delete tag from given connection.

  Use `Conns.Defaults` to define function `add_tag/2`, `delete_tag/2`
  and `tags/1` which returns `:notsupported` atoms as a constant.
  """
  @spec delete_tag( Conn.t, tag) :: Conn.t | :notsupported
  def delete_tag( conn, tag)


  @doc """
  All tags associated with given connection. Tags can be added via
  `Conn.add_tag/2` function and deleted via `Conn.delete_tag/2`.

  Use `Conns.Defaults` to define functions `add_tag/2`, `delete_tag/2`
  and `tags/1`, which returns `:notsupported` atoms as a constant.
  """
  @spec tags( Conn.t) :: [tag] | :notsupported
  def tags( conn)

end
