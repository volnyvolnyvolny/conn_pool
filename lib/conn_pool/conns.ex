defmodule Conns.Lib do

  @doc """
  Initialize and return list of connections for
  given source in order that is given by `Conns.specs/1`
  protocol function.
  """
  @spec init( Conns.source) :: [Conn.t]
  def init( source) do
    Conns.specs( source)
    |> Enum.map( fn {name, args} ->
         Conn.init( struct( name), args ++ [source: source])
       end)
  end
end


defprotocol Conns do
  @moduledoc """
  Conns protocol is needed for .
  """

  @type source :: term
  @type struct_name :: atom


  @doc """
  Return specifiactions list (struct_name + args keyword list)
  for given source in prefered order.

  Connections would be initialized by `&Conn.init/2` function
  as `Conn.init( struct( struct_name), args)`.
  """
  @spec specs( source) :: [{struct_name, keyword}]
  def specs( source)

end
