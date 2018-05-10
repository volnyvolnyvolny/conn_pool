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
    * `parse/2` — parse data in respect of connection context.

  ## Example

  Let's implement simple generic text-base RPC protocol. Client can send server
  requests in the form of `:COMMAND` or `:COMMAND:ARGS` to execute `COMMAND`
  with given `ARGS` or without them. There is a special request `:COMMANDS` to
  ask for a list of all available commands, response for it is `ok:COMMAND1,CMD2,…`.

  Server may reply with `ok:COMMAND1,CMD2,…`, `ok`, `ok:DATA` or `err:REASON`,
  where `REASON` could be `notsupported` (command), `badarg`, `parse`, or
  arbitrary string.

  Now simple test conn will look like:

      defmodule TextConn, do: defstruct [:res]

  Let's implement protocol described above:

      defimpl Conn, for: TextConn do
        def init(conn, server) do
          if Process.alive?(server) do
            {:ok, %TextConn{res: server}}
          else
            {:error, :dead, :closed, conn}
          end
        end

        def resource(%_{res: server}), do: server

        def methods!(%_{res: server}=conn) do
          send(server, {self(), ":COMMANDS"})

          receive do
            "ok:" <> cmds ->
              String.split(",")
          end
        end

        def call(%_{res: server} = conn, cmd, args \\\\ nil) when is_binary(args) do
          if Process.alive?(server) do
            send(server, {self(), args && ":\#{cmd}:\#{args}" || ":\#{cmd}"})

            receive do
              "ok" ->
                {:noreply, conn}

              "ok:" <> reply ->
                {:reply, reply, conn}

              "err:notsupported" ->
                {:error, :notsupported, conn}

              "err:"<>reason ->
                # Suggest 50 ms timeout.
                {:error, reason, 50, conn}
            after
              5000 ->
                {:error, :timeout, conn}
            end
          else
            {:error, :closed}
          end
        end

  — it's the part of the implementation used on the client side. Let's move to
  parsing:

        def parse(conn, ""), do: :ok
        def parse(conn, ":COMMANDS" <> _), do: {:ok, :methods, ""}

        def parse(conn, ":" <> data) do
          case Regex.named_captures(~r[(?<cmd>[^:]+)(?::(?<args>.*))?], data) do
            %{"cmd" => cmd, "args" => args} ->
              {:ok, {:call, cmd, args}, ""}

            _ ->
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
      ...>       {client, data} ->
      ...>         case Conn.parse(%TextConn{}, data) do
      ...>           {:error, {:parse, _}, _rest} ->
      ...>              send(client, "err:parse")
      ...>              loop(state)
      ...>
      ...>           {:ok, :methods, _rest} ->
      ...>              send(client, "ok:INC,GET,STOP")
      ...>              loop(state)
      ...>
      ...>           {:ok, {:call, "INC", ""}, _rest} ->
      ...>              send(client, "ok:\#{state+1}")
      ...>              loop(state+1)
      ...>
      ...>           {:ok, {:call, "GET", ""}, _rest} ->
      ...>              send(client, "ok:\#{state}")
      ...>              loop(state)
      ...>
      ...>           {:ok, {:call, "STOP", ""}, _rest} ->
      ...>              send(client, "ok")
      ...>
      ...>           {:ok, {:call, _, ""}, _rest} ->
      ...>              send(client, "err:notsupported")
      ...>              loop(state)
      ...>
      ...>           {:ok, {:call, _, _}, _rest} ->
      ...>              send(client, "err:badarg")
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
      {:error, :resource}

  `TextConn` could be used to connect to any server that implements above
  protocol.
  """

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

  ## In case of succeed, returns

    * `{:ok, conn}`, where `conn` could be used immediately;
    * `{:ok, timeout, conn}`, where suggested to wait `timeout` ms before use
      `conn`.

  ## If initialization fails, returns

    * `{:error, :timeout, conn}` when call took too long, and it is suggested to
      repeat it immediately;
    * `{:error, reason, conn}` when suggested to repeat call immediately;
    * `{:error, reason, timeout, conn}` when suggested to repeat `init/2` call
      after `timeout` ms.

  Raise inside the `init/2` call will not cause problems.

  ## Examples

      iex> {:ok, conn1} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:ok, conn2} = Conn.init(%Conn.Agent{}, res: Conn.resource(conn1))
      iex> Conn.resource(conn1) == Conn.resource(conn2)
      true
  """
  @spec init(Conn.t(), init_args | []) ::
          {:ok, Conn.t()}
          | {:ok, timeout, Conn.t()}
          | {:error, :timeout | reason, Conn.t()}
          | {:error, :timeout | reason, timeout, Conn.t()}
  def init(_conn, args \\ [])

  @doc """
  Interacts using given connection, method and data.

  ## If call succeed, returns

    * `{:noreply, conn}` — call could be repeated immediately;
    * `{:noreply, timeout, conn}` — call could be repeated after `timeout` ms;
    * `{:noreply, :infinity | :closed, conn}` — call should not be repeated as
      it will return `{:error, :closed}` until reopen happend (via `init/2`);

    * `{:reply, reply, conn}`, where `reply` is the response data and call could
      be repeated immediately;
    * `{:reply, reply, timeout, conn}` when suggested to repeat call no sooner
      than `timeout` ms;
    * `{:reply, reply, :infinity | :closed, conn}` when `init/2` should be
      called prior to any other interactions.

  ## If call fails, returns

    * `{:error, :closed}` — because connection is closed (use `init/2` to
      reopen);
    * `{:error, :timeout, conn}` — because call takes too long;
    * `{:error, :notsupported, conn}` — because method is not supported;
    * `{:error, reason, conn}` where `reason` is an arbitrary term and call
      could be repeated immediately;
    * `{:error, reason, timeout, conn}` suggested to repeat call no sooner than
      `timeout` ms;
    * `{:error, reason, :infinity | :closed, conn}` when call should be repeated
      only after connection is reopened with `init/2`.

  ## Examples

      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:reply, 42, ^conn} = Conn.call(conn, :get, & &1)
      iex> {:noreply, :closed, ^conn} = Conn.call(conn, :stop)
      iex> Conn.call(conn, :get, & &1)
      {:error, :closed}
  """
  @spec call(Conn.t(), Conn.method(), any) ::
          {:noreply, Conn.t()}
          | {:noreply, timeout, Conn.t()}
          | {:reply, reply, Conn.t()}
          | {:reply, reply, timeout, Conn.t()}
          | {:error, :closed}
          | {:error, :timeout | :notsupported | reason, Conn.t()}
          | {:error, :timeout | :notsupported | reason, timeout | :closed, Conn.t()}
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
  Resource is an arbitrary term (for ex., some pid). Connection represents
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
  Methods of interactions available for connection. Can be HTTP-methods: `:get`,
  `:put`, `:post`, etc., or custom terms `:info`, `:say`, `:ask`, `{:method, 1}`
  and so on. They represents types of interactions can be done using given
  connection.

  It's taken to be that for arbitrary conn method list could not always be
  preprogrammed or even stay permanent during it's lifecycle.

  ## Returns

    * list of methods available for `call/3`;
    * list of methods available for `call/3` and `updated conn`.

  or raise.

  ## Examples

      iex> Conn.methods!(%Conn.HTTP{})
      [:get, :post, :put, :head, :delete, :patch, :options]

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
