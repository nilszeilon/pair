defmodule Pair.Counter do
  @moduledoc """
  Incremental session ID counter. Returns zero-padded 3-digit IDs: 001, 002, ...
  """
  use GenServer

  @table :pair_counter

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def next do
    n = :ets.update_counter(@table, :next, {2, 1})
    n |> Integer.to_string() |> String.pad_leading(3, "0")
  end

  @impl true
  def init(_) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, {:next, 1})
    end
    {:ok, %{}}
  end
end
