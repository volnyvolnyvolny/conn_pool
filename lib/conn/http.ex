defmodule(Conn.HTTP, do: defstruct([:res, :mirrors]))

defimpl Conn, for: Conn.HTTP do
  def init(conn, init_args) do
    url = init_args[:res]

    if res do
      mirrors = init_args[:mirrors] || []
      {:ok, %Conn.HTTP{res: url, mirrors: mirrors}}
    else
      {:error, :nores, conn}
    end
  end

  def resource(%_{res: url}), do: url

  def parse(_conn, _data), do: {:error, :notimplemented}

  def methods!(_conn), do: [:get, :post]

  def call(conn, method, params \\ [])

  def call(%_{res: r} = conn, method, params)
      when method in [:get, :head, :post, :put, :delete, :options, :patch] do
    case HTTPoison.request(method, r, params[:body], params[:headers], params[:options]) do
      {:ok, %HTTPoison.AsyncResponse{id: reference}} ->
        {:reply, reference, conn}

      {:ok, %HTTPoison.Response{status_code: 404} = resp} ->
        case conn.mirrors do
          [] ->
            {:error, 404}

          [m | ms] ->
            case call(%{conn | mirrors: ms, res: m}, method, params) do
              
            end
        end

        {:reply, resp, conn}

      {:error, %HTTPoison.Error{reason: r}} ->
        {:error, r, conn}
    end
  end

  def call(_conn, _, _) do
    {:error, :notsupported}
  end
end
