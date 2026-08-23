# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Property.ReversalAtomicityTest do
  @moduledoc """
  Property tests for three things a ledger cannot be wrong about.

    * **Reversal** — posting a journal and reversing it returns every account it
      touched to the exact balance it had before, whatever the leg count, the
      sides, the amounts, how often one account appears in the same journal, or
      what order the journals were posted and reversed in.

    * **Atomicity** — a journal with one bad leg writes nothing at all, wherever
      in the journal that leg sits and whatever is wrong with it. Transaction,
      Entry AND Balance counts are all checked; a Balance row surviving a rolled
      back journal is the failure mode nobody notices until a statement is wrong.

    * **Totality** — `post` answers `{:ok, _}` or an Ash error for ANY input. A
      library that raises on a malformed request hands its consumer a 500 where
      a 422 belongs, so "it errored" is not enough: it has to error by returning.

  Tests tagged `:library_bug` pin defects that are known and not yet fixed;
  `test_helper.exs` excludes them from an ordinary run, and
  `mix test --include library_bug` runs them.

  Balances are compared as normalised `Decimal`s. `balance_as_of` is `nil` until
  an account has any balance row, and "has not moved yet" has to compare equal
  to "moved and moved back".
  """
  use DataCase, async: false
  use ExUnitProperties

  alias AshDoubleEntry.Test.{Account, Balance, Entry, Transaction}

  require Ash.Query

  @moduletag timeout: 600_000
  @moduletag ownership_timeout: :infinity

  # ------------------------------------------------------------------
  # fixtures — the idioms from test/transaction_cascade_test.exs
  # ------------------------------------------------------------------

  defp account(identifier, currency) do
    Account
    |> Ash.Changeset.for_create(:open, %{identifier: identifier, currency: currency})
    |> Ash.create!()
  end

  defp pool(size, prefix, currency \\ "USD") do
    tag = System.unique_integer([:positive])
    Enum.map(1..size, &account("#{prefix}_#{tag}_#{&1}", currency))
  end

  defp post(entries, attrs \\ %{}) do
    Transaction
    |> Ash.Changeset.for_create(:post, Map.put(attrs, :entries, entries))
    |> Ash.create()
  end

  defp reverse(transaction_id) do
    Transaction
    |> Ash.Changeset.for_create(:reverse, %{original_transaction_id: transaction_id})
    |> Ash.create()
  end

  defp count(resource) do
    resource |> Ash.Query.new() |> Ash.count!(authorize?: false)
  end

  defp row_counts do
    %{transactions: count(Transaction), entries: count(Entry), balances: count(Balance)}
  end

  # Splode nests errors; the leaves are what carry `path` and `field`.
  defp leaves(error) do
    case Map.get(error, :errors) do
      [_ | _] = errors -> Enum.flat_map(errors, &leaves/1)
      _ -> [error]
    end
  end

  defp leaf_paths({:error, error}), do: leaf_paths(error)
  defp leaf_paths(error), do: error |> leaves() |> Enum.map(& &1.path)

  defp balances(account_ids) do
    Account
    |> Ash.Query.filter(id in ^account_ids)
    |> Ash.Query.load(:balance_as_of)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn account -> {account.id, to_decimal(account.balance_as_of)} end)
  end

  defp to_decimal(nil), do: dec(0)
  defp to_decimal(%Money{amount: amount}), do: Decimal.normalize(amount)

  # Balances are compared by map equality, so both sides need the same canonical
  # Decimal form — `Decimal.normalize/1` writes 10 as 1E+1, and an un-normalised
  # literal would never match it.
  defp dec(value), do: value |> Decimal.new() |> Decimal.normalize()

  defp legs_of(transaction) do
    transaction
    |> Ash.load!(:entries)
    |> Map.get(:entries)
    |> Enum.map(&{&1.account_id, &1.side, Decimal.normalize(&1.amount.amount), &1.line_item_id})
    |> Enum.sort()
  end

  defp flip(:debit), do: :credit
  defp flip(:credit), do: :debit

  # Σ debits − Σ credits, as a plain Decimal.
  defp imbalance(legs) do
    Enum.reduce(legs, Decimal.new(0), fn leg, acc ->
      case leg.side do
        :debit -> Decimal.add(acc, leg.amount.amount)
        :credit -> Decimal.sub(acc, leg.amount.amount)
      end
    end)
  end

  # ------------------------------------------------------------------
  # generators
  # ------------------------------------------------------------------

  # Amounts across scales: sub-cent, ordinary, and far past what a float would
  # survive. `money_with_currency` is an unbounded numeric, so nothing here has
  # an excuse for losing precision.
  defp amount_generator(min_units) do
    StreamData.frequency([
      {6, StreamData.map(StreamData.integer(min_units..1_000_000), &decimal_money(&1, -2))},
      {2, StreamData.map(StreamData.integer(min_units..1_000_000), &decimal_money(&1, -4))},
      {2,
       StreamData.map(
         StreamData.integer(1_000_000_000_000..999_999_999_999_999_999),
         &decimal_money(&1, -2)
       )}
    ])
  end

  defp decimal_money(coefficient, exponent) do
    Money.new!(:USD, Decimal.new(1, coefficient, exponent))
  end

  defp leg_generator(account_ids, min_units) do
    gen all(
          account_id <- StreamData.member_of(account_ids),
          side <- StreamData.member_of([:debit, :credit]),
          amount <- amount_generator(min_units),
          line_item_id <-
            StreamData.one_of([
              StreamData.constant(nil),
              StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
            ])
        ) do
      %{account_id: account_id, side: side, amount: amount, line_item_id: line_item_id}
    end
  end

  # A balanced journal: free legs, plus one closing leg that absorbs whatever
  # imbalance they left. Accounts are drawn from a small pool, so the same
  # account routinely appears on both sides of one journal.
  #
  # `nonzero: true` guarantees every leg carries a non-zero amount, which the
  # atomicity properties need: a corruption applied to a zero leg (negating it,
  # say) can leave a perfectly legal journal behind. The reversal properties
  # leave it off, because a zero leg is a legal shape and reversing one has to
  # stay zero.
  defp journal_generator(account_ids, opts \\ []) do
    nonzero? = Keyword.get(opts, :nonzero, false)
    min_units = if nonzero?, do: 1, else: 0

    gen all(
          legs <-
            StreamData.list_of(leg_generator(account_ids, min_units),
              min_length: 1,
              max_length: Keyword.get(opts, :max_free_legs, 7)
            ),
          closing_account <- StreamData.member_of(account_ids)
        ) do
      legs = if nonzero?, do: ensure_imbalanced(legs), else: legs
      legs ++ [closing_leg(legs, closing_account)]
    end
  end

  # If the free legs already balance, the closing leg would be zero. Flipping
  # the last leg's side moves the imbalance by twice its (non-zero) amount, so
  # the closing leg is non-zero without changing any amount.
  defp ensure_imbalanced(legs) do
    if Decimal.equal?(imbalance(legs), Decimal.new(0)) do
      List.update_at(legs, -1, &%{&1 | side: flip(&1.side)})
    else
      legs
    end
  end

  defp closing_leg(legs, account_id) do
    imbalance = imbalance(legs)
    side = if Decimal.negative?(imbalance), do: :debit, else: :credit

    %{
      account_id: account_id,
      side: side,
      amount: Money.new!(:USD, Decimal.abs(imbalance)),
      line_item_id: "closing"
    }
  end

  # ------------------------------------------------------------------
  # reversal
  # ------------------------------------------------------------------

  describe "reversal round trip" do
    property "post then reverse returns every touched account to its prior balance" do
      accounts = pool(5, "rt")
      ids = Enum.map(accounts, & &1.id)

      check all(journal <- journal_generator(ids), max_runs: 60) do
        before = balances(ids)

        assert {:ok, transaction} = post(journal)
        assert {:ok, _reversal} = reverse(transaction.id)

        assert balances(ids) == before,
               "a #{length(journal)}-leg journal did not reverse cleanly"
      end
    end

    property "the same holds for wide journals over a small pool of accounts" do
      # Up to 21 legs over 3 accounts: every account carries several legs of the
      # same journal, on both sides, and every cascaded Entry lands in the same
      # millisecond — so the ULIDs that order the balance rows differ only in
      # their random suffix, and the balance shift has to be right for any
      # ordering of them.
      accounts = pool(3, "wide")
      ids = Enum.map(accounts, & &1.id)

      check all(journal <- journal_generator(ids, max_free_legs: 20), max_runs: 20) do
        before = balances(ids)

        assert {:ok, transaction} = post(journal)
        assert {:ok, _reversal} = reverse(transaction.id)

        assert balances(ids) == before,
               "a #{length(journal)}-leg journal did not reverse cleanly"
      end
    end

    property "reversing the reversal returns to the post-original state" do
      accounts = pool(4, "rr")
      ids = Enum.map(accounts, & &1.id)

      check all(journal <- journal_generator(ids, max_free_legs: 5), max_runs: 40) do
        assert {:ok, original} = post(journal)
        after_original = balances(ids)

        assert {:ok, reversal} = reverse(original.id)

        # Guard against a vacuous pass: if `reverse` moved nothing, "reversing
        # the reversal restores" would hold for the wrong reason. Only a journal
        # whose net effect on some account is non-zero can carry that check.
        unless trivial?(journal) do
          refute balances(ids) == after_original,
                 "the first reversal moved nothing at all"
        end

        assert {:ok, _second} = reverse(reversal.id)

        assert balances(ids) == after_original,
               "reversing a reversal did not restore the post-original balances"
      end
    end

    defp trivial?(journal) do
      journal
      |> Enum.group_by(& &1.account_id)
      |> Enum.all?(fn {_id, legs} -> Decimal.equal?(imbalance(legs), Decimal.new(0)) end)
    end

    property "a reversal is the exact mirror of the original, app fields included" do
      accounts = pool(4, "mirror")
      ids = Enum.map(accounts, & &1.id)

      check all(journal <- journal_generator(ids, max_free_legs: 5), max_runs: 40) do
        assert {:ok, original} = post(journal)
        assert {:ok, reversal} = reverse(original.id)

        expected =
          original
          |> legs_of()
          |> Enum.map(fn {account_id, side, amount, line_item_id} ->
            {account_id, flip(side), amount, line_item_id}
          end)
          |> Enum.sort()

        assert legs_of(reversal) == expected
        assert reversal.reverses_transaction_id == original.id
      end
    end

    property "journals posted at arbitrary times, reversed in arbitrary order, net to nothing" do
      # Backdating is where the balance model earns its keep: a reversal always
      # posts at `now`, so reversing a 40-day-old journal inserts an entry AFTER
      # entries that are already there and has to shift nothing, while the
      # backdated original had to shift everything later than it. Reversing in
      # an order unrelated to the posting order exercises both directions.
      accounts = pool(4, "clock")
      ids = Enum.map(accounts, & &1.id)

      check all(
              journals <-
                StreamData.list_of(journal_generator(ids, max_free_legs: 3),
                  min_length: 2,
                  max_length: 4
                ),
              offsets <-
                StreamData.list_of(StreamData.integer(-90..0), length: length(journals)),
              order <-
                StreamData.list_of(StreamData.integer(0..999), length: length(journals)),
              max_runs: 25
            ) do
        before = balances(ids)

        posted =
          journals
          |> Enum.zip(offsets)
          |> Enum.map(fn {journal, days} ->
            posted_at = DateTime.add(DateTime.utc_now(), days * 24 * 60 * 60, :second)
            assert {:ok, transaction} = post(journal, %{posted_at: posted_at})
            transaction
          end)

        order
        |> Enum.zip(posted)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.each(fn {_key, transaction} ->
          assert {:ok, _} = reverse(transaction.id)
        end)

        assert balances(ids) == before,
               "#{length(journals)} journals posted across #{inspect(offsets)} days did not net out"
      end
    end

    test "a reversal of an all-zero journal stays zero on both sides" do
      [a, b] = pool(2, "zero_only")

      assert {:ok, original} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "0.00")},
                 %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "0.00")}
               ])

      assert {:ok, reversal} = reverse(original.id)

      assert legs_of(reversal) ==
               Enum.sort([
                 {a.id, :credit, dec(0), nil},
                 {b.id, :debit, dec(0), nil}
               ])

      assert balances([a.id, b.id]) == %{a.id => dec(0), b.id => dec(0)}
    end

    test "a journal that both debits and credits one single account reverses cleanly" do
      [a] = pool(1, "self")

      assert {:ok, original} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "10.00")},
                 %{account_id: a.id, side: :credit, amount: Money.new!(:USD, "10.00")}
               ])

      assert balances([a.id]) == %{a.id => dec(0)}

      assert {:ok, _} = reverse(original.id)
      assert balances([a.id]) == %{a.id => dec(0)}
    end
  end

  # ------------------------------------------------------------------
  # idempotency of :reverse
  # ------------------------------------------------------------------

  describe "reversing the same journal twice" do
    test "is accepted, and doubles the correction" do
      # Documenting, not endorsing. `reverses_transaction_id` carries no identity
      # and nothing reads it before posting, so `reverse` is unguarded: called
      # twice on the same journal it posts two mirrors and drives the account
      # PAST zero, to the negative of the original. An application that retries
      # a reversal — a timeout, a duplicated webhook, an operator clicking twice
      # — books the correction twice and nothing in the ledger objects.
      #
      # Whether the library should refuse this is the owner's call: guarding it
      # means an identity on `reverses_transaction_id` and a unique index that
      # every consuming application would have to migrate to. See the report.
      [a, b] = pool(2, "twice")

      assert {:ok, original} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "10.00")},
                 %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "10.00")}
               ])

      assert {:ok, first} = reverse(original.id)
      assert balances([a.id]) == %{a.id => dec(0)}

      assert {:ok, second} = reverse(original.id)

      assert first.id != second.id
      assert first.reverses_transaction_id == original.id
      assert second.reverses_transaction_id == original.id

      assert balances([a.id, b.id]) == %{
               a.id => dec("-10"),
               b.id => dec("10")
             }
    end

    @tag :library_bug
    test "a caller-supplied `entries` argument to :reverse is silently discarded" do
      # `:reverse` declares a public `entries` argument (`{:array, :map}`,
      # allow_nil?: true) purely so `ReverseTransaction` can hand the flipped
      # legs to `VerifyTransaction`. Ash exposes action arguments to whatever
      # sits on top — AshJsonApi, AshGraphql, a `code_interface` — so a caller
      # can supply `entries` on a reversal, and `ReverseTransaction.change/3`
      # overwrites it with `set_argument/3` before anything reads it.
      #
      # The journal that gets posted is not the one that was asked for, and
      # nothing says so. That is the same silent discard the rest of this stack
      # went out of its way to remove for `post` (see the "fields the
      # transaction owns" tests, where a per-leg `timestamp` is REJECTED rather
      # than overridden). `:reverse` should refuse the input the same way.
      [a, b, c] = pool(3, "rev_entries")

      assert {:ok, original} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "10.00")},
                 %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "10.00")}
               ])

      result =
        Transaction
        |> Ash.Changeset.for_create(:reverse, %{
          original_transaction_id: original.id,
          entries: [
            %{account_id: c.id, side: :debit, amount: Money.new!(:USD, "999.00")},
            %{account_id: a.id, side: :credit, amount: Money.new!(:USD, "999.00")}
          ]
        })
        |> Ash.create()

      assert match?({:error, _}, result),
             "reverse accepted an `entries` argument and threw it away: " <>
               "account c moved #{inspect(balances([c.id]))} instead of 999.00, " <>
               "and the caller was told the reversal succeeded"
    end
  end

  # ------------------------------------------------------------------
  # atomicity
  # ------------------------------------------------------------------

  # Kinds the extension names the offending leg for: some error leaf carries
  # `[:entries, index]`.
  @indexed_kinds [
    :unknown_account,
    :account_currency_mismatch,
    :negative_amount,
    :unaccepted_key,
    :string_typo_key,
    :owned_field
  ]

  # Kinds that trip the journal-level shape check, which has no leg index. That
  # is a deliberate difference, not an oversight: "this journal does not
  # balance" and "all entries must share currency" are statements about the
  # journal. See the report for the one case that arguably should be indexed.
  @unindexed_kinds [:junk_side, :missing_amount, :mixed_currency]

  defp corrupt(journal, index, kind, foreign_account_id) do
    List.update_at(journal, index, fn leg ->
      case kind do
        :unknown_account ->
          %{leg | account_id: "00000000-0000-0000-0000-000000000000"}

        :account_currency_mismatch ->
          %{leg | account_id: foreign_account_id}

        # Negate the amount AND flip the side. That keeps Σdebits == Σcredits
        # exactly, so the journal-level balance check still passes and the leg's
        # own negative-amount check is what has to catch it — which is the whole
        # attack the negative-amount refusal exists to stop. Simply negating an
        # amount unbalances the journal, and then the balance error (correctly)
        # fires first and names no leg.
        :negative_amount ->
          %{leg | side: flip(leg.side), amount: Money.mult!(leg.amount, -1)}

        :unaccepted_key ->
          Map.put(leg, :internal_note, "not accepted")

        :string_typo_key ->
          Map.put(leg, "line_itm_id", "typo")

        :owned_field ->
          Map.put(leg, :timestamp, ~U[2001-01-01 00:00:00.000000Z])

        :junk_side ->
          %{leg | side: :sideways}

        :missing_amount ->
          Map.delete(leg, :amount)

        :mixed_currency ->
          %{leg | amount: Money.new!(:EUR, leg.amount.amount)}
      end
    end)
  end

  describe "atomicity" do
    property "one invalid leg anywhere in a journal writes nothing at all" do
      accounts = pool(4, "atomic")
      ids = Enum.map(accounts, & &1.id)
      [foreign] = pool(1, "atomic_eur", "EUR")

      check all(
              journal <- journal_generator(ids, max_free_legs: 6, nonzero: true),
              index <- StreamData.integer(0..(length(journal) - 1)),
              kind <- StreamData.member_of(@indexed_kinds ++ @unindexed_kinds),
              max_runs: 150
            ) do
        before = row_counts()

        result = journal |> corrupt(index, kind, foreign.id) |> post()

        assert {:error, _} = result,
               "#{kind} at leg #{index} of #{length(journal)} was accepted"

        assert row_counts() == before,
               "#{kind} at leg #{index} left rows behind: " <>
                 "#{inspect(row_counts())} vs #{inspect(before)}"

        if kind in @indexed_kinds do
          assert [:entries, index] in leaf_paths(result),
                 "#{kind} at leg #{index} did not name its leg; " <>
                   "paths were #{inspect(leaf_paths(result))}"
        end
      end
    end

    property "a bad leg at index 0 and the same bad leg at index N-1 behave identically" do
      accounts = pool(4, "sym")
      ids = Enum.map(accounts, & &1.id)
      [foreign] = pool(1, "sym_eur", "EUR")

      check all(
              journal <- journal_generator(ids, max_free_legs: 6, nonzero: true),
              kind <- StreamData.member_of(@indexed_kinds ++ @unindexed_kinds),
              max_runs: 60
            ) do
        last = length(journal) - 1

        before = row_counts()

        first_result = journal |> corrupt(0, kind, foreign.id) |> post()
        assert {:error, _} = first_result
        assert row_counts() == before

        last_result = journal |> corrupt(last, kind, foreign.id) |> post()
        assert {:error, _} = last_result
        assert row_counts() == before

        assert error_shape(first_result, 0) == error_shape(last_result, last),
               "#{kind} reported differently at index 0 " <>
                 "(#{inspect(error_shape(first_result, 0))}) than at index #{last} " <>
                 "(#{inspect(error_shape(last_result, last))})"
      end
    end

    # The error's *shape* with the index factored out: which leaf modules fired,
    # and whether each fired at the corrupted leg or off it.
    defp error_shape({:error, error}, index) do
      error
      |> leaves()
      |> Enum.map(&{&1.__struct__, &1.path == [:entries, index]})
      |> Enum.sort()
    end

    test "an unknown account at the FIRST leg leaves nothing behind" do
      [_a, b] = pool(2, "atomic_first")
      before = row_counts()

      assert {:error, _} =
               post([
                 %{
                   account_id: "00000000-0000-0000-0000-000000000000",
                   side: :debit,
                   amount: Money.new!(:USD, "1.00")
                 },
                 %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "1.00")}
               ])

      assert row_counts() == before
    end

    test "a journal whose only fault is at the very last leg leaves nothing behind" do
      [a, b, c] = pool(3, "atomic_last")
      before = row_counts()

      assert {:error, _} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "3.00")},
                 %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "2.00")},
                 %{
                   account_id: c.id,
                   side: :credit,
                   amount: Money.new!(:USD, "1.00"),
                   internal_note: "not accepted"
                 }
               ])

      assert row_counts() == before
    end

    test "a balance-preserving negative leg is refused at its own index" do
      # The shrunk, deterministic form of the `:negative_amount` corruption: the
      # journal balances, so only the per-leg check can catch it.
      [a, b] = pool(2, "neg_flip")
      before = row_counts()

      result =
        post([
          %{account_id: a.id, side: :credit, amount: Money.new!(:USD, "-10.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "10.00")}
        ])

      assert {:error, _} = result
      assert [:entries, 0] in leaf_paths(result)
      assert row_counts() == before
    end
  end

  # ------------------------------------------------------------------
  # totality
  # ------------------------------------------------------------------

  defp junk_value do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.boolean(),
      StreamData.integer(),
      StreamData.float(),
      StreamData.string(:printable, max_length: 6),
      StreamData.atom(:alphanumeric),
      StreamData.list_of(StreamData.integer(), max_length: 2),
      StreamData.constant(%{}),
      StreamData.constant([{:a, 1}]),
      StreamData.constant(Money.new!(:USD, "1.00")),
      StreamData.constant(Decimal.new("1.5")),
      StreamData.constant(~U[2020-01-01 00:00:00.000000Z]),
      StreamData.constant("00000000-0000-0000-0000-000000000000"),
      StreamData.constant("not-a-uuid"),
      StreamData.constant("debit"),
      StreamData.constant(:debit)
    ])
  end

  defp junk_key do
    StreamData.member_of([
      :account_id,
      "account_id",
      :side,
      "side",
      :amount,
      "amount",
      :timestamp,
      :transaction_id,
      :line_item_id,
      "line_item_id",
      :internal_note,
      :id,
      1,
      "",
      {:tuple, :key}
    ])
  end

  defp junk_leg(account_ids) do
    StreamData.one_of([
      StreamData.map(
        StreamData.list_of(StreamData.tuple({junk_key(), junk_value()}), max_length: 5),
        &Map.new/1
      ),
      # a leg that is nearly right, with one or two fields replaced by junk
      gen all(
            account_id <- StreamData.member_of(account_ids),
            side <- junk_value(),
            amount <- junk_value()
          ) do
        %{account_id: account_id, side: side, amount: amount}
      end,
      # legs that are not maps at all
      junk_value()
    ])
  end

  defp junk_entries(account_ids) do
    StreamData.frequency([
      {8, StreamData.list_of(junk_leg(account_ids), max_length: 5)},
      {1,
       StreamData.one_of([
         StreamData.constant(nil),
         StreamData.constant(%{}),
         StreamData.constant(%{"0" => %{}, "1" => %{}}),
         StreamData.constant("entries"),
         StreamData.constant(42),
         StreamData.constant(:entries),
         StreamData.constant(%{account_id: nil}),
         StreamData.constant([[]]),
         StreamData.constant([nil, nil])
       ])}
    ])
  end

  # A journal that is perfectly well formed apart from one leg's `account_id`
  # being something no uuid parser will accept. Every journal-level check passes,
  # so this reaches `VerifyTransaction.lock_accounts/3` — the deepest point a
  # caller-supplied value travels before any row is written.
  defp malformed_account_id_journal(account_ids) do
    gen all(
          journal <- journal_generator(account_ids, max_free_legs: 4),
          index <- StreamData.integer(0..(length(journal) - 1)),
          junk <-
            StreamData.one_of([
              StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
              StreamData.integer(),
              StreamData.boolean(),
              StreamData.constant(%{}),
              StreamData.constant([1, 2]),
              StreamData.constant("00000000-0000-0000-0000-00000000000"),
              StreamData.constant(:not_an_id)
            ])
        ) do
      List.update_at(journal, index, &%{&1 | account_id: junk})
    end
  end

  defp ash_error?(term), do: is_exception(term) and Ash.Error.ash_error?(term)

  defp guarded_post(entries) do
    {:returned, post(entries)}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  catch
    kind, value -> {:caught, kind, value}
  end

  defp describe_outcome({:raised, exception, stacktrace}) do
    Exception.format(:error, exception, Enum.take(stacktrace, 6))
  end

  defp describe_outcome(other), do: inspect(other, limit: 8)

  describe "totality" do
    property "post answers {:ok, _} or an Ash error for arbitrary malformed entries" do
      accounts = pool(3, "junk")
      ids = Enum.map(accounts, & &1.id)

      check all(entries <- junk_entries(ids), max_runs: 400) do
        case guarded_post(entries) do
          {:returned, {:ok, _transaction}} ->
            :ok

          {:returned, {:error, error}} ->
            assert ash_error?(error),
                   "post returned a non-Ash error for #{inspect(entries, limit: 5)}: " <>
                     inspect(error)

          other ->
            flunk("""
            post did not return for entries #{inspect(entries, limit: 10)}

            #{describe_outcome(other)}
            """)
        end
      end
    end

    property "a malformed journal never leaves a partial write behind" do
      accounts = pool(3, "junk_atomic")
      ids = Enum.map(accounts, & &1.id)

      check all(entries <- junk_entries(ids), max_runs: 200) do
        before = row_counts()

        case guarded_post(entries) do
          {:returned, {:ok, transaction}} ->
            # A junk journal that nonetheless posts must have posted completely.
            leg_count = transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length()
            after_counts = row_counts()

            assert after_counts.transactions == before.transactions + 1
            assert after_counts.entries == before.entries + leg_count

          {:returned, {:error, _}} ->
            assert row_counts() == before,
                   "a rejected malformed journal left rows behind: #{inspect(entries, limit: 5)}"

          other ->
            flunk("post did not return: #{describe_outcome(other)}")
        end
      end
    end

    test "entries that is not a list at all is an error, not a crash" do
      for value <- [nil, 42, "entries", :entries, %{}] do
        outcome = guarded_post(value)

        assert match?({:returned, {:error, _}}, outcome),
               "entries: #{inspect(value)} did not produce a returned error:" <>
                 "\n\n#{describe_outcome(outcome)}"

        {:returned, {:error, error}} = outcome
        assert ash_error?(error)
      end
    end

    test "a leg that is not a map is an error, not a crash" do
      [a] = pool(1, "nonmap_leg")

      for leg <- [nil, 42, "leg", :leg, [1, 2, 3]] do
        outcome =
          guarded_post([
            leg,
            %{account_id: a.id, side: :credit, amount: Money.new!(:USD, "1.00")}
          ])

        assert match?({:returned, {:error, _}}, outcome),
               "leg: #{inspect(leg)} did not produce a returned error:" <>
                 "\n\n#{describe_outcome(outcome)}"

        {:returned, {:error, error}} = outcome
        assert ash_error?(error)
      end
    end

    test "the crash on a malformed account_id at least rolls back" do
      # Separated from the tagged failure below so that the atomicity half of
      # this stays green and stays checked: whatever `post` does with a bad
      # account_id, it must not half-write the journal.
      [a] = pool(1, "bad_uuid_rollback")
      before = row_counts()

      _ =
        guarded_post([
          %{account_id: "not-a-uuid", side: :debit, amount: Money.new!(:USD, "1.00")},
          %{account_id: a.id, side: :credit, amount: Money.new!(:USD, "1.00")}
        ])

      assert row_counts() == before
    end

    test "an account_id that is not a UUID is a returned error, not a raise" do
      # Regression pin. The up-front account lock (f74cf06) fed caller-supplied
      # ids straight into its `id in ^ids` filter, so a value the id type could
      # not cast raised `InvalidFilterValue` out of the before_action hook — a
      # 500 where the Entry changeset used to return `InvalidAttribute` at the
      # leg. Fixed in 7733f4f by casting each id before it reaches the filter.
      # Not confined to strings: 42, true, %{} and [1, 2] all raised identically,
      # at any leg index.
      [a] = pool(1, "bad_uuid")

      outcome =
        guarded_post([
          %{account_id: "not-a-uuid", side: :debit, amount: Money.new!(:USD, "1.00")},
          %{account_id: a.id, side: :credit, amount: Money.new!(:USD, "1.00")}
        ])

      assert match?({:returned, {:error, _}}, outcome),
             "post raised instead of returning:\n\n#{describe_outcome(outcome)}"

      {:returned, {:error, error}} = outcome
      assert ash_error?(error)
    end

    property "post never raises, for any leg's account_id and any leg index" do
      # The fuzzed form of the same regression: an otherwise valid balanced journal
      # with one leg's account_id replaced by something no uuid parser accepts.
      accounts = pool(3, "bad_uuid_fuzz")
      ids = Enum.map(accounts, & &1.id)

      check all(journal <- malformed_account_id_journal(ids), max_runs: 60) do
        case guarded_post(journal) do
          {:returned, {:ok, _}} -> :ok
          {:returned, {:error, error}} -> assert ash_error?(error)
          other -> flunk("post did not return:\n\n#{describe_outcome(other)}")
        end
      end
    end
  end
end
