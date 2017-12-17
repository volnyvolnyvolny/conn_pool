defmodule Conn.Lib do
  @type  tag :: any

  @doc """
  Is connection valid or there exists an interaction
  type for which state function returns :invalid?
  """
  @spec valid?( Conn.t) :: boolean
  def valid?( conn) do
    Conn.int_types( conn)
    |> Enum.all?(& Conn.state( conn, &1) != :invalid)
  end


  defmacro __using__(_) do
    quote do

      def add_tag(_conn,_tag), do: {:error, :unsupported}

      def delete_tag(_conn,_tag), do: {:error, :unsupported}

      def tags(_conn), do: {:error, :unsupported}


      def undo(_conn,_int_type,_specs), do: {:error, :unsupported}

      defoverridable [add_tag: 2, delete_tag: 2, tags: 2, undo: 3]
    end
  end
end


defprotocol Conn do
  @moduledoc """
  Protocol represents abstract connection.

  # Callbacks

    * init( Conn.t, map) — initialize connection;
    * call( Conn.t, int_type, specs) — interact using given connection and specs;
    * source( Conn.t) — get connection source;
    * can_auth?( Conn.t) — is this connection supports authentication?
    * set_auth( Conn.t, auth) — setup connection to use authentication;
    * int_types( Conn.t) — interaction types supported by connection;
    * state( Conn.t, int_type) — state of connection in respect of interaction type.
  """

  @type  t :: any
  @type  id :: term
  @type  int_type :: atom
  @type  auth :: any
  @type  tag :: any
  @type  source :: atom | String.t


  @doc """
  Init connection. Options can be provided.

  While init connection, connection pool
  provide at least `source: source` option.
  """
  @spec init( Conn.t, keyword) :: Conn.t
  def init(_conn, opts \\ [])


  @doc """
  Send and receive data using given connection and specification.

  ## Examples

     iex> source = %JSON_API{url: "http://example.com/api/v1"}

     iex> {:ok, conn} = Pool.take_first( source, [:say, :listen]) #takes conn from pool
     iex> {:ok, conn} = Conn.call( conn, :say, %{what: "Hi!", name: "Louie"})
     iex> {:ok, "Hi Louie!"} = Conn.call( conn, :listen)
     iex> {:ok, _id} = Pool.put( conn) #returns connection back to pool

     Or:

     iex> {:ok, {id, conn}} = Pool.get_first( source, [:say, :listen])
     iex> {:ok, {conn, dialog_id}} = Conn.call( conn, :say, %{what: "Hi!", name: "Louie", opts: [:new_conversation]})
     iex> {:ok, {conn, "Hi Louie!"}} = Conn.call( conn, :listen, %{dialog_id: dialog_id})
     iex> {:ok, conn} = Conn.call( conn, :say, %{what: "How are U?", dialog_id: dialog_id})
     iex> Pool.update( id, conn)
     iex> {:ok, ^conn} = Pool.get( id)
     iex> {:ok, "Fine, tnx!"} = Conn.call( conn, :listen, %{dialog_id: dialog_id})
  """
  @spec call( Conn.t, int_type, keyword) :: :ok | {:error, any}
                                         | {:ok, Conn.t | {Conn.t, any}}
                                         | {:error, any, Conn.t}
                                         | {:error, {:timeout, timeout}}
  def call( conn, int_type, specs \\ [])



  @doc """
  Undo changes maded by `&Conn.call/3` call. This used in Sagas-transactions.
  If you don't use transactions over multiple connections — just define this to
  return :unsupported:

  `def undo( _conn, _int_type, _specs), do: {:error, :unsupported}`

  ## Examples

     iex> source = %JSON_API{url: "http://example.com/api/v1"}

     iex> {:ok, conn} = Pool.take_first( source, [:say, :listen]) #takes conn from pool
     iex> {:ok, conn} = Conn.call( conn, :say, %{what: "Hi!", name: "Louie"})
     iex> :ok = Conn.undo( conn, :say)
     iex> {:ok, _id} = Pool.put( conn) #returns connection back to pool
  """
  @spec undo( Conn.t, int_type, keyword) :: :ok
                                         | {:ok, Conn.t}
                                         | {:error, any, Conn.t}
                                         | {:error, :unsupported}
                                         | {:error, {:timeout, timeout}}
  def undo( conn, int_type, specs \\ [])


  @doc """
  Source of given connection.

  ## Examples

     iex> {:ok, {id, conn}} = Pool.choose_and_take(%JSON_API{url: "http://example.com/api/v1"}, :info)
     iex> Conn.source( conn).url
     "http://example.com/api/v1"
  """
  @spec source( Conn.t) :: source
  def source( conn)


  @doc """
  Authenticate connection.

  ## Return

    * {:ok, updated conn} — authentication succeed, return updated connection;
    * :already — connection is already authenticated;
    * :cannot, if authentification is not supported for this connection.
  """
  @spec set_auth( Conn.t, auth) :: {:ok, Conn.t} | :already | :cannot
  def set_auth( conn, auth)


  @doc """
  Authentication is supported?
  """
  @spec can_auth?( Conn.t) :: boolean
  def can_auth?( conn)


  @doc """
  Interaction types provided by connection.

  ## Examples

     iex> {:ok, {id, conn}} = Pool.choose_and_get(%JSON_API{url: "http://example.com/api/v1"}, :info)
     iex> :info in Conn.int_types( conn)
     true
  """
  @spec int_types( Conn.t) :: [int_type]
  def int_types( conn)


  defdelegate valid?( conn), to: Conn.Lib


  @doc """
  Connection state for given type of interacting.

  # Return atoms:

    * :cannot   — interaction type is not in the &Conn.int_types/1 list;
    * :ready | {:timeout, 0} — ready for given type interactions;
    * :invalid  — connection is broken, need to recreate it;
    * {:timeout, not spended}  — timeout happend, return how long is it to wait in milliseconds;
    * :needauth — for this type of interactions auth is needed.
    * {:needauth, {:timeout, not spended}} — for this type of interactions auth and also timeout was set.
  """
  @spec state( Conn.t, int_type) :: :cannot
                                  | :invalid
                                  | :ready
                                  | :needauth
                                  | {:timeout, timeout}
                                  | {:needauth, {:timeout, timeout}}
  def state( conn, int_type)


  @doc """
  Tag given connection so later it can be searched
  using `&Conn.tags/1`.
  """
  @spec add_tag( Conn.t, tag) :: Conn.t | :unsupported
  def add_tag( conn, tag)


  @doc """
  Delete tag from given connection.
  """
  @spec delete_tag( Conn.t, tag) :: Conn.t | :unsupported
  def delete_tag( conn, tag)


  @doc """
  Tags associated with given connection. Can be
  added via `&Conn.add_tag/2` function.
  """
  @spec tags( Conn.t) :: [tag] | :unsupported
  def tags( conn)

end
