# Changelog for Conn.Pool v0.3.0

## v0.3.0

### 1. Enhancements

#### Conn.HTTP

  * Docs added
  * Doctests added
  * `:args` opt could be provided in `Conn.call/3` to make calls like

      {:ok, conn} =
        Conn.init(%Conn.HTTP{}, res: :search,
                                url: &"https://goooogel.com?q=\#{&1}",
                                mirror: &"https://duckduckgo.com/?q=\#{&1}")
      {:reply, resp, ^conn} =
        Conn.call(conn, :get, args: ["follow the white rabbit"], follow_redirect: true)

      resp.body =~ "follow"
      resp.body =~ "duck"

  * `init_args[:mirror]` added to `Conn.init/2` as an option
  * `init_args[:url]` added to `%Conn.HTTP{}` struct. If `init_args[:res]` opt
    is not given in `Conn.init/2`, it is copied from `init_args[:res]` and
    vice versa
  * a few cases in `Conn.init/2` added where this call raise

#### Conn

  * from now on default `init_args` in `Conn.init/2` are `[]`

#### Conn.Pool

  * from now on default `init_args` in `Conn.Pool.init/2` are `[]`
  * `Conn.init/2` can safely raise now. Pool interpret this as `Conn.init/2`
  returns `{:error, {:exist, reason}, conn}`
