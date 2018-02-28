defmodule Conns.Pool.Server do
  @moduledoc false

  use GenServer

  import NaiveDateTime


  # Generate uniq id
  defp gen_id(), do: System.system_time()


  def init(penalty) do
   :rand.seed(:exsp)

    Process.put :'$penalty', penalty || fn
      0 -> 50
      p when p < 3000 -> p*2
      p -> p
    end

    #      resources,      conns
    {:ok, {AgentMap.new(), AgentMap.new()}}
  end


  def start_link(args, opts) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def start(args, opts) do
    GenServer.start(__MODULE__, args, opts)
  end


  def handle_call({:put, conn, tags, init_args}, _f, {resources, conns}=state) do
    conn = %Conn{conn: conn,
                 init_args: init_args,
                 tags: tags}

    id = gen_id()

    AgentMap.put conns, id, conn
    AgentMap.update resources, Conn.resource(conn), fn
      nil -> [id]
      ids -> [id|ids]
    end

    {:reply, id, state}
  end


  def handle_call({:call, res, method, payload, filter}, _f, state) do
    {resources, conns} = state
    ids = AgentMap.fetch! resources, res
    conns = for id <- ids,
                conn = AgentMap.fetch!(conns, id),
                method in conn.methods,
                filter.(conn) do

              {id, conn}
            end

    conns = Enum.sort_by conns, fn {id,conn} ->
      len = AgentMap.queue_len conns, id
      conn.timeout
    end

    AgentMap.update conns, id, fn ->
    end

    {:noreply, state}
  end


  def handle_call({:pop, id}, _f, {_, conns}=state) do
    {:reply, AgentMap.pop(conns, id), state}
  end

#   def handle_call( {:update_conn, {id, conn}}, _from, table) do
#     case :ets.lookup( table, id) do
#       [{^id, timeout, _conn}] -> :ets.insert( table, {id, timeout, conn})
#       [] -> :ets.insert( table, {id, nil, conn})
#     end

#     {:reply, conn, table}
#   end


#   def handle_cast( {:set_timeout, {id, timeout}}, _from, table) do
#     next_try = if timeout == :infinity do
#                 :never
#                else
#                  add( utc_now(), timeout, :microseconds)
#                end

#     with [{id,_timeout, conn}] <- :ets.lookup( table, id) do
#      :ets.insert( table, {id, {:next_try, next_try}, conn})
#     end

#     {:noreply, table}
#   end

#   def handle_cast( {:put_with_timeout, {conn, timeout}}, _from, table) do
#     {_,id,_} = handle_call( {:put, conn}, :_, table)

#     handle_cast( {:set_timeout, {id, timeout}}, :_, table)

#     {:noreply, table}
#   end

# #   def handle_call({:get_conn, {source_id,_,_}=specs}, _from, {table, auths}) do
# #     reply = with nil <- find_ready( table, specs),

# #                         table
# #                         |> use_auth( specs),

# #                  nil <- find_ready( table, specs) do

# #               {:error, :noconns}

# #             else
# #               tuple -> {:ok, tuple}
# #             end

# #     {:reply, reply, table}
# #   end


# #   def handle_cast({:update_conn, tuple}, {table,_auths}=state) do
# #     update_tuple( table, tuple)

# #     {:noreply, state}
# #   end

# #   # Sync connections for every source:
# #   defp sync_conns( {table, auths}=state, source_id) do
# #     names = names( source_id)

# #     # Connections to given source that
# #     # are in use:
# #     conns = conns( table, source_id)
# #             |> Enum.filter(& &1.__struct__ in names)

# #     # Missed connections:
# #     new_ones = (names -- Enum.map conns, & &1.__struct__)
# #                 |> Enum.flat_map( fn name ->

# #                      Conn.init( struct( name),
# #                                 %{source_id: source_id})
# #                      |> conn_to_tuples( state)
# #                    end)

# #     # Update ETS
# #     replace_conns( table, conns++new_ones, source_id)

# #     state
# #   end


# #   def handle_info(:maintenance, {table, auths}=state) do
# #     sources = Remote.list_sources()
# #               |> Enum.map(& atomize(&1.id))

# #     # Clean up connections to sources that are
# #     # no longer in the DB:
# #     delete( table, fn {{source_id,_,_}, _, _} ->
# #       not source_id in sources
# #     end)

# #     # Recreate invalid connections:
# #     conns( table)
# #     |> Enum.filter(& not Conn.valid?(&1))
# #     |> Enum.map( fn {id,_,_} -> recreate_conn( table, id) end)

# #                                   xchange:
# #     sources
# #     |> Enum.map(& sync_conns( table, &1))

# #     {:noreply, state}
# #   end
end
