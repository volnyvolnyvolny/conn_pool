defmodule Conn.Info do
  @moduledoc false

  @type t :: %__MODULE__{
    conn: Conn.t(),
    init_args: any | [],
    extra: any | nil,
    ttl: pos_integer | :infinity,
    methods: [Conn.method],
    only: [Conn.method] | :all,
    closed: boolean,
    stats: %{required(Conn.method) => {non_neg_integer, pos_integer}},
    last_call: pos_integer | :never,
    last_init: pos_integer | :never,
    timeout: timeout,
    min_timeout: non_neg_integer,
    revive: boolean,
    unsafe: boolean
  }

  @enforce_keys [:conn]
  defstruct [
    :conn,
    :extra,
    :methods,
    init_args: [],
    ttl: :infinity,
    min_timeout: 0,
    only: :all,
    closed: false,
    revive: false,
    stats: %{},
    last_call: :never,
    last_init: :never,
    timeout: 0,
    unsafe: false
  ]
end

defmodule Conn.Pool.Helpers do
  @moduledoc false

  # Current monotonic time.
  def now(), do: System.monotonic_time()

  def to_ms(native) do
    System.convert_time_unit(native, :native, :milliseconds)
  end

  def to_native(ms) do
    System.convert_time_unit(ms, :milliseconds, :native)
  end

  def expired?(%{ttl: :infinity}), do: false

  def expired?(info) do
    info.last_init + to_native(info.ttl) < now()
  end

  # Updates stats info for given method.
  def update_stats(info, method, start) do
    stop = now()

    update_in(info.stats[method], fn
      nil -> {stop - start, 1}
      {avg, num} -> {(avg * num + stop - start) / (num + 1), num + 1}
    end)
  end

  # Generate uniq id.
  def gen_id, do: now()

  # Filtering happend on caller.
  def find(pool, res, filter) do
    pool
    |> AgentMap.get({:res, res}, [])
    |> Stream.filter(fn id ->
      case AgentMap.fetch(pool, {:conn, id}) do
        {:ok, info} ->
          info
          |> Map.from_struct()
          |> filter.()

        _err ->
          false
      end
    end)
  end

  # Calls Conn.methods!/1 and caches results.
  def sync_methods!(info) do
    case Conn.methods!(info.conn) do
      {methods, conn} when is_list(methods) ->
        %{info | methods: methods, conn: conn}

      methods when is_list(methods) ->
        %{info | methods: methods}

      err ->
        raise("""
        Conn.methods!/1 call expected to return [method]
        or {[method], updated conn}, but instead #{inspect(err)} returned.
        """)
    end
  end

  # Deletes conn with given id from pool
  # and returns corr. %Conn.Info{}.
  @spec pop(Conn.Pool.t, Conn.id) :: {:ok, Conn.Info.t} | :error
  def pop(pool, id) do
    info = AgentMap.pop(pool, {:conn, id})

    if info do
      AgentMap.cast(
        pool,
        fn
          [[^id]] ->
            :drop

          [ids] ->
            [List.delete(ids, id)]

          [nil] ->
            :id
        end,
        [{:res, Conn.resource(info.conn)}]
      )
    end

    info
  end

  # Estimates time to wait until call can be made on conn with given id.
  def waiting_time(pool, id) do
    with {:ok, info} <- AgentMap.fetch(pool, {:conn, id}) do
      {sum, n} =
        Enum.reduce(info.stats, {0, 0}, fn {_key, {avg, num}}, {sum, n} ->
          {sum + avg * num, n + num}
        end)

      if n == 0 do
        {:ok, info.timeout}
      else
        {:ok, sum / n * AgentMap.queue_len(pool, {:conn, id}) + info.timeout}
      end
    end
  end

  # Select the best conn.
  def select(pool, resource, method, filter, opts \\ [except: []]) do
    with {:ok, ids} <- filter(pool, resource, method, filter, opts) do
      {:ok, Enum.min_by(ids, &waiting_time(pool, &1))}
    end
  end

#  @spec filter(Conn.Pool.t, Conn.resource, Conn.method, filter)
  # Returns {:ok, ids} | {:error, :resources} | {:error, method}
  # | {:error, filter}.
  def filter(pool, resource, method, filter, except: except) do
    pool = AgentMap.new(pool)
    ids = pool[{:res, resource}] || []
    import Enum

    ids =
    for id <- ids -- except do
      {id, pool[{:conn, id}]}
    end

    with {_, [_ | _] = ids} <- {:r, filter(ids, fn {_, i} -> not i.closed end)},
         {_, [_ | _] = ids} <-
    {:m,
     filter(ids, fn
       {_, %{only: :all} = i} ->
         method in i.methods

       {_, i} ->
         method in i.methods && method in i.only
     end)},
  {_, [_ | _] = ids} <- {:f, filter(ids, fn {_, i} -> filter.(i) end)} do
      {:ok, for({id, _} <- ids, do: id)}
    else
      {:r, []} -> {:error, :resource}
    {:m, []} -> {:error, :method}
      {:f, []} -> {:error, :filter}
    end
  end
end
