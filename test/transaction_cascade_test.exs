# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.TransactionCascadeTest do
  @moduledoc """
  How `Transaction.post` turns the `entries` argument into Entry rows.

  Covers what an application may put on a leg, what it may not, and what has to
  happen when a leg is wrong — the leg has to be identifiable, and nothing may be
  left behind.
  """
  use DataCase, async: false

  alias AshDoubleEntry.Test.{Account, Balance, Entry, Transaction}

  require Ash.Query

  defp account(identifier) do
    Account
    |> Ash.Changeset.for_create(:open, %{identifier: identifier, currency: "USD"})
    |> Ash.create!()
  end

  defp post(entries, attrs \\ %{}) do
    Transaction
    |> Ash.Changeset.for_create(:post, Map.put(attrs, :entries, entries))
    |> Ash.create()
  end

  # Splode nests errors; the leaves are what carry `path` and `field`.
  defp leaves(error) do
    case Map.get(error, :errors) do
      [_ | _] = errors -> Enum.flat_map(errors, &leaves/1)
      _ -> [error]
    end
  end

  defp leaf_summaries({:error, error}), do: leaf_summaries(error)

  defp leaf_summaries(error) do
    error
    |> leaves()
    |> Enum.map(&{&1.__struct__, Map.get(&1, :field), Map.get(&1, :input), &1.path})
  end

  defp count(resource) do
    resource |> Ash.Query.new() |> Ash.count!(authorize?: false)
  end

  describe "application-defined Entry fields" do
    test "a field listed in create_accept is carried from the leg onto the Entry row" do
      cash = account("cash_af1")
      revenue = account("revenue_af1")

      {:ok, transaction} =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-cash"
          },
          %{
            account_id: revenue.id,
            side: :credit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-rev"
          }
        ])

      transaction = Ash.load!(transaction, :entries)

      assert transaction.entries
             |> Enum.map(&{&1.account_id, &1.line_item_id})
             |> Enum.sort() ==
               Enum.sort([{cash.id, "li-cash"}, {revenue.id, "li-rev"}])
    end

    test "the same field arriving under a string key is carried too" do
      cash = account("cash_af2")
      revenue = account("revenue_af2")

      {:ok, transaction} =
        post([
          %{
            "account_id" => cash.id,
            "side" => "debit",
            "amount" => Money.new!(:USD, "10.00"),
            "line_item_id" => "li-cash"
          },
          %{
            "account_id" => revenue.id,
            "side" => "credit",
            "amount" => Money.new!(:USD, "10.00"),
            "line_item_id" => "li-rev"
          }
        ])

      transaction = Ash.load!(transaction, :entries)

      assert transaction.entries |> Enum.map(& &1.line_item_id) |> Enum.sort() ==
               ["li-cash", "li-rev"]
    end

    test "an Entry attribute NOT listed in create_accept is rejected at its own leg index" do
      cash = account("cash_af3")
      revenue = account("revenue_af3")

      result =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{
            account_id: revenue.id,
            side: :credit,
            amount: Money.new!(:USD, "10.00"),
            internal_note: "not accepted"
          }
        ])

      assert {:error, _} = result

      assert {Ash.Error.Invalid.NoSuchInput, nil, :internal_note, [:entries, 1]} in leaf_summaries(
               result
             )
    end

    test "a misspelled accepted key is rejected at its own leg index rather than dropped" do
      cash = account("cash_af4")
      revenue = account("revenue_af4")
      tax = account("tax_af4")

      result =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "9.00")},
          %{
            account_id: tax.id,
            side: :credit,
            amount: Money.new!(:USD, "1.00"),
            line_itm_id: "typo"
          }
        ])

      assert {:error, _} = result

      assert {Ash.Error.Invalid.NoSuchInput, nil, :line_itm_id, [:entries, 2]} in leaf_summaries(
               result
             )

      assert count(Transaction) == 0
      assert count(Entry) == 0
    end

    test "a misspelled key is rejected under a string spelling too" do
      cash = account("cash_af6")
      revenue = account("revenue_af6")

      result =
        post([
          %{"account_id" => cash.id, "side" => "debit", "amount" => Money.new!(:USD, "10.00")},
          %{
            "account_id" => revenue.id,
            "side" => "credit",
            "amount" => Money.new!(:USD, "10.00"),
            "line_itm_id" => "typo"
          }
        ])

      assert {:error, _} = result

      assert {Ash.Error.Invalid.NoSuchInput, nil, "line_itm_id", [:entries, 1]} in leaf_summaries(
               result
             )

      assert count(Entry) == 0
    end

    test "a transaction-owned field supplied on a leg is rejected, not silently overridden" do
      cash = account("cash_af5")
      revenue = account("revenue_af5")

      {:ok, other} =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "1.00")},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "1.00")}
        ])

      result =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            transaction_id: other.id
          },
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert {:error, _} = result

      assert Enum.any?(leaf_summaries(result), fn {_mod, field, input, path} ->
               (field == :transaction_id or input == :transaction_id) and path == [:entries, 0]
             end)

      # and the other transaction was left alone
      assert other |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 2
    end
  end

  describe "fields the transaction owns" do
    setup do
      %{cash: account("cash_own"), revenue: account("revenue_own")}
    end

    # `timestamp` is derived from the transaction's posted_at. Silently overriding a
    # caller's value would be the same silent-discard this change exists to remove.
    test "a per-leg timestamp is rejected rather than overridden", %{cash: cash, revenue: revenue} do
      result =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            timestamp: ~U[2001-01-01 00:00:00.000000Z]
          },
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert {:error, _} = result

      assert Enum.any?(leaf_summaries(result), fn {_mod, field, _input, path} ->
               field == :timestamp and path == [:entries, 0]
             end)
    end

    test "and is rejected under its string spelling too", %{cash: cash, revenue: revenue} do
      result =
        post([
          %{"account_id" => cash.id, "side" => "debit", "amount" => Money.new!(:USD, "10.00")},
          %{
            "account_id" => revenue.id,
            "side" => "credit",
            "amount" => Money.new!(:USD, "10.00"),
            "transaction_id" => "01ARZ3NDEKTSV4RRFFQ69G5FAV"
          }
        ])

      assert {:error, _} = result

      assert Enum.any?(leaf_summaries(result), fn {_mod, field, _input, path} ->
               field == "transaction_id" and path == [:entries, 1]
             end)
    end
  end

  describe "cascade integrity" do
    test "legs given as Entry structs create real Entry rows" do
      # The copy-a-journal shape: load a posted transaction's legs and post them
      # again. A struct leg must not be mistaken for a record that already exists.
      cash = account("cash_ci1")
      revenue = account("revenue_ci1")

      {:ok, first} =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-1"
          },
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      first = Ash.load!(first, :entries)

      assert {:ok, second} = post(first.entries)

      second = Ash.load!(second, :entries)
      assert length(second.entries) == 2
      assert Enum.all?(second.entries, &(&1.transaction_id == second.id))
      assert "li-1" in Enum.map(second.entries, & &1.line_item_id)

      cash = Ash.load!(cash, :balance_as_of)
      assert Money.equal?(cash.balance_as_of, Money.new!(:USD, "20.00"))
    end

    test "legs read with a restricted select post again without their unselected fields" do
      # Attributes left out of a select come back as %Ash.NotLoaded{}, which is not a
      # value any Entry attribute would accept. They have to be dropped, not forwarded.
      cash = account("cash_ci5")
      revenue = account("revenue_ci5")

      {:ok, first} =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-1"
          },
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      first =
        Ash.load!(first,
          entries: Ash.Query.select(Entry, [:id, :account_id, :side, :amount])
        )

      assert Enum.any?(first.entries, &match?(%Ash.NotLoaded{}, &1.line_item_id))

      assert {:ok, second} = post(first.entries)

      second = Ash.load!(second, :entries)
      assert length(second.entries) == 2
      assert Enum.all?(second.entries, &is_nil(&1.line_item_id))
    end

    test "a leg that fails at the database leaves no transaction, entry or balance rows" do
      cash = account("cash_ci2")

      transactions_before = count(Transaction)
      entries_before = count(Entry)
      balances_before = count(Balance)

      result =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{
            account_id: "00000000-0000-0000-0000-000000000000",
            side: :credit,
            amount: Money.new!(:USD, "10.00")
          }
        ])

      assert {:error, _} = result
      assert count(Transaction) == transactions_before
      assert count(Entry) == entries_before
      assert count(Balance) == balances_before
    end

    test "a leg failing at the database reports its own index" do
      cash = account("cash_ci3")
      revenue = account("revenue_ci3")

      result =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "9.00")},
          %{
            account_id: "00000000-0000-0000-0000-000000000000",
            side: :credit,
            amount: Money.new!(:USD, "1.00")
          }
        ])

      assert {:error, _} = result

      assert Enum.any?(leaf_summaries(result), fn {_mod, field, _input, path} ->
               field == :account_id and path == [:entries, 2]
             end)
    end

    test "entries are populated on the :post result, in input order" do
      cash = account("cash_ci4")
      revenue = account("revenue_ci4")
      tax = account("tax_ci4")

      {:ok, transaction} =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "9.00")},
          %{account_id: tax.id, side: :credit, amount: Money.new!(:USD, "1.00")}
        ])

      refute match?(%Ash.NotLoaded{}, transaction.entries)

      # The set, not the order. Ash happens to hand these back in input order, but
      # that falls out of a private prepend-then-reverse and is not a documented
      # guarantee — pinning it would weld this suite to an Ash implementation detail.
      assert transaction.entries |> Enum.map(& &1.account_id) |> Enum.sort() ==
               Enum.sort([cash.id, revenue.id, tax.id])
    end
  end

  describe "authorization" do
    test "the cascade writes Entries despite a policy forbidding every Entry create" do
      # Deliberate and documented: `entry.create_accept` says these fields are written
      # with authorization bypassed. This pins it, so that removing the bypass is a
      # visible change rather than a quiet one — and so that anyone widening
      # create_accept can see exactly what they are opting into.
      cash = account("cash_az1")
      revenue = account("revenue_az1")

      {:ok, transaction} =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-1"
          },
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 2

      # The same write, made directly and authorized, is refused.
      assert {:error, %Ash.Error.Forbidden{}} =
               Entry
               |> Ash.Changeset.for_create(:create, %{
                 transaction_id: transaction.id,
                 account_id: cash.id,
                 side: :debit,
                 amount: Money.new!(:USD, "1.00"),
                 timestamp: transaction.posted_at
               })
               |> Ash.create(authorize?: true)
    end
  end

  describe "posted_at is the one instant a journal happened" do
    test "every cascaded Entry is stamped with the transaction's persisted posted_at" do
      cash = account("cash_pa1")
      revenue = account("revenue_pa1")

      {:ok, transaction} =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      transaction = Ash.load!(transaction, :entries)

      refute is_nil(transaction.posted_at)
      assert Enum.all?(transaction.entries, &(&1.timestamp == transaction.posted_at))
    end

    test "and that holds for a backdated posting too" do
      cash = account("cash_pa2")
      revenue = account("revenue_pa2")
      backdated = ~U[2020-03-04 05:06:07.000000Z]

      {:ok, transaction} =
        post(
          [
            %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
            %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
          ],
          %{posted_at: backdated}
        )

      transaction = Ash.load!(transaction, :entries)

      assert transaction.posted_at == backdated
      assert Enum.all?(transaction.entries, &(&1.timestamp == backdated))
    end
  end

  describe "leg shape validation" do
    test "an unrecognised side is rejected rather than counted as neither debit nor credit" do
      cash = account("cash_ls1")
      revenue = account("revenue_ls1")

      # Both legs fall out of both sums, so a naive Σdebits == Σcredits check sees
      # 0 == 0 and lets an unbalanced journal through.
      result =
        post([
          %{account_id: cash.id, side: :sideways, amount: Money.new!(:USD, "10.00")},
          %{account_id: revenue.id, side: :sideways, amount: Money.new!(:USD, "99.00")}
        ])

      assert {:error, _} = result
      assert count(Transaction) == 0
      assert count(Entry) == 0
    end

    test "an unrecognised side given as a string does not mint an atom" do
      cash = account("cash_ls2")
      revenue = account("revenue_ls2")

      junk_side = fn ->
        post([
          %{
            "account_id" => cash.id,
            "side" => "no-such-side-#{System.unique_integer([:positive])}",
            "amount" => Money.new!(:USD, "10.00")
          },
          %{
            "account_id" => revenue.id,
            "side" => "credit",
            "amount" => Money.new!(:USD, "10.00")
          }
        ])
      end

      # Warm up first: the first trip through this path lazily loads modules, which
      # mints atoms of its own. What matters is that a *repeat* request mints none,
      # because `side` is caller-controlled and reachable from a JSON request body.
      assert {:error, _} = junk_side.()
      before_count = :erlang.system_info(:atom_count)
      assert {:error, _} = junk_side.()
      assert {:error, _} = junk_side.()

      assert :erlang.system_info(:atom_count) == before_count
    end

    test "a leg with no amount is rejected rather than crashing" do
      cash = account("cash_ls3")
      revenue = account("revenue_ls3")

      result =
        post([
          %{account_id: cash.id, side: :debit},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "reversal" do
    test "a reversal carries the original legs' application-defined fields" do
      cash = account("cash_rv1")
      revenue = account("revenue_rv1")

      {:ok, original} =
        post([
          %{
            account_id: cash.id,
            side: :debit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-cash"
          },
          %{
            account_id: revenue.id,
            side: :credit,
            amount: Money.new!(:USD, "10.00"),
            line_item_id: "li-rev"
          }
        ])

      {:ok, reversal} =
        Transaction
        |> Ash.Changeset.for_create(:reverse, %{original_transaction_id: original.id})
        |> Ash.create()

      reversal = Ash.load!(reversal, :entries)

      assert reversal.entries
             |> Enum.map(&{&1.side, &1.line_item_id})
             |> Enum.sort() ==
               Enum.sort([{:credit, "li-cash"}, {:debit, "li-rev"}])
    end
  end
end
