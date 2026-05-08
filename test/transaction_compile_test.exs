defmodule AshDoubleEntry.TransactionCompileTest do
  use ExUnit.Case, async: true

  test "a resource using AshDoubleEntry.Transaction compiles" do
    Code.ensure_compiled(AshDoubleEntry.Test.Transaction)

    assert AshDoubleEntry.Test.Transaction.module_info(:module) ==
             AshDoubleEntry.Test.Transaction
  end

  test "Transaction has :id, :posted_at, :inserted_at attributes" do
    attrs =
      AshDoubleEntry.Test.Transaction
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert MapSet.member?(attrs, :id)
    assert MapSet.member?(attrs, :posted_at)
    assert MapSet.member?(attrs, :inserted_at)
  end
end
