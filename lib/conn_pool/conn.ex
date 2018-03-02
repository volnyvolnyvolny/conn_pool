# defmodule Conn.Defaults do
#   @moduledoc """
#   Default implementations of optional callbacks of `Conn` protocol:
#   `Conn.undo/3`, `Conn.set_auth/3`. All of them are overridable, and by default
#   return `{:error, :notsupported}`.

#   Use it like this:

#       defimpl Conn, for: MyConn do
#         use Conn.Defaults

#         # Callbacks:
#         def init(_, _), do: …
#         def resource(_), do: …
#         def methods(_), do: …
#         def call(_, _, _), do: …

#         # Optional callbacks:
#         def undo(_, _, _), do: …
#         def parse(_,_), do: …
#       end
#   """

#   defmacro __using__(_) do
#     quote do

# #      def undo(_conn,_method,_specs), do: {:error, :notimplemented}
#       def parse(_conn,_data), do: {:error, :notimplemented}

#       defoverridable [#undo: 3,
#                       parse: 2]
#     end
#   end
# end


defprotocol Conn do

  @moduledoc """
  High level abstraction that represents connection in the most common sense.
  Implementation can use any transport to connect to any remote or VM-local
  resource: `Agent`, `GenServer`, different http-APIs, etc.

  ## Callbacks

    * `init/2` — initialize connection with given arguments;
    * `resource/1` — resource for that interaction is made;
    * `methods/1` — methods supported while making `Conn.call/3`;
    * `call/3` — interact via selected method.
    * `parse/2` — parse data in respect of connection context.

  ## Example

  Let's implement simple generic text-base interaction protocol. Client can send
  server commands in the format of `:COMMAND;` or `:COMMAND:ARGS;` to execute
  `COMMAND` with given `ARGS` or without them. There is a special command
  `:COMMANDS;` that returns available commands;

  Server is the process that may reply with `ok:COMMAND1,CMD2,…`, `ok`,
  `ok:DATA` or `err:REASON`, where `REASON` could be `notsupported` (command),
  `badarg`, `parse`, or any other.

  Now simple test conn will look like:

      defmodule TextConn, do: defstruct [:res]

  Let's implement protocol described above:

      defimpl Conn, for: TextConn do

        def init(conn, pid) do
          if Process.alive? pid do
            {_, conn} = Conn.methods conn # take available methods
            {:ok, %{conn | res: pid}}
          else
            {:error, :dead, :infinity, conn} # take available methods
          end
        end

        def resource(%_{res: pid}), do: pid

        def methods(%_{res: pid}=conn) do
          unless Process.alive? pid do
            :error
          else
            send pid, {self(), ":COMMANDS;"}
            receive do
              "ok:"<>cmds -> String.split ","
            # after 5000 -> :error # no need, pool will handle this
            end
          end
        end

        def call(%_{res: pid}=c, cmd, args \\\\ "") do
          unless Process.alive? pid do
            {:error, :closed}
          else
            send pid, {self(), if args == "", do: ":\#{cmd};", else: ":\#{cmd}:\#{args};"}

            receive do
              "ok;" ->  {:ok, 0, c}
              "ok:"<>reply ->  {:ok, reply, 0, c}

              "err:notsupported" ->  {:error, :notsupported, 50, c} # suggests timeout 50 ms
              "err:"<>reason ->      {:error, reason, 50, c}
            after 5000 ->
              {:error, :timeout, 0, c}
            end
          end
        end

  — it's the part of the implementation used on the client side, and now
  parsing:

        def parse(conn, ""), do: :ok
        def parse(conn, ":COMMANDS;"<>rest), do: {:ok, :methods, rest}
        def parse(conn, ":"<>data) do
          case Regex.named_captures ~r[(?<cmd>.*)(:(?<args>.*))?;(?<rest>.*)], data do
            %{"cmd" => cmd, "args" => args, "rest" => rest} ->
              {:ok, {:call, cmd, args}, rest}
            nil ->
              {:error, :needmoredata}
          end
        end
        def parse(conn, malformed) do
          case String.split data, ";" do
            [malformed, rest] ->
              {:error, {:parse, malformed}, rest}
            _ ->
              {:error, :needmoredata}
          end
        end
      end

  That's it. Now all that left is to spawn corresponding server that will
  interact with client using above protocol. Let us implement server that holds
  integer value and supports commands `INC`, `GET` and `STOP`.

      iex> defmodule Server do
      ...>   def loop(data, state \\\\ 0) do
      ...>     receive do
      ...>       {pid, new} ->
      ...>         data = data<>new
      ...>         case Conn.parse %TestConn{}, data do
      ...>           {:error, :needmoredata} -> loop rest, state
      ...>           {:error, {:parse,_}, rest} ->
      ...>              send pid, "err:parse"
      ...>              loop rest, state
      ...>           {:ok, :methods, rest} ->
      ...>              send pid, "ok:INC,GET,STOP"
      ...>              loop rest, state
      ...>           {:ok, {:call, "INC", ""}, rest} ->
      ...>              send pid, "ok:"<>state+1
      ...>              loop rest, state+1
      ...>           {:ok, {:call, "GET", ""}, rest} ->
      ...>              send pid, "ok:"<>state
      ...>              loop rest, state
      ...>           {:ok, {:call, "STOP", ""},_rest} ->
      ...>              send pid, "ok"
      ...>           {:ok, {:call, _, ""},_rest} ->
      ...>              send pid, "err:notsupported"
      ...>              loop rest, state
      ...>           {:ok, {:call, _, _},_rest} ->
      ...>              send pid, "err:badarg"
      ...>              loop rest, state
      ...>         end
      ...>     end
      ...>   end
      ...> end
      ...>
      ...>
      iex> pid = spawn_link fn -> Server.loop "" end
      iex> {:ok, pool} = Conn.Pool.start_link()
      iex> Conn.Pool.init pool, %TextConn{}, pid
      iex> Conn.Pool.call pool, pid, "GET"
      {:ok, 0}
      iex> Conn.Pool.call pool, pid, "INC"
      {:ok, 1}
      iex> Conn.Pool.call pool, pid, "DEC"
      {:error, :notsupported}
      iex> Conn.Pool.call pool, pid, "INC", :badarg
      {:error, "badarg"}
      iex> Conn.Pool.call pool, pid, "STOP"
      :ok
      iex> Conn.Pool.call pool, pid, "GET"
      {:error, :closed}

  Now `TextConn` could be used to connect to *any* server that implements above
  protocol.
  """

  @enforce_keys [:conn]
  defstruct [:conn,
             :init_args,
             :extra,
             :expires,

             methods: [],
             revive: false,

             stats: %{},

             init_timeout: 5000, # ms
             last_call: System.system_time(),
             timeout: 0]


  @type  t :: term
  @type  id :: non_neg_integer

  @type  method :: any
  @type  auth :: any
  @type  resource :: any
  @type  reply :: any
  @type  reason :: any
  @type  init_args :: any


  @doc """
  Initialize connection, args could be provided.

  ## Returns

    * `{:ok, conn}` in case of successful initialization.

    * `{:error, reason, 0 ms, conn}` in case initialization failed with reason
    `reason`, suggested to repeat `init/2` call immediately.
    * `{:error, reason, T ms, conn}` in case initialization failed with reason
    `reason`, suggested to repeat `init/2` call after `T` milliseconds;
    * `{:error, reason, :infinity, conn}` in case initialization failed with
    reason `reason`, suggested to never repeat `init/2` call.

  ## Examples

      iex> {:ok, conn1} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, conn2} = Conn.init %Conn.Agent{}, res: Conn.resource conn1
      iex> Conn.resource conn1 == Conn.resource conn2
      true
  """
  @spec init(Conn.t, init_args)
        :: {:ok, Conn.t} |
           {:error, :timeout | reason, timeout, Conn.t}
  def init(_conn, args \\ nil)


  @doc """
  Interact using given connection, method and data.

  ## Returns

    * `{:ok, timeout | :closed, conn}` if call succeed and *suggested* to wait
      `timeout` ms until use `conn` again. `:closed` or `:infinity` means that
      connection is closed and there can be no interactions from this moment as
      any `call/3` will return `{:error, :closed}`;

    * `{:ok, reply, timeout | :closed, conn}`, where `reply` is the response
      data;

    * `{:error, :closed}` if connection is closed;
    * `{:error, reason, timeout | :closed, conn}`.

  ## Examples

      iex> {:ok, conn} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, reply, 0, ^conn} = Conn.call conn, :get, & &1
      iex> reply
      42
      iex> {:ok, :closed, conn} == Conn.call conn, :stop
      true
      iex> Conn.call conn, :get, & &1
      {:error, :closed}
  """
  @spec call(Conn.t, Conn.method, any)
        :: {:ok,        0 | pos_integer | :infinity | :closed, Conn.t}
         | {:ok, reply, 0 | pos_integer | :infinity |:closed, Conn.t}
         | {:error, :closed}
         | {:error, :timeout,      0 | pos_integer | :infinity | :closed, Conn.t}
         | {:error, :notsupported, 0 | pos_integer | :infinity | :closed, Conn.t}
         | {:error, reason,        0 | pos_integer | :infinity | :closed, Conn.t}
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
  Resource is an arbitrary term. Mostly it is some pid. Connection represents
  interaction with resource.

  ## Examples

      iex> {:ok, conn1} = Conn.init %Conn.Agent{}, fn -> 42 end
      iex> {:ok, conn2} = Conn.init %Conn.Agent{}, res: Conn.resource conn
      iex> Conn.resource conn1 == Conn.resource conn2
      true

      iex> {:ok, agent} = Agent.start_link fn -> 42 end
      iex> {:ok, conn1} = Conn.init %Conn.Agent{}, res: agent
      iex> {:ok, conn2} = Conn.init %Conn.Agent{}, res: agent
      iex> Conn.resource conn1 == Conn.resource conn2
      true
  """
  @spec resource(Conn.t) :: resource | [resource]
  def resource(conn)


  @doc """
  Methods of interactions available for connection. Can be http-methods: `:get`,
  `:put`, `:post`, etc., or user defined arbitrary terms `:info`, `:say`,
  `:ask`, `{:method, 1}` and so on. They represents types of interactions can be
  done using given connection.

  ## Returns

    * list of methods available for `call/3`;
    * list of methods available for `call/3` and `updated conn`.

  ## Examples

      iex> Conn.methods %Conn.Agent{}
      [:get, :get_and_update, :update, :stop]
  """
  @spec methods(Conn.t) :: [method] | {[method], Conn.t}
  def methods(conn)


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
  @spec parse(Conn.t, data)
        :: :ok
         | {:ok, {:call, method, data}, rest}
         | {:ok, :methods, rest}
#         | {:ok, {:undo, method, data}, rest}

         | {:error, {:parse, data}, rest}
         | {:error, :needmoredata}
         | {:error, :notimplemented | reason}
  def parse(_conn, data)

end
