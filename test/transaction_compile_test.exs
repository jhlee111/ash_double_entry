defmodule AshDoubleEntry.TransactionCompileTest do
  use ExUnit.Case, async: true

  test "a resource using AshDoubleEntry.Transaction compiles" do
    Code.ensure_compiled(AshDoubleEntry.Test.Transaction)

    assert AshDoubleEntry.Test.Transaction.module_info(:module) ==
             AshDoubleEntry.Test.Transaction
  end
end
