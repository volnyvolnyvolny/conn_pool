defmodule Conn.HTTP do
  @moduledoc """
  This module represents HTTP-connection. It's a simple wrapper around HTTPoison.

  To initialize, use `Conn.init/2` method:

      Conn.init(%Conn.HTTP{}, res: "http://archlinux.mirror.ba/lastupdate",
                              mirrors: ["http://ftp.fau.de/archlinux/lastupdate",
                                        "http://mirror.hactar.xyz/lastupdate"])


  Call is made via `Conn.call/3` method:

      Conn.call(conn, :get, body: "", headers: [], follow_redirect: true)
  """
  defstruct [:res, :mirrors]
end

defimpl Conn, for: Conn.HTTP do
  def init(conn, init_args) do
    url = init_args[:res]

    if url do
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
    case HTTPoison.request(method, r, params[:body] || "", params[:headers] || [], params) do
      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        {:reply, ref, conn}

      {:ok, %HTTPoison.Response{status_code: 200} = resp} ->
        {:reply, resp, conn}

      {:ok, resp} ->
        case conn.mirrors do
          [] ->
            {:reply, resp, conn}

          [m | ms] ->
            case call(%{conn | mirrors: ms, res: m}, method, params) do
              {:reply, resp, conn} ->
                {:reply, resp, %{conn | mirrors: [r | ms]}}

              {:error, reason, conn} ->
                {:error, reason, %{conn | mirrors: [r | ms]}}
            end
        end

      {:error, %HTTPoison.Error{reason: r}} ->
        {:error, r, conn}
    end
  end

  def call(_conn, _, _), do: {:error, :notsupported}
end
