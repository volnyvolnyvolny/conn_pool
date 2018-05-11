defmodule X do
  defstruct []

  defimpl Conn do
    use Conn.Defaults

    def resource(_conn), do: :re
    def methods!(_conn), do: []

    def call(conn, method, nil) do
      call(conn, method, [])
    end

    def call(_conn, _method, payload) do
      payload
    end
  end
end
