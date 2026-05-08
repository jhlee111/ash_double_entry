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

  test "Transaction has :reverses_transaction_id attribute and self belongs_to" do
    attrs =
      AshDoubleEntry.Test.Transaction
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    rels =
      AshDoubleEntry.Test.Transaction
      |> Ash.Resource.Info.relationships()
      |> Enum.map(& &1.name)

    assert :reverses_transaction_id in attrs
    assert :reverses_transaction in rels
  end

  test "Transaction has has_many :entries relationship" do
    rel = AshDoubleEntry.Test.Transaction |> Ash.Resource.Info.relationship(:entries)
    assert rel
    assert rel.type == :has_many
  end

  test "Transaction has primary :read action" do
    assert AshDoubleEntry.Test.Transaction |> Ash.Resource.Info.primary_action(:read)
  end
end
