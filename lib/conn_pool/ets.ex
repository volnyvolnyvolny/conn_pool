defmodule Conns.Pool.ETS do

 #  import BBot.CommonHelpers
 #  import Enum, only: [with_index: 2,
 #                      sort_by: 3,
 #                      uniq: 1,
 #                      map: 2]


 @moduledoc """
  Common functions used in Pool.
  """

 #  # Ready to try again connection?
 #  def can_use?( {id, {next_try,_}, conn}, data_type) do
 #    (DateTime.compare( next_try, now()) in [:lt, :eq])
 #  && can_use?( {id, :noerrors, conn}, data_type)
 #  end

 #  def can_use?( {_, :noerrors, conn}, data_type) do
 #    Conn.state( conn, data_type)
 #  end


 # @doc "Find tuples for which given fun returns true."
 #  def lookup( table, fun) do
 #   :ets.foldl( fn tuple, list ->
 #      if fun.(tuple) do
 #        [tuple|list]
 #      else
 #        list
 #      end
 #    end, [], table)
 #  end


 # @doc "Get all conns from ETS-table."
 #  def conns( table) do
 #    lookup( table, fn _ -> true end)
 #  end


 # @doc "Delete tuples for which given fun returns true."
 #  defp delete( table, fun) do
 #    lookup( table, fun)
 #    |> Enum.map(& :ets.delete_object( table, &1))

 #    table
 #  end


 # @doc "Connections to given source that are in ETS-table."
 #  def conns_to( table, source_id) do
 #    lookup( table, fn {_,_,conn}=tuple ->
 #      source_id == Conn.source_id( conn)
 #    end)
 #  end


 # @doc "Delete connections to given source from ETS-table."
 #  def delete_conns( table, source_id) do
 #    delete( table, fn {_,_,conn} ->
 #      source_id == Conn.source_id( conn)
 #    end)

 #    table
 #  end


 # @doc "Update tuple in ETS table if it's exists."
 #  def update_tuple( table, {id,_,_}=tuple) do
 #    if :ets.member( table, id) do
 #      :ets.insert( table, tuple)
 #    end
 #  end


 # @doc "Get connection by id."
 #  def get_conn!( table, id) do
 #    unless :ets.member( table, id) do
 #      raise "There is no connection with id #{id} in corresponding ETS-table"
 #    end

 #    [tuple] = :ets.lookup( table, id)

 #    tuple
 #  end


 # @doc "Recreate invalid state connection"
 #  def recreate_conn( table, id)
 #    conn = get_conn!( table, id)
 #    same_struct = struct( name( conn))
 #    source_id = source_id( conn)

 #    table
 #    |> update_tuple( {id, :no_errors, Conn.init( same_struct,
 #                                                 %{source_id: source_id})})
 #  end




 # @doc """
 #  Replace all connections to source with a new
 #  ones list.
 #  """
 #  def replace_conns( [], table, source_id) do
 #    delete_conns( table, source_id)
 #  end

 #  def replace_conns( conns, table, source_id \\ nil) do
 #    source_id <~ source_id( conns)

 #    table
 #    |>  delete_conns( source_id)
 #    |> :ets.insert( reorder( conns))

 #    table
 #  end


 #  # Change ids of the given conns list so they are
 #  # in the order that is encoded in DB.
 #  defp reorder( conns, names \\ nil)

 #  defp reorder( [], _names), do: []
 #  defp reorder( conns, names) do
 #    source_id = source_id( conns)

 #    names = names( source_id)

 #    # Order two elements using the order that is
 #    # encoded in the given list.
 #    comp = fn a, b ->
 #             find_index( a, names) <= find_index( b, names)
 #           end

 #    conns
 #    |> sort_by(&name/1, comp)
 #    |> with_index(1)
 #    |> map( fn {{{_, auth_idx, _}, error_status, conn},  new_num} ->
 #         {{source_id, aut_idx, new_num}, error_status, conn}
 #       end)
 #  end


 #  # Names for connections to be used, returned
 #  # in the right order.
 #  defp names( source_id) do
 #    Remote.get_exchange!( to_string( source_id)).conns
 #    |> map(&String.to_atom/1)
 #  end


 #  # Source id of all the conns.
 #  # If there are different sources conns
 #  # in list — raise MatchError.
 #  defp source_id!( conns) do
 #    [source_id] = conns
 #                    |> Enum.map(&conn/1)
 #                    |> Enum.map(&Conn.source_id/1)
 #                    |> Enum.uniq()
 #    source_id
 #  end


 #  # Extract source information from tuple.
 #  defp source_id( {{source_id,_,_}, _, _}) do
 #    source_id
 #  end

 #  # Extract connection from tuple.
 #  defp conn( {_,_,conn}), do: conn
 #  defp conn( conn), do: conn

 #  # Extract struct name from connection tuple or struct.
 #  defp name( conn), do: conn( conn).__struct__
end
