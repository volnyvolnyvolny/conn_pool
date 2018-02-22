defmodule Conns.Lib do

  @doc """
  Initialize and return list of connections for
  given source in order that is given by `Conns.specs/1`
  protocol function.
  """
  @spec init(Conns.source) :: [Conn.t]
  def init(source) do
    Conns.specs(source)
    |> Enum.map( fn {name, args} ->
         Conn.init( struct( name), args ++ [resource: resource])
       end)
  end
end


defprotocol Conns do
  @moduledoc """
  Conn spec is a tuple that can be used to create connection using `Conn.init/2`
  function.

  List of initialized connections can be created using `Conns.init/1` function.
  For this need `Conns` protocol should be implemented for this source.
  """

  @type source :: term
  @type struct_name :: atom


  defdelegate init( source), to: Conns.Lib


  @doc """
  Return specification list (struct_name + args keyword list)
  in prefered order for given source.

  Connections would be initialized by `Conn.init/2` function
  using `Conn.init( struct( struct_name), args)` formula.
  """
  @spec specs( source) :: [{struct_name, keyword}]
  def specs( source)

end
