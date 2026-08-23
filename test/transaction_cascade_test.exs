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

  describe "a leg's currency must match its account's (#5)" do
    test "a mismatch is a validation error at the leg's own index, and nothing is written", ctx do
      _ = ctx
      cash = account("cash_cur1")
      revenue = account("revenue_cur1")

      # Both legs agree with EACH OTHER (EUR), so the journal's own currency
      # check passes — it is the accounts (USD) they disagree with. Before this
      # fix that surfaced from deep inside VerifyEntry as Ash.Error.Unknown
      # wrapping Money.add!'s ArgumentError, with no leg index.
      result =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:EUR, "10.00")},
          %{account_id: revenue.id, side: :credit, amount: Money.new!(:EUR, "10.00")}
        ])

      assert {:error, %Ash.Error.Invalid{}} = result

      assert Enum.any?(leaf_summaries(result), fn {_mod, field, _input, path} ->
               field == :amount and path == [:entries, 0]
             end),
             "expected a leaf at [:entries, 0] on :amount; got #{inspect(leaf_summaries(result))}"

      assert count(Transaction) == 0
      assert count(Entry) == 0
    end
  end

  describe "accounts are locked up front, in one statement, in id order (#4)" do
    # A live deadlock cannot be a valid red here: the test sandbox shares one
    # connection, so two concurrent posts never contend for row locks. What CAN
    # be pinned deterministically is the mechanism VerifyTransfer already uses —
    # one `FOR UPDATE` over every account the journal touches, ordered, issued
    # before any Entry exists — by watching the repo's query telemetry.
    setup do
      handler = "lock-order-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_double_entry, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _ -> send(test_pid, {:sql, query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp drain_sql(acc \\ []) do
      receive do
        {:sql, q} -> drain_sql([q | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "the first FOR UPDATE precedes the first entries insert, is ordered, and covers all legs",
         ctx do
      _ = ctx
      # Three accounts referenced in an order that is NOT id order.
      accounts = Enum.map(1..3, &account("lock_#{&1}"))
      [a, b, c] = Enum.sort_by(accounts, & &1.id, :desc)

      drain_sql()

      {:ok, _} =
        post([
          %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "30.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "20.00")},
          %{account_id: c.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      sql = drain_sql()

      first_lock = Enum.find_index(sql, &String.contains?(&1, "FOR UPDATE"))
      first_entry_insert = Enum.find_index(sql, &String.contains?(&1, ~s(INSERT INTO "entries")))

      assert first_lock, "no FOR UPDATE query was issued at all"
      assert first_entry_insert, "no entries insert was observed"

      assert first_lock < first_entry_insert,
             "the first account lock came AFTER the first entry insert — locks are per leg, not up front"

      lock = Enum.at(sql, first_lock)
      assert lock =~ "ORDER BY", "the up-front lock is not ordered: #{lock}"

      assert lock =~ ~r/= ANY\(|IN \(/,
             "the up-front lock is not a single batched statement: #{lock}"
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

  describe "the up-front lock runs in the caller's context (#4 follow-up)" do
    alias AshDoubleEntry.Test.{TenantAccount, TenantEntry, TenantTransaction}

    # `VerifyTransfer` and `VerifyEntry` both build their `:lock_accounts` read with
    # `Ash.Context.to_opts(context, ...)`, which carries the tenant (and the actor and
    # tracer) into the extension's own reads. A multitenant consumer is entitled to
    # the same from the up-front lock: without the tenant, Ash refuses the read
    # outright and the multi-leg feature is simply unavailable to that application.
    test "a journal posts under attribute multitenancy, every cascaded Entry in the caller's tenant" do
      org = Ash.UUID.generate()

      [cash, revenue] =
        for identifier <- ["tenant_cash", "tenant_revenue"] do
          TenantAccount
          |> Ash.Changeset.for_create(:open, %{identifier: identifier, currency: "USD"},
            tenant: org
          )
          |> Ash.create!()
        end

      assert {:ok, transaction} =
               TenantTransaction
               |> Ash.Changeset.for_create(
                 :post,
                 %{
                   entries: [
                     %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
                     %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
                   ]
                 },
                 tenant: org
               )
               |> Ash.create()

      entries =
        TenantEntry
        |> Ash.Query.filter(transaction_id == ^transaction.id)
        |> Ash.read!(tenant: org)

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.org_id == org))
    end

    # Ash lets a caller hand the tenant (and actor, tracer) to `Ash.create/2`
    # rather than to `for_create/3`. The change's `context` is a snapshot taken
    # at `for_create`, so a hook that closes over it never sees them; the
    # changeset the hook is handed does.
    test "a tenant given to Ash.create/2 rather than for_create/3 is honoured too" do
      org = Ash.UUID.generate()

      [cash, revenue] =
        for identifier <- ["tenant_cash_late", "tenant_revenue_late"] do
          TenantAccount
          |> Ash.Changeset.for_create(:open, %{identifier: identifier, currency: "USD"},
            tenant: org
          )
          |> Ash.create!()
        end

      assert {:ok, transaction} =
               TenantTransaction
               |> Ash.Changeset.for_create(:post, %{
                 entries: [
                   %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
                   %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
                 ]
               })
               |> Ash.create(tenant: org)

      assert transaction.org_id == org
    end
  end

  describe "a leg's account_id must cast to the Account's id type" do
    # Before the up-front lock, a malformed id only ever reached the Entry changeset,
    # where Ash cast it and returned `InvalidAttribute` at the leg. Feeding the raw
    # value into the lock's `id in ^ids` filter instead raises `InvalidFilterValue`
    # from inside the before_action hook — a 500 with no leg index where a 422 belongs.
    test "a malformed id is a validation error at its own leg, not a raise from the lock query" do
      cash = account("cast_cash")

      result =
        post([
          %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: "not-a-uuid", side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert {:error, %Ash.Error.Invalid{}} = result

      assert {Ash.Error.Changes.InvalidAttribute, :account_id, nil, [:entries, 1]} in leaf_summaries(
               result
             )

      assert count(Transaction) == 0
      assert count(Entry) == 0
      assert count(Balance) == 0
    end

    test "a well-formed id that names no account is reported at its leg the same way" do
      cash = account("cast_cash_2")
      ghost = Ash.UUID.generate()

      result =
        post([
          %{account_id: ghost, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: cash.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert {:error, %Ash.Error.Invalid{}} = result

      assert {Ash.Error.Changes.InvalidAttribute, :account_id, nil, [:entries, 0]} in leaf_summaries(
               result
             )
    end
  end

  describe "a leg's currency is compared against its account's normalised code" do
    # `Account.currency` is an unconstrained string, and the released Transfer
    # path only ever reads it through `Money.new!/2`, which normalises case. A
    # code the library accepted on `open` has to stay postable on every path.
    test "an account stored with a lowercase currency code posts", ctx do
      _ = ctx

      [cash, revenue] =
        for identifier <- ["lc_cash", "lc_revenue"] do
          Account
          |> Ash.Changeset.for_create(:open, %{identifier: identifier, currency: "usd"})
          |> Ash.create!()
        end

      # Control: the released path accepts these accounts as they are.
      assert {:ok, _} =
               AshDoubleEntry.Test.Transfer
               |> Ash.Changeset.for_create(:transfer, %{
                 from_account_id: cash.id,
                 to_account_id: revenue.id,
                 amount: Money.new!(:USD, "1.00")
               })
               |> Ash.create()

      assert {:ok, _} =
               post([
                 %{account_id: cash.id, side: :debit, amount: Money.new!(:USD, "10.00")},
                 %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, "10.00")}
               ])
    end
  end
end
