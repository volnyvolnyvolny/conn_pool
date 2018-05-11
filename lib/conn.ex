defmodule Conn.Defaults do
  @moduledoc """

  Default implementations of optional callbacks to be used with `Conn` protocol:
  `Conn.resource/1`, `Conn.methods!/1`, `Conn.call/3`. Also, default
  implementation of `Conn.init/2` is given.

  Use it as:

      defimpl Conn, for: MyConn do
        use Conn.Defaults

        # Callbacks:
        def init(_, _), do: …
        def resource(_), do: …
        def methods!(_), do: …
        def call(_, _, _), do: …

        # Optional callbacks:
        def parse(_,_), do: …
        def spec(_), do: …
      end

  Also, `spec` fields could be provided as follows:

      defimpl Conn, for: MyConn do
        use Conn.Defaults, ttl: 10000, min_timeout: 10

        def resource(_), do: …
        def methods!(_), do: …
        def call(_, _, _), do: …
      end
  """
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      def parse(_conn, _data), do: {:error, :notimplemented}

      def init(conn, _args), do: {:ok, conn}

      def spec(_conn) do
        Enum.into(unquote(Macro.escape(opts)), %{
          ttl: :infinity,
          revive: true,
          min_timeout: 0,
          unsafe: false
        })
      end

      defoverridable spec: 1,
                     init: 2,
                     parse: 2
    end
  end
end

defprotocol Conn do
  @moduledoc """
  High level abstraction that represents connection in the most common sense.
  Implementation can use any transport to connect to any remote or VM-local
  resource: `Agent`, `GenServer`, different APIs, files, sockets, etc.

  Also, take a look at `Conn.Defaults`.

  ## Callbacks

    * `init/2` — initialize connection with given arguments;
    * `resource/1` — resource associated with connection or it's representation;
    * `methods!/1` — methods supported while making `Conn.call/3`;
    * `call/3` — interact via selected method;
    * `parse/2` — parse data in respect of connection context;
    * `spec/1` — default options used while making `Conn.Pool.put!/3` call.

  ## TL;DR example

  Let's implement simple generic text-base RPC protocol. Client can send server
  requests in the form of `:COMMAND` or `:COMMAND:ARGS` to execute `COMMAND`
  with given `ARGS` or without them. There is a special request `:COMMANDS` to
  ask for a list of available commands, the response to which is
  `ok:COMMAND1,CMD2,…`.

  Server always replies with `ok:COMMAND1,CMD2,…`, `ok`, `ok:DATA` or
  `err:REASON`, where `REASON` is `notsupported` (command), `badarg`, `parse`,
  or any arbitrary string.

  Now simple test conn will look like:

      defmodule TextConn, do: defstruct [:res]

  Let's implement protocol described above:

      defimpl Conn, for: TextConn do
        use Conn.Defaults, unsafe: true

        def init(conn, server) do
          if Process.alive?(server) do
            {:ok, %TextConn{res: server}}
          else
            {:error, :dead, :closed, conn}
            # — it says that there is no way to init
            # conn using the same args.
          end
        end

        def resource(%_{res: server}), do: server

        def methods!(%_{res: server}=conn) do
          send(server, {self(), ":COMMANDS"})

          receive do
            "ok:" <> cmds ->
              String.split(cmds, ",")
          end
        end

        def call(%_{res: server} = conn, cmd, args) when is_binary(args) do
          if Process.alive?(server) do
            send(server, {self(), args == "" && ":\#{cmd}" || ":\#{cmd}:\#{args}"})

            receive do
              "ok" ->
                {:noreply, conn}

              "ok:" <> reply ->
                {:reply, reply, conn}

              "err:notsupported" ->
                {:error, :notsupported, conn}

              "err:" <> reason ->
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
      iex> {:ok, conn} = Conn.init(%TextConn{}, res)
      iex> Conn.Pool.put!(pool, conn)
      :ok
      iex> Conn.Pool.call(pool, res, "GET", "")
      {:ok, "0"}
      iex> Conn.Pool.call(pool, res, "INC", "")
      {:ok, "1"}
      iex> Conn.Pool.call(pool, res, "DEC", "")
      {:error, :method}
      iex> Conn.Pool.call(pool, res, "INC", :badarg)
      {:error, "badarg"}
      iex> Conn.Pool.call(pool, res, "STOP", "")
      :ok
      iex> Conn.Pool.call(pool, res, "GET", "")
      {:error, :resource}

  `TextConn` could be used to connect to any server that implements the above
  protocol.
  """

  @type t :: term
  @type method :: any
  @type resource :: any
  @type reply :: any
  @type reason :: any
  @type init_args :: any

  @doc """
  Initializes `conn` with `args`.

  Raise inside the `init/2` call will not cause any troubles.

  Use `Conn.Defaults` to add implementation that just returns `{:ok, conn}`.

  ## In case of succeed, returns

    * `{:ok, conn}`;
    * `{:ok, timeout, conn}`, if suggested to wait `timeout` ms before use
      `conn` again.

  ## If initialization fails, returns

    * `{:error, reason, conn}`;
    * `{:error, reason, timeout, conn}`, if suggested to repeat `init/2` call
      after `timeout` ms;
    * `{:error, reason, :closed, conn}`, if `conn` could never be reopened
      (`init/2`) with the same `args`.

  where `reason` could be:

    * `:timeout`, if init process took too long;
    * `:toosoon`, if init must be repeated later;
    * arbitrary term.

  ## Examples

      iex> {:ok, conn1} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:ok, conn2} = Conn.init(%Conn.Agent{}, res: Conn.resource(conn1))
      iex> Conn.resource(conn1) == Conn.resource(conn2)
      true
  """
  @spec init(Conn.t(), init_args | []) ::
          {:ok, Conn.t()}
          | {:ok, non_neg_integer(), Conn.t()}
          | {:error, :timeout | reason, Conn.t()}
          | {:error, :timeout | :toosoon | reason, non_neg_integer(), Conn.t()}
          | {:error, :timeout | reason, :closed, Conn.t()}
  def init(_conn, args \\ [])

  @doc """
  Returns default options used with `Conn.Pool.put!/3`.

  Use `Conn.Defaults` to add default implementation of this method.

  ## Examples

      defmodule X do
        defstruct []

        defimpl Conn do
          use Conn.Defaults

          def resource(_), do: :foo
          def methods!(_), do: []
          def call(_, _, _), do: :foo
        end
      end

      Conn.spec(%X{}) == %{
        ttl: :infinity,
        revive: true,
        min_timeout: 0,
        unsafe: false
      }
  """
  @spec spec(Conn.t()) :: %{
          optional(:ttl) => timeout,
          optional(:revive) => boolean | :force,
          optional(:min_timeout) => non_neg_integer,
          optional(:unsafe) => boolean
        }
  def spec(_conn)

  @doc """
  Interacts using given `conn`, `method` and `payload`.

  ## If call succeed, returns

    * `{:noreply, conn}` — call could be repeated immediately;

    * `{:noreply, timeout, conn}` — call could be repeated after `timeout` ms;
    * `{:noreply, :closed, conn}` — call should not be repeated as it will
      return `{:error, :closed}` until reopen happend (via `init/2`);

    * `{:reply, reply, conn}`, where `reply` is the response data and call could
      be repeated immediately;
    * `{:reply, reply, timeout, conn}` when suggested to repeat call no sooner
      than `timeout` ms;
    * `{:reply, reply, :closed, conn}` when `init/2` should be called prior to
      any other forthcomming interactions.

  ## If call fails

  Error tuple should always take one of the following forms:

    * `{:error, :closed}` — call failed because connection is closed (use
      `init/2` to reopen);
    * `{:error, reason, conn}`;
    * `{:error, reason, timeout, conn}`;
    * `{:error, reason, :closed, conn}` — if `conn` became closed (use `init/2`
      to reopen).

  where:

    * `reason` could be `:notsupported` if `method` is not supported, `:timeout`
      if call took too long, or arbitrary term except `:closed`;
    * `timeout` is a suggested value in ms to wait until try any call on any
      method again.

  ## Examples

      iex> {:ok, conn} = Conn.init(%Conn.Agent{}, fn -> 42 end)
      iex> {:reply, 42, ^conn} = Conn.call(conn, :get, & &1)
      iex> {:noreply, :closed, ^conn} = Conn.call(conn, :stop, [])
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
          | {:error, :timeout | :notsupported | :toosoon | reason, timeout | :closed, Conn.t()}
  def call(conn, method, payload)

  @doc """
  Returns resource associated with `conn`. Resource could represent any
  arbitrary term, without limitations.

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

      iex> {:ok, conn} = Conn.init(%Conn.HTTP{}, url: "https://google.com")
      iex> Conn.resource(conn)
      "https://google.com"
  """
  @spec resource(Conn.t()) :: resource | [resource]
  def resource(conn)

  @doc """
  Returns methods of interactions available for `conn`. Can be HTTP methods:
  `:get`, `:put`, `:post`, etc., or custom terms `:info`, `:say`, `:ask`,
  `{:method, 1}` and so on. They represents types of interactions can be done
  using given connection.

  It's taken to be, that method list for an arbitrary conn could not always be
  preprogrammed or even stay permanent during it's lifecycle.

  ## Returns

    * list of methods available for `call/3`;
    * list of methods available for `call/3` and `updated conn`.

  or raise!

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
  Parses data in context of given `conn`.

  ## Returns

  On success:

    * `{:ok, {:call, method, payload}, rest of the data}`;
    * `{:ok, :methods, rest of the data}`.

  On error:

    * `{:error, :notimplemented}`;
    * `{:error, :needmoredata}`;
    * `{:error, {:parse, data that is malformed}, rest of the data}`;
    * `{:error, reason}` — for any other parse error.

  Use `Conn.Defaults` to add implementation that just returns `{:error,
  :notimplemented}`.

  See example in the head of the module docs.
  """
  @spec parse(Conn.t(), data) ::
          :ok
          | {:ok, {:call, method, data}, rest}
          | {:ok, :methods, rest}
          | {:error, {:parse, data}, rest}
          | {:error, :needmoredata}
          | {:error, :notimplemented | reason}
  def parse(_conn, data)
end
