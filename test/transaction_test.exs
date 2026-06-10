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
      %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "108.00")},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "100.00")},
      %{account_id: tax.id, side: :credit, amount: Money.new!(:USD, "8.00")}
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
      %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "100.00")},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "50.00")}
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
      %{account_id: usd.id, side: :debit, amount: Money.new!(:USD, "100.00")},
      %{account_id: eur.id, side: :credit, amount: Money.new!(:EUR, "100.00")}
    ]

    assert {:error, _} =
             Transaction
             |> Ash.Changeset.for_create(:post, %{entries: entries})
             |> Ash.create()
  end

  test "Account.balance_as_of reflects multi-leg Transaction entries" do
    {:ok, cash} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "cash_bal", currency: "USD"})
      |> Ash.create()

    {:ok, revenue} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "revenue_bal", currency: "USD"})
      |> Ash.create()

    entries = [
      %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "50.00")},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "50.00")}
    ]

    {:ok, _t} =
      Transaction
      |> Ash.Changeset.for_create(:post, %{entries: entries})
      |> Ash.create()

    cash = Ash.load!(cash, :balance_as_of)
    revenue = Ash.load!(revenue, :balance_as_of)

    assert Money.equal?(cash.balance_as_of, Money.new!(:USD, "50.00"))
    assert Money.equal?(revenue.balance_as_of, Money.new!(:USD, "-50.00"))
  end

  test "Transaction.reverse creates flipped-side Transaction with reverses_transaction_id" do
    {:ok, cash} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "cash_rev", currency: "USD"})
      |> Ash.create()

    {:ok, revenue} =
      Account
      |> Ash.Changeset.for_create(:open, %{identifier: "revenue_rev", currency: "USD"})
      |> Ash.create()

    entries = [
      %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "100.00")},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "100.00")}
    ]

    {:ok, original} =
      Transaction
      |> Ash.Changeset.for_create(:post, %{entries: entries})
      |> Ash.create()

    {:ok, reversal} =
      Transaction
      |> Ash.Changeset.for_create(:reverse, %{original_transaction_id: original.id})
      |> Ash.create()

    reversal = Ash.load!(reversal, :entries)
    assert reversal.reverses_transaction_id == original.id
    assert length(reversal.entries) == 2

    cash = Ash.load!(cash, :balance_as_of)
    revenue = Ash.load!(revenue, :balance_as_of)
    assert Money.equal?(cash.balance_as_of, Money.new!(:USD, 0))
    assert Money.equal?(revenue.balance_as_of, Money.new!(:USD, 0))
  end

  describe "backdated posting (posted_at → Entry ULIDs)" do
    test "entries of a backdated transaction sort at posted_at, and balance_as_of(posted_at) includes them" do
      {:ok, account_one} =
        Account
        |> Ash.Changeset.for_create(:open, %{identifier: "cash_bd1", currency: "USD"})
        |> Ash.create()

      {:ok, account_two} =
        Account
        |> Ash.Changeset.for_create(:open, %{identifier: "revenue_bd1", currency: "USD"})
        |> Ash.create()

      backdate = DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)

      {:ok, transaction} =
        Transaction
        |> Ash.Changeset.for_create(:post, %{
          entries: [
            %{account_id: account_one.id, side: :debit, amount: Money.new!(:USD, "100.00")},
            %{account_id: account_two.id, side: :credit, amount: Money.new!(:USD, "100.00")}
          ],
          posted_at: backdate
        })
        |> Ash.create()

      transaction = Ash.load!(transaction, :entries)

      for entry <- transaction.entries do
        # The ULID encodes the backdated millisecond, not now: it sorts at-or-before
        # backdate's last ULID and after one second earlier. (The ULID module has no
        # timestamp extractor — ULID ordering IS the contract balance_as_of uses.)
        assert entry.id <= AshDoubleEntry.ULID.generate_last(backdate)
        assert entry.id > AshDoubleEntry.ULID.generate(DateTime.add(backdate, -1, :second))
      end

      # Boundary inclusivity: as-of exactly the backdate includes the entries...
      account_one_at =
        Ash.load!(account_one, balance_as_of: %{timestamp: backdate}).balance_as_of

      assert Money.equal?(account_one_at, Money.new!(:USD, "100.00"))

      # ...and one second before excludes them (zero/default balance).
      balance_before =
        Ash.load!(
          account_one,
          balance_as_of: %{timestamp: DateTime.add(backdate, -1, :second)}
        ).balance_as_of

      assert Money.equal?(balance_before, Money.new!(:USD, 0))
    end

    test "a backdated insert shifts the balances of LATER entries (out-of-order correctness)" do
      {:ok, account_one} =
        Account
        |> Ash.Changeset.for_create(:open, %{identifier: "cash_bd2", currency: "USD"})
        |> Ash.create()

      {:ok, account_two} =
        Account
        |> Ash.Changeset.for_create(:open, %{identifier: "revenue_bd2", currency: "USD"})
        |> Ash.create()

      {:ok, _now_txn} =
        Transaction
        |> Ash.Changeset.for_create(:post, %{
          entries: [
            %{account_id: account_one.id, side: :debit, amount: Money.new!(:USD, "50.00")},
            %{account_id: account_two.id, side: :credit, amount: Money.new!(:USD, "50.00")}
          ]
        })
        |> Ash.create()

      yesterday = DateTime.add(DateTime.utc_now(), -1 * 24 * 60 * 60, :second)

      {:ok, _backdated_txn} =
        Transaction
        |> Ash.Changeset.for_create(:post, %{
          entries: [
            %{account_id: account_one.id, side: :debit, amount: Money.new!(:USD, "100.00")},
            %{account_id: account_two.id, side: :credit, amount: Money.new!(:USD, "100.00")}
          ],
          posted_at: yesterday
        })
        |> Ash.create()

      # The later (now-dated) balance row was shifted by the backdated insert.
      at_now =
        Ash.load!(account_one, balance_as_of: %{timestamp: DateTime.utc_now()}).balance_as_of

      assert Money.equal?(at_now, Money.new!(:USD, "150.00"))

      at_yesterday =
        Ash.load!(account_one, balance_as_of: %{timestamp: yesterday}).balance_as_of

      assert Money.equal?(at_yesterday, Money.new!(:USD, "100.00"))
    end
  end
end
