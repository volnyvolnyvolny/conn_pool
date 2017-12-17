defmodule Conns.Pool.Server do
  use GenServer

  @moduledoc """
  GenServer back end for connections pool.
  """

  import Conns.Pool.ETS
  import NaiveDateTime

#   import Enum, only: [map: 2]

  @name System.get_env("POOL_NAME") || :"Conns.Pool"


  @doc """
  GenServer name for given id.
  """
  def name( pool_id) do
   :"#{@name}#{if pool_id do "."<>to_string( pool_id) end}"
  end


  @doc "Initialize ETS table."
  def init(_pool_id) do
    :rand.seed(:exsp)

    {:ok, {:ets.new(:_, [:ordered_set, :private]), []}}
  end

  @doc "Start pool server."
  def start_link( pool_id \\ nil) do
    GenServer.start_link(__MODULE__, pool_id, name: name( pool_id))
  end



#   # Given spec match tuple?
#   defp match_spec( {_,_,conn}=tuple, {source_id, data_type, auth}) do
#      data_type in Conn.data_types( conn)
#   && source_id == Conn.source_id( conn)
#   && auth in [:_, Conn.auth( conn)]
#   end




#  @doc "Add auth to ETS."
#   def add_auth!( {table, auths}=state, auth, source_id) do
#     require Kernel

#     unless find_index( auths, auth) do

#       {auths, idx} = if idx = find_index( auths, &Kernel.!/1) do
#                        {List.replace_at( auths, idx, nil), idx}
#                      else
#                        {auths++[auth], length( auths)}
#                      end

#       lookup( table, fn {{conn_source_id,_,conn}, _, _} ->
#                         conn_source_id == source_id,
#                      && Conn.auth( conn) != :is_not_supported
#       end)
#       |> Enum.map( fn tuple ->
#            conn = Conn.init( struct( name( tuple)),
#                              %{source_id: source_id})

#            {{source_id, idx, :_}, :noerrors, conn}
#          end)
#       |> Enum.concat( get_conns( table, source_id))
#       |> replace_conns( table, source_id)

#       {table, auths}
#     else
#       raise "Cannot add auth that is already in list!"
#     end
#   end


#  @doc "Delete auth from ETS."
#   def delete_auth!( {table, auths}=state, auth) do

#     if idx = find_index auths, auth do
#       delete( table, fn {{_,auth_idx,_}, _, _} ->
#         auth_idx == idx
#       end)

#       {table, List.replace_at( auths, idx, nil)}
#     else
#       raise "Cannot delete auth that is not there!"
#     end
#   end

#   # Find first tuple with conn ready for use and
#   # all the conditions are stand.
#   defp find_ready( table, {_source_id, data_type,_auth}=spec) do
#    :ets.foldl( fn {_,_,conn}=tuple, acc ->

#       acc || if match_spec?( tuple, spec)
#              && ready_for_use?( tuple, data_type) do

#                tuple
#              end
#     end, nil, table)
#   end

  # Generate uniq id.
  defp gen_id( table) do
    if :ets.member( table, id = :rand.uniform( 1000000000000)) do
      gen_id( table)
    else
      id
    end
  end


#   #———————————————————————————————————————————————————————————

  def handle_call( {:get, id}, _from, table) do
    {:reply,
     case :ets.lookup( table, id) do
       [{^id, nil, conn}] -> conn
       [{^id, {:next_try, next_try}, conn}] ->
         if (compare( next_try, utc_now()) in [:lt, :eq]) do
           conn
         else
           {:error, {:timeout, diff( next_try, utc_now(), :microseconds)}}
         end
       [] -> {:error, :not_found}
     end,
     table}
  end


  def handle_call( {:take, id}, from, table) do
    with {:ok, _conn} <- handle_call( {:get, id}, from, table) do
     :ets.delete( table, id)
    end
  end


  def handle_call( {:put, conn}, _from, table) do
    id = gen_id( table)
    :ets.insert( table, {id, nil, conn})

    {:reply, id, table}
  end

  def handle_call( {:update_conn, {id, conn}}, _from, table) do
    case :ets.lookup( table, id) do
      [{^id, timeout, _conn}] -> :ets.insert( table, {id, timeout, conn})
      [] -> :ets.insert( table, {id, nil, conn})
    end

    {:reply, conn, table}
  end


  def handle_call( {:lookup, {source, int_type_s, filter}}, _from, table) do

    :ets.foldl( fn {id, timeout, conn}, list ->
      timeout = case timeout do
                  nil -> 0
                  {:next_try, :never} -> :infinity
                  {:next_try, next_try} -> diff( next_try, utc_now(), :microseconds)
                end

      timeout = if timeout < 0 do 0 else timeout end

      with :cannot <- Conn.state( conn) do
        list
      else
       :invalid                 -> [{id, :invalid} | list]
       :ready                   -> [{id, timeout, conn} | list]
       {:timeout, conn_timeout} -> [{id, max( timeout, conn_timeout), conn} | list]
       :needauth                -> [{id, :needauth, conn} | list]
       {:needauth, {:timeout, conn_timeout}} -> [{id, :needauth, conn} | list]
      end
     
      state = with {:timeout, timeout} <- Conn.state( conn) do
                timeout
              else
                :invalid -> :invalid
                _ -> 
              end || 0
      

      if filter.(conn) do
        [{id, case timeout do
                nil -> {id, 0, conn}
                {:next_try, :never} -> [{id, :infinity, conn} | list]
                {:} -> [{id, 0, conn} | list]
         end, conn} | list]
      else
        list
      end
    end, [], table)

    
    case :ets.lookup( table, id) do
      [{^id, timeout, _conn}] -> :ets.insert( table, {id, timeout, conn})
      [] -> :ets.insert( table, {id, nil, conn})
    end

    {:reply, conn, table}
  end


  def handle_cast( {:set_timeout, {id, timeout}}, _from, table) do
    next_try = if timeout == :infinity do
                :never
               else
                 add( utc_now(), timeout, :microseconds)
               end

    with [{id,_timeout, conn}] <- :ets.lookup( table, id) do
     :ets.insert( table, {id, {:next_try, next_try}, conn})
    end

    {:noreply, table}
  end

  def handle_cast( {:put_with_timeout, {conn, timeout}}, _from, table) do
    {_,id,_} = handle_call( {:put, conn}, :_, table)

    handle_cast( {:set_timeout, {id, timeout}}, :_, table)

    {:noreply, table}
  end

#   def handle_call({:get_conn, {source_id,_,_}=specs}, _from, {table, auths}) do
#     reply = with nil <- find_ready( table, specs),

#                         table
#                         |> use_auth( specs),

#                  nil <- find_ready( table, specs) do

#               {:error, :noconns}

#             else
#               tuple -> {:ok, tuple}
#             end

#     {:reply, reply, table}
#   end


#   def handle_cast({:update_conn, tuple}, {table,_auths}=state) do
#     update_tuple( table, tuple)

#     {:noreply, state}
#   end

#   # Sync connections for every source:
#   defp sync_conns( {table, auths}=state, source_id) do
#     names = names( source_id)

#     # Connections to given source that
#     # are in use:
#     conns = conns( table, source_id)
#             |> Enum.filter(& &1.__struct__ in names)

#     # Missed connections:
#     new_ones = (names -- Enum.map conns, & &1.__struct__)
#                 |> Enum.flat_map( fn name ->

#                      Conn.init( struct( name),
#                                 %{source_id: source_id})
#                      |> conn_to_tuples( state)
#                    end)

#     # Update ETS
#     replace_conns( table, conns++new_ones, source_id)

#     state
#   end


#   def handle_info(:maintenance, {table, auths}=state) do
#     sources = Remote.list_sources()
#               |> Enum.map(& atomize(&1.id))

#     # Clean up connections to sources that are
#     # no longer in the DB:
#     delete( table, fn {{source_id,_,_}, _, _} ->
#       not source_id in sources
#     end)

#     # Recreate invalid connections:
#     conns( table)
#     |> Enum.filter(& not Conn.valid?(&1))
#     |> Enum.map( fn {id,_,_} -> recreate_conn( table, id) end)

#                                   xchange:
#     sources
#     |> Enum.map(& sync_conns( table, &1))

#     {:noreply, state}
#   end
end
