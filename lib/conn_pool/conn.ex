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

    * `init/2` — initialize connection;
    * `call/3` — interact using given connection and specs;
    * `source/1` — get connection source;
    * `methods/1` — methods supported by connection;
    * `state/2` — state of connection in respect of method
      (`:ready` for interaction, `:notsupported` method, `:invalid`, timeout);

  ## Optional callbacks

    * `tags/1` — tags associated with connection;
    * `add_tag/2` — associate tag with connection;
    * `delete_tag/2` — deassociate tag from connection;
    * `set_auth/3` — authenticate connection;

    * `undo/3` — support for Sagas-transaction mechanism.
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


  @doc """
  Init connection. Options can be provided.

  As init argument, connection pool provide at
  least `{:source, source}` tuple.
  """
  @spec init( Conn.t, keyword) :: Conn.t
  def init(_conn, opts \\ [])


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
  Source of given connection.

  ## Examples

      iex> source = %JSON_API{url: "http://example.com/api/v1"}
      iex> {:ok, conn} = Pool.take_first( source, :info)
      iex> Conn.source( conn).url
      "http://example.com/api/v1"
  """
  @spec source( Conn.t) :: source
  def source( conn)


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
  Connection state for given type of interacting.

  ## Return atoms:

    * `:notsupported`            — method is not in the `methods/1` list;
    * `:ready` | `{:timeout, 0}` — ready for given method interaction;
    * `:invalid`                 — connection is broken for this method
                                   of interaction, need to recreate it;
    * `{:timeout, not spended}`  — timeout happend, return how long is it left
                                   to wait in microseconds.

  ## Timeouts

     System has two timeouts: (1) refresh rate, which prevents from using
     connection too frequently; (2) pool timeout, which can be setted by user,
     for example, in case of error happend. Pool will never give you access
     to invalid connection (see `invalid?/1`) or connection with nonzero
     timeout through `Conns.Pool.fetch/2` / `Conns.Pool.take/2` and
     `Conns.Pool.get_first/4` / `Conns.Pool.take_first/4` functions. To
     bypass, use `Conns.Pool.lookup/4`, `Conns.Pool.unsafe_get/2`,
     `Conns.Pool.unsafe_take/2`, or their synonyms.
  """
  @spec state( Conn.t, method) :: :notsupported
                                | :invalid
                                | :ready
                                | {:timeout, timeout}
  def state( conn, method)



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
