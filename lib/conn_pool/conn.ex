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
        def source(_), do: …
        def state(_, _), do: …
        def call(_, _, _), do: …
        def methods(_), do: …

        # Optional callbacks:
        def init(_, _), do: …
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


  @doc """
  Execute `Conn.fix/3` for every method that is `Conn.state/2`
  `:invalid`.
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

      def add_tag(_conn,_tag), do: :notsupported

      def delete_tag(_conn,_tag), do: :notsupported

      def tags(_conn), do: :notsupported

      def fix( conn,_method, init_args), do: Conn.init( conn, init_args)

      def init( conn,_args), do: {:ok, conn}

      def close(_conn), do: {:error, :notsupported}

      def undo(_conn,_method,_specs), do: {:error, :notsupported}

      def set_auth(_conn, _method, _auth), do: {:error, :notsupported}

      defoverridable [child_spec: 1, init: 2, fix: 3, close: 1,
                      add_tag: 2, delete_tag: 2, tags: 2,
                      undo: 3,
                      set_auth: 3]
    end
  end
end


defprotocol Conn do
  @moduledoc """
  Protocol for connections managable by `Conns.Pool`.
  It's a high level abstraction: underlying implementation can
  use any transport mechanism; one or many sources can be
  remote (for ex., some API) or VM-local such as `Agent`s,
  `GenServer`s, etc.

  # Callbacks

    * `sources/1` — get connection sources. *Commonly it's a list
    with a lonely single element* but you can make connections that are
    handling more than one source;
    * `methods/1` — methods supported in connection calls;
    * `state/2` — state of connection in respect of method
      (`:ready` for interaction; `:invalid` and needs to be fixed;
      have local timeout; was `:closed`);
    * `call/3` — interact using given connection and specs.

  ## Optional callbacks

    * `init/2` — initialize connection;
    * `fix/2` — try to fix connection that returns `state/2` == `:invalid`
       for specific method;

    * `parse/2` — parse data in respect of connection context;

    * `tags/1` — tags associated with connection;
    * `add_tag/2` — associate tag with connection;
    * `delete_tag/2` — deassociate tag from connection;

    * `set_auth/3` — authenticate connection;

    * `undo/3` — support for Sagas-transaction mechanism.
  """

  @type  t :: any
  @type  id :: non_neg_integer
  @type  method :: not_list

  @type  not_list :: term

  @type  auth :: any
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

  As init argument, `Conns.Pool` provide at least
  `[source: source]` keyword.

  Module `Conn.Defaults` has default implementation of `init/2` that
  just returns given conn. *Commonly, you would want to override it.*
  """
  @spec init( Conn.t, keyword) :: {:ok, Conn.t} | {:error, error}
  def init(_conn, args \\ [])



  @doc """
  Try to repair given method of conn interaction.
  As a the argument provide options used in `init/2`.

  Use `Conn.Defaults` to define `fix/2` that just
  calls `init/2` with provided arguments.
  """
  @spec fix( Conn.t, method, keyword) :: {:ok, Conn.t}
                                       | {:error, error, Conn.t}
                                       | {:error, error}
  def fix( conn, method, init_args)


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
  def call( conn, method, payload \\ nil)



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

  Module `Conn.Defaults` has default implementation of `set_auth/3` that
  returns as a constant `{:error, :notsupported}`.
  """
  @spec set_auth( Conn.t, method, auth) :: {:ok, :already | Conn.t}
                                        |  {:ok, :already, Conn.t}
                                        |  {:error, :notsupported | error}
                                        |  {:error, :notsupported | error, Conn.t}
  def set_auth( conn, method, auth)


  @doc """
  Interaction methods provided by connection. Can be http-methods:
  :get, :put, :post, etc., or user defined arbitrary terms :info,
  :say, :ask, {:method, 1} and so on. They represents types of
  interactions can be done using given connection.

  Returns list of methods available for `call/3`.

  This functions is actively used in "healthcare" mechanism provided
  by pool. So if the methods list will change, it's better to use
  some form of caching so pool will not block or slowdown.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, {id, conn}} = Pool.take_first( source, :info)
      iex> :info in Conn.methods( conn)
      true
  """
  @spec methods( Conn.t) :: [method]
  def methods( conn)


  @doc """
  Parse data in context of given connection. On success returns
  `{source, method, payload}` and the rest of data to parse.

  On parse error returns `{{:parse, data piece with error}, rest of data}`
  or `{{:notsupported, method, data piece with error}, rest of data}` if
  used method is not supported. Finally, it can return arbitrary
  error with `{:error, error}`.

  Use `Conn.Defaults` to define function `parse/2` to always return
  `{:error, :notsupported}`.
  """
  @spec parse( Conn.t, data) :: {:ok, {{source, method, data
                                                      | auth
                                                      | {auth, data}}, data}}
                              | {:error, {{:parse, data}, data}}
                              | {:error, {{:notsupported, method, data}, data}}
                              | {:error, :notsupported | error}
  def parse(_conn, data)


  defdelegate fix( conn, init_args), to: Conn.Defaults
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
     timeout. To bypass, use `Conns.Pool.lookup/4` and `Conns.Pool.grab/2`.
  """
  @spec state( Conn.t, method) :: :invalid
                                | :closed
                                | :ready
                                | {:timeout, timeout}
  def state( conn, method)


  @doc """
  Close connection. State `:closed` is designed as a final state of conn.
  Connection in this state should return `:closed` for all `methods/1`.
  There can be no after interactions.

  Normally, connection with `state/2` == `:closed` would be removed from
  pool as soon as a pool sense that, but this can be tweaked using `Conns.Pool`
  specs mechanism (see corresponding child spec section). Trying to `put/2`
  such connection to pool results in `{:error, :closed}`.

  Use `Conn.Defaults` to define function `close/1` that always returns
  `{:error, :notsupported}`.
  """
  @spec close( Conn.t) :: :ok | {:error, error | :notsupported}
  def close( conn)


  @doc """
  Add tag to given connection so later it can be filtered
  using `tags/1` with any pool's function that supports
  filter argument, such as `Conns.Pool.lookup/4`,
  `Conns.Pool.take_first/4` and so on.

  Use `Conn.Defaults` to define function `add_tag/2`, `delete_tag/2`
  and `tags/1` to return `:notsupported`.
  """
  @spec add_tag( Conn.t, tag) :: Conn.t | :notsupported
  def add_tag( conn, tag)


  @doc """
  Delete tag from given connection.

  Use `Conn.Defaults` to define function `add_tag/2`, `delete_tag/2`
  and `tags/1` to return `:notsupported`.
  """
  @spec delete_tag( Conn.t, tag) :: Conn.t | :notsupported
  def delete_tag( conn, tag)


  @doc """
  All tags associated with given connection. Tags can be added via
  `Conn.add_tag/2` function and deleted via `Conn.delete_tag/2`.

  Use `Conn.Defaults` to define function `add_tag/2`, `delete_tag/2`
  and `tags/1` to return `:notsupported`.
  """
  @spec tags( Conn.t) :: [tag] | :notsupported
  def tags( conn)

end
