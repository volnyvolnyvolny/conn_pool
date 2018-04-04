defmodule Conn.Defaults do
  @moduledoc """
  Default implementations of optional callbacks of `Conn` protocol:
  `Conn.undo/3`. All of them are overridable, and by default
  return `{:error, :notsupported}`.

  Use it like this:

      defimpl Conn, for: MyConn do
        use Conn.Defaults

        # Callbacks:
        def init(conn, init_args), do: …
        def resource(conn), do: …
        def methods(conn), do: …
        def call(conn, method, payload), do: …

        # Optional callbacks:
        def timeout(conn), do: …
        def parse(conn, data), do: …
      end
  """

  defmacro __using__(_) do
    quote do

#      def undo(_conn,_method,_specs), do: {:error, :notimplemented}
      def parse(_conn,_data), do: {:error, :notimplemented}
      def timeout(_conn), do: 0

      defoverridable [timeout: 1,
#                      undo: 3,
                      parse: 2]
    end
  end
end

defprotocol Conn do
  @moduledoc """
  High level abstraction that represents connection in the most common sense.
  Implementation can use any transport to connect to any remote or VM-local
  resource: `Agent`, `GenServer`, different http-APIs, etc.

  ## Callbacks

    * `init/2` — initialize connection with given arguments;
    * `resource/1` — resource for that interaction is made;
    * `methods!/1` — methods supported while making `Conn.call/3`;
    * `call/3` — interact via selected method;
    * `timeout/1` — suggested timeout in ms before repeating `Conn.all/3`;
    * `parse/2` — parse data in respect of connection context.

  ## Example

  Let's implement simple generic text-base RPC protocol. Client can send server
  requests in the form of `:COMMAND` or `:COMMAND:ARGS` to execute `COMMAND`
  with given `ARGS` or without them. There is a special request `:COMMANDS` to
  ask for a list of all available commands, that is send in form of
  `ok:COMMAND1, CMD2,…`.

  Server may reply with `ok:COMMAND1,CMD2,…`, `ok`, `ok:DATA` or `err:REASON`,
  where `REASON` could be `notsupported` (command), `badarg`, `parse`, or any
  other.

  Now simple test conn will look like:

      defmodule TextConn, do: defstruct [:res, timeout: 0]

  Let's implement protocol described above:

      defimpl Conn, for: TextConn do
        def init(conn, pid) do
          if Process.alive?(pid) do
            {:ok, %TextConn{res: pid}}
          else
            {:error, :dead, %{conn | timeout: :closed}}
          end
        end

        def resource(%_{res: pid}), do: pid

        def timeout(conn), do: conn.timeout

        def methods!(%_{res: pid}=conn) do
          send(pid, {self(), ":COMMANDS"})

          receive do
            "ok:" <> cmds ->
              String.split(",")
          end
        end

        def call(%_{res: pid} = conn, cmd, args \\\\ nil) when is_binary(args) do
          if Process.alive?(pid) do
            conn = %{conn | timeout: 0}

            send(pid, {self(), args && ":\#{cmd}:\#{args}" || ":\#{cmd}"})

            receive do
              "ok" ->
                {:ok, conn}

              "ok:" <> reply ->
                {:ok, reply, conn}

              "err:notsupported" ->
                {:error, :notsupported, %{conn | timeout: 50}}

              "err:"<>reason ->
                {:error, reason, %{conn | timeout: 50}}
            after
              5000 ->
                {:error, :timeout, conn}
            end
          else
            {:error, :closed}
          end
        end

  — it's the part of the implementation used on the client side, and now
  parsing:

        def parse(conn, ""), do: :ok
        def parse(conn, ":COMMANDS" <> _), do: {:ok, :methods, ""}

        def parse(conn, ":" <> data) do
          case Regex.named_captures(~r[(?<cmd>.*)(:(?<args>.*))?], data) do
            %{"cmd" => cmd, "args" => args} ->
              {:ok, {:call, cmd, args}, ""}

            nil ->
              {:error, {:parse, data}, ""}
          end
        end
        def parse(conn, malformed) do
          {:error, {:parse, malformed}, ""}
        end
      end

  That's it. Now all that left is to spawn corresponding server that will
  interact with client using above protocol. Let us implement server that holds
  integer value and supports commands `INC`, `GET` and `STOP`.

      iex> defmodule Server do
      ...>   def loop(state \\\\ 0) do
      ...>     receive do
      ...>       {pid, data} ->
      ...>         case Conn.parse(%TextConn{}, data) do
      ...>           {:error, {:parse, _}, _rest} ->
      ...>              send(pid, "err:parse")
      ...>              loop(state)
      ...>
      ...>           {:ok, :methods, _rest} ->
      ...>              send(pid, "ok:INC,GET,STOP")
      ...>              loop(state)
      ...>
      ...>           {:ok, {:call, "INC", ""}, _rest} ->
      ...>              send(pid, "ok:\#{state+1}")
      ...>              loop(state+1)
      ...>
      ...>           {:ok, {:call, "GET", ""}, _rest} ->
      ...>              send(pid, "ok:\#{state}")
      ...>              loop(state)
      ...>
      ...>           {:ok, {:call, "STOP", ""}, _rest} ->
      ...>              send(pid, "ok")
      ...>
      ...>           {:ok, {:call, _, ""}, _rest} ->
      ...>              send(pid, "err:notsupported")
      ...>              loop(state)
      ...>
      ...>           {:ok, {:call, _, _}, _rest} ->
      ...>              send(pid, "err:badarg")
      ...>              loop(state)
      ...>         end
      ...>     end
      ...>   end
      ...> end
      ...>
      ...>
      iex> res = spawn_link(&Server.loop/0)
      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> Conn.Pool.init(pool, %TextConn{}, res)
      iex> Conn.Pool.call(pool, res, "GET")
      {:ok, "0"}
      iex> Conn.Pool.call(pool, res, "INC")
      {:ok, "1"}
      iex> Conn.Pool.call(pool, res, "DEC")
      {:error, :method}
      iex> Conn.Pool.call(pool, res, "INC", :badarg)
      {:error, "badarg"}
      iex> Conn.Pool.call(pool, res, "STOP")
      :ok
      iex> Conn.Pool.call(pool, res, "GET")
      {:error, :closed}

  `TextConn` could be used to connect to *any* server that implements above
  protocol.
  """

  @type info :: %Conn{
          conn: any,
          init_args: any | nil,
          extra: any | nil,
          ttl: pos_integer | :infinity,
          methods: [method],
          closed: boolean,
          stats: %{required(method) => {non_neg_integer, pos_integer}},
          last_call: pos_integer | :never,
          last_init: pos_integer | :never,
          timeout: timeout,
          revive: boolean | :force
        }

  @enforce_keys [:conn]
  defstruct [
    :conn,
    :init_args,
    :extra,
    :methods,
    ttl: :infinity,
    closed: false,
    revive: false,
    stats: %{},
    last_call: :never,
    last_init: :never,
    timeout: 0
  ]

  @type t :: term
  @type id :: non_neg_integer

  @type method :: any
  @type auth :: any
  @type resource :: any
  @type reply :: any
  @type reason :: any
  @type init_args :: any

  @doc """
  Initialize connection, args could be provided.

  ## Returns

    * `{:ok, conn}` in case of successful initialization;
    * `{:error, :timeout, conn}` in case initialization failed because it takes
      too long;
    * `{:error, reason, conn}` in case initialization failed with
    reason `reason`, suggested to never repeat `init/2` call.

  ## Examples

      iex> {:ok, conn1} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:ok, conn2} = Conn.init(%Conn.Agent{}, res: Conn.resource(conn1))
      iex> Conn.resource(conn1) == Conn.resource(conn2)
      true
  """
  @spec init(Conn.t(), init_args) ::
          {:ok, Conn.t()}
          | {:error, :timeout | reason, Conn.t()}
  def init(_conn, args \\ nil)

  @doc """
  Interact using given connection, method and data.

  ## Returns

    * `{:ok, conn}` if call succeed;
    * `{:ok, reply, conn}`, where `reply` is the response data;
    * `{:error, :closed}` if call fails because connection is closed;
    * `{:error, reason, conn}` in case of arbitrary error.

  ## Examples

      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:ok, reply, ^conn} = Conn.call(conn, :get, & &1)
      iex> reply
      42
      iex> {:ok, conn} == Conn.call(conn, :stop)
      true
      iex> Conn.call(conn, :get, & &1)
      {:error, :closed}
  """
  @spec call(Conn.t(), Conn.method(), any) ::
          {:ok, Conn.t()}
          | {:ok, reply, Conn.t()}
          | {:error, :closed}
          | {:error, :timeout | :notsupported | reason, Conn.t()}
  def call(conn, method, payload \\ nil)

  # @doc """
  # Undo changes that were made by `Conn.call/3`. This used in
  # Sagas-transactions.

  # If you don't use transactions over multiple connections, use default
  # implementation provided by `Conn.Defaults` that returns `{:error,
  # :unsupported}` tuple for every conn, method and payload given as an argument.

  # ## Examples

  # {:ok, conn} = Pool.take_one(resource, [:say, :listen])
  # {:ok, conn} = Conn.call(conn, :say, what: "Hi!", name: "Louie")

  #     resource = %JSON_API{url: "http://example.com/api/v1"}

  #     {:ok, conn} = Pool.take_first(resource, [:say, :listen])
  #     {:ok, conn} = Conn.call(conn, :say, what: "Hi!", name: "Louie")

  #     :ok = Conn.undo(conn, :say, what: "Hi!", name: "Louie")

  #     # or, maybe, simply:
  #     # :ok = Conn.undo(conn, :say) #as payload doesn't matters here
  #     {:ok, _id} = Pool.put(conn) #return connection to pool
  # """
  # @spec undo(Conn.t, method, keyword) :: :ok
  #                                      | {:ok, Conn.t}

  #                                      | {:error, reason, Conn.t}
  #                                      | {:error, :unsupported}
  # def undo(conn, method, payload_used \\ [])

  @doc """
  Resource is an arbitrary term. Mostly it is some pid. Connection represents
  interaction with resource.

  ## Examples

      iex> {:ok, conn1} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:ok, conn2} = Conn.init(%Conn.Agent{}, res: Conn.resource(conn1))
      iex> Conn.resource(conn1) == Conn.resource(conn2)
      true

      iex> {:ok, agent} = Agent.start_link(fn -> 42 end)
      iex> {:ok, conn1} = Conn.init(%Conn.Agent{}, res: agent)
      iex> {:ok, conn2} = Conn.init(%Conn.Agent{}, res: agent)
      iex> Conn.resource(conn1) == Conn.resource(conn2)
      true
  """
  @spec resource(Conn.t()) :: resource | [resource]
  def resource(conn)


  @doc """
  *Suggested* value (in ms) to wait until use `call/3` again. Returns `0` if no
  timeout is suggested; `:closed` or `:infinity` if connection should never be
  used again as from this moment any `call/3` will return `{:error, :closed}`.

  `Conn.Pool` executes this method after making every `call/3`.
  """
  @spec resource(Conn.t()) :: non_neg_integer() | :infinity | :closed
  def timeout(conn)


  @doc """
  Methods of interactions available for connection. Can be http-methods: `:get`,
  `:put`, `:post`, etc., or user defined arbitrary terms `:info`, `:say`,
  `:ask`, `{:method, 1}` and so on. They represents types of interactions can be
  done using given connection.

  ## Returns

    * list of methods available for `call/3`;
    * list of methods available for `call/3` and `updated conn`.

  or raise.

  ## Examples

      iex> Conn.methods!(%Conn.Agent{})
      [:get, :get_and_update, :update, :stop]
  """
  @spec methods!(Conn.t()) :: [method] | {[method], Conn.t()}
  def methods!(conn)

  @type data :: any
  @type rest :: data

  @doc """
  Parse data in context of given connection.

  ## Returns

  On success:

    * `{:ok, {:call, method, payload}, rest of the data}`;
    * `{:ok, :methods, rest of the data}`.

  On error:

    * `{:error, :notimplemented}` if parse is not implemented;
    * `{:error, :needmoredata}` if parsing needs more data;
    * `{:error, {:parse, data that is malformed}, rest of the data}`;
    * `{:error, reason}` for any other error while parsing.

  If `parse/2` function will not be used return `{:error, :notimplemented}`.

  See example in the head of the module docs.
  """
  @spec parse(Conn.t(), data) ::
          :ok
          | {:ok, {:call, method, data}, rest}
          | {:ok, :methods, rest}
          | {:error, {:parse, data}, rest}
          | {:error, :needmoredata}
          | {:error, :notimplemented | reason}
  #         | {:ok, {:undo, method, data}, rest}
  def parse(_conn, data)
end
