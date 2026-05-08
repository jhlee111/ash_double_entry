defmodule AshDoubleEntry.TransactionTest do
  use DataCase, async: false
  alias AshDoubleEntry.Test.{Account, Transaction}

  test "balanced 3-leg Transaction posts successfully" do
    {:ok, cash} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "cash_t1", currency: "USD"})
      |> Ash.create()

    {:ok, revenue} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "revenue_t1", currency: "USD"})
      |> Ash.create()

    {:ok, tax} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "tax_t1", currency: "USD"})
      |> Ash.create()

    entries = [
      %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, 108_00)},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, 100_00)},
      %{account_id: tax.id, side: :credit, amount: Money.new!(:USD, 8_00)}
    ]

    {:ok, transaction} =
      Transaction
      |> Ash.Changeset.for_create(:post, %{entries: entries})
      |> Ash.create()

    transaction = Ash.load!(transaction, :entries)
    assert length(transaction.entries) == 3
  end

  test "unbalanced Transaction is rejected" do
    {:ok, cash} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "cash_t2", currency: "USD"})
      |> Ash.create()

    {:ok, revenue} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "revenue_t2", currency: "USD"})
      |> Ash.create()

    entries = [
      %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, 100_00)},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, 50_00)}
    ]

    assert {:error, _} =
             Transaction
             |> Ash.Changeset.for_create(:post, %{entries: entries})
             |> Ash.create()
  end

  test "mixed-currency Transaction is rejected" do
    {:ok, usd} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "usd_t3", currency: "USD"})
      |> Ash.create()

    {:ok, eur} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "eur_t3", currency: "EUR"})
      |> Ash.create()

    entries = [
      %{account_id: usd.id, side: :debit, amount: Money.new!(:USD, 100_00)},
      %{account_id: eur.id, side: :credit, amount: Money.new!(:EUR, 100_00)}
    ]

    assert {:error, _} =
             Transaction
             |> Ash.Changeset.for_create(:post, %{entries: entries})
             |> Ash.create()
  end
end
