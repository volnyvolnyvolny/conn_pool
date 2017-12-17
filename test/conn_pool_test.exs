defmodule ConnPoolTest do
  use ExUnit.Case
  doctest ConnPool

  test "greets the world" do
    assert ConnPool.hello() == :world
  end
end
