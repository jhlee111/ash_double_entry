# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.BalanceConservationPropertyTest do
  @moduledoc """
  Balance conservation and reconstruction, fuzzed.

  Three claims, stated as properties over randomly generated journals:

    1. CONSERVATION — for any balanced journal, every touched account's balance
       moves by exactly the signed sum of its own legs (debit adds, credit
       subtracts), and no untouched account moves.

    2. RECONSTRUCTION — for any sequence of journals, the reified balance equals
       a fold over that account's own Entry rows, computed here and never read
       out of a Balance row. This is the invariant the whole Balance-row scheme
       exists to serve.

    3. GLOBAL CONSERVATION — summing every account's balance over a sequence of
       balanced journals is zero.

  Balances are read back through the public calculations (`balance_as_of`,
  `balance_as_of_ulid`), never by inspecting Balance rows, so a property that
  holds is evidence about the API an application actually consumes.

  Two tests in "interleaved Transfer and Transaction writes" pin a defect fixed in
  this stack: a Transfer's balance ripple never reached entry-keyed Balance rows.
  """

  use DataCase, async: false
  use ExUnitProperties

  # Heavy properties: ~12 s alone, but a loaded host pushed them past ExUnit's 60 s default.
  @moduletag timeout: 600_000
  @moduletag ownership_timeout: :infinity

  alias AshDoubleEntry.Test.{Account, Balance, Entry, Transaction, Transfer}

  require Ash.Query

  @currency :USD
  @zero Money.new!(@currency, 0)

  # Past any timestamp these tests use, so "the balance now" is unambiguous.
  @end_of_time ~U[2999-01-01 00:00:00.000000Z]

  # Every property draws its legs from a pool of this many accounts, so leg
  # generation can be plain integer indices and account reuse — including the
  # same account on both sides of one journal — happens on its own.
  @pool 4

  # ---------------------------------------------------------------------------
  # Fixtures — same idioms as test/transaction_cascade_test.exs
  # ---------------------------------------------------------------------------

  # Property runs share one sandbox transaction, so identifiers have to be
  # unique across every run of every test in the file.
  defp account(prefix) do
    Account
    |> Ash.Changeset.for_create(:open, %{
      identifier: "#{prefix}_#{System.unique_integer([:positive])}",
      currency: to_string(@currency)
    })
    |> Ash.create!()
  end

  defp accounts(n, prefix), do: Enum.map(1..n, fn _ -> account(prefix) end)

  defp post(entries, attrs \\ %{}) do
    Transaction
    |> Ash.Changeset.for_create(:post, Map.put(attrs, :entries, entries))
    |> Ash.create()
  end

  defp post!(entries, attrs \\ %{}) do
    {:ok, transaction} = post(entries, attrs)
    transaction
  end

  defp transfer!(from, to, amount, attrs) do
    Transfer
    |> Ash.Changeset.for_create(
      :transfer,
      Map.merge(%{from_account_id: from.id, to_account_id: to.id, amount: amount}, attrs)
    )
    |> Ash.create!()
  end

  defp count(resource) do
    resource |> Ash.Query.new() |> Ash.count!(authorize?: false)
  end

  # Turn generated leg indices into legs against a concrete account pool.
  defp resolve(legs, pool) do
    Enum.map(legs, fn leg -> %{leg | account_id: Enum.at(pool, leg.account_id - 1).id} end)
  end

  # ---------------------------------------------------------------------------
  # Reading balances back — through the public calculations only
  # ---------------------------------------------------------------------------

  defp balance_as_of(account_id, timestamp \\ @end_of_time) do
    Account
    |> Ash.Query.filter(id == ^account_id)
    |> Ash.Query.load(balance_as_of: %{timestamp: timestamp})
    |> Ash.read_one!()
    |> Map.fetch!(:balance_as_of)
  end

  defp balance_as_of_ulid(account_id, ulid) do
    Account
    |> Ash.Query.filter(id == ^account_id)
    |> Ash.Query.load(balance_as_of_ulid: %{ulid: ulid})
    |> Ash.read_one!()
    |> Map.fetch!(:balance_as_of_ulid)
  end

  defp entries_of(account_id) do
    Entry
    |> Ash.Query.filter(account_id == ^account_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.select([:id, :side, :amount])
    |> Ash.read!(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # The arithmetic the library is supposed to be doing, done independently
  # ---------------------------------------------------------------------------

  defp signed(%{side: :debit, amount: amount}), do: amount
  defp signed(%{side: :credit, amount: amount}), do: Money.mult!(amount, -1)

  defp net_by_account(legs) do
    Enum.reduce(legs, %{}, fn leg, acc ->
      Map.update(acc, leg.account_id, signed(leg), &Money.add!(&1, signed(leg)))
    end)
  end

  defp sum_money(monies), do: Enum.reduce(monies, @zero, &Money.add!(&2, &1))

  defp assert_money(actual, expected, context) do
    assert Money.equal?(actual, expected),
           "#{context}\n  expected: #{inspect(expected)}\n  actual:   #{inspect(actual)}"
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Amounts across the scales an application actually uses: ordinary cents,
  # sub-cent rates, and figures far past what a float or an int64 of cents could
  # hold. All non-negative — `amount` is a magnitude (D2) and a negative one is
  # refused outright, so generating them would only fuzz the rejection path.
  defp amount_gen do
    StreamData.frequency([
      {6, StreamData.map(StreamData.integer(0..1_000_000), &decimal(&1, 2))},
      {2, StreamData.map(StreamData.integer(1..999_999), &decimal(&1, 6))},
      {1,
       StreamData.map(
         StreamData.integer(1..999_999),
         &decimal(&1 * 1_000_000_000_000_000_000, 2)
       )},
      {1, StreamData.constant(decimal(0, 2))}
    ])
    |> StreamData.map(&Money.new!(@currency, &1))
  end

  defp decimal(int, scale), do: Decimal.new(1, int, -scale)

  # A journal that balances BY CONSTRUCTION: k matched pairs, each contributing
  # one debit and one credit of the same amount, each leg landing on a freely
  # chosen account from the pool. Account reuse comes for free — the same
  # account on both sides of one journal, and duplicate identical legs, both
  # arise — without ever generating an UNbalanced journal, whose rejection would
  # say nothing about conservation.
  #
  # `account_id` holds a 1-based pool INDEX here; `resolve/2` swaps in real ids.
  defp balanced_journal(max_pairs) do
    gen all(
          pairs <-
            StreamData.list_of(
              StreamData.tuple(
                {amount_gen(), StreamData.integer(1..@pool), StreamData.integer(1..@pool)}
              ),
              min_length: 1,
              max_length: max_pairs
            ),
          shuffle_seed <- StreamData.integer()
        ) do
      pairs
      |> Enum.flat_map(fn {amount, debit_index, credit_index} ->
        [
          %{account_id: debit_index, side: :debit, amount: amount},
          %{account_id: credit_index, side: :credit, amount: amount}
        ]
      end)
      # Deterministic shuffle: leg ORDER within a journal must not matter, and a
      # seeded reshuffle keeps a shrunk counterexample reproducible.
      |> Enum.sort_by(&:erlang.phash2({shuffle_seed, &1}))
    end
  end

  # ---------------------------------------------------------------------------
  # PROPERTY 1 — per-account conservation, and untouched accounts
  # ---------------------------------------------------------------------------

  property "a balanced journal moves each touched account by the signed sum of its own legs" do
    check all(indexed_legs <- balanced_journal(6), max_runs: 200) do
      pool = accounts(@pool, "p1")
      bystanders = accounts(2, "p1_bystander")
      legs = resolve(indexed_legs, pool)

      assert {:ok, transaction} = post(legs)

      # every leg became its own Entry row — no leg silently collapsed into another
      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() ==
               length(legs)

      expected = net_by_account(legs)

      for acct <- pool do
        assert_money(
          balance_as_of(acct.id),
          Map.get(expected, acct.id, @zero),
          "account #{acct.identifier} after a #{length(legs)}-leg journal"
        )
      end

      for acct <- bystanders do
        assert_money(balance_as_of(acct.id), @zero, "an account named on no leg moved")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PROPERTY 2 — reconstruction
  # ---------------------------------------------------------------------------

  property "the reified balance equals a fold over the account's own Entry rows, at every point" do
    # A sequence of journals against a shared account pool, posted at timestamps
    # that are deliberately NOT in posting order. Backdating is the case the
    # Balance-row scheme has to survive: a backdated entry must ripple through
    # every LATER balance row of its account.
    #
    # The fold is over Entry ULIDs, the order the ledger itself treats as
    # authoritative — entry ids are time-ordered and the legs of one journal
    # share a millisecond. Folding by `timestamp` instead would be a test bug:
    # it cannot break ties inside a journal.
    check all(
            journals <- StreamData.list_of(balanced_journal(3), min_length: 1, max_length: 4),
            offsets <-
              StreamData.list_of(StreamData.integer(0..5_000), length: length(journals)),
            max_runs: 120
          ) do
      pool = accounts(@pool, "p2")
      base = ~U[2024-01-01 00:00:00.000000Z]

      journals
      |> Enum.zip(offsets)
      |> Enum.each(fn {indexed_legs, offset_ms} ->
        assert {:ok, _} =
                 post(
                   resolve(indexed_legs, pool),
                   %{posted_at: DateTime.add(base, offset_ms, :millisecond)}
                 )
      end)

      for acct <- pool do
        entries = entries_of(acct.id)

        history =
          inspect(Enum.map(entries, &{&1.id, &1.side, Money.to_string!(&1.amount)}))

        # Check the reified balance at EVERY point in the history, not just the
        # end. A scheme that only gets the final number right is not a ledger.
        total =
          Enum.reduce(entries, @zero, fn entry, running ->
            running = Money.add!(running, signed(entry))

            assert_money(
              balance_as_of_ulid(acct.id, entry.id),
              running,
              "reconstruction diverged at entry #{entry.id} of #{acct.identifier}; history = #{history}"
            )

            running
          end)

        assert_money(
          balance_as_of(acct.id),
          total,
          "the final balance of #{acct.identifier} does not equal the fold over its entries"
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PROPERTY 3 — global conservation
  # ---------------------------------------------------------------------------

  property "the sum of every account's balance over a sequence of journals is zero" do
    check all(
            journals <- StreamData.list_of(balanced_journal(4), min_length: 1, max_length: 4),
            max_runs: 120
          ) do
      pool = accounts(@pool, "p3")

      Enum.each(journals, fn indexed_legs ->
        assert {:ok, _} = post(resolve(indexed_legs, pool))
      end)

      assert_money(
        sum_money(Enum.map(pool, &balance_as_of(&1.id))),
        @zero,
        "money was created or destroyed across #{length(journals)} journals"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "one account on both sides of a single journal" do
    test "the legs net, and the up-front lock copes with the duplicate id" do
      cash = account("both_sides")
      other = account("both_sides_other")

      balances_before = count(Balance)

      assert {:ok, _} =
               post([
                 %{account_id: cash.id, side: :debit, amount: Money.new!(@currency, "10.00")},
                 %{account_id: cash.id, side: :credit, amount: Money.new!(@currency, "4.00")},
                 %{account_id: other.id, side: :credit, amount: Money.new!(@currency, "6.00")}
               ])

      assert_money(balance_as_of(cash.id), Money.new!(@currency, "6.00"), "netted balance")
      assert_money(balance_as_of(other.id), Money.new!(@currency, "-6.00"), "counterparty")

      # One Balance row per Entry, not one per account: the two legs on `cash`
      # must not collide on the upsert identity and overwrite one another.
      assert count(Balance) - balances_before == 3
    end

    test "legs that net to exactly zero leave the account where it started" do
      cash = account("net_zero")
      other = account("net_zero_other")

      post!([
        %{account_id: cash.id, side: :debit, amount: Money.new!(@currency, "25.00")},
        %{account_id: other.id, side: :credit, amount: Money.new!(@currency, "25.00")}
      ])

      post!([
        %{account_id: cash.id, side: :debit, amount: Money.new!(@currency, "7.00")},
        %{account_id: cash.id, side: :credit, amount: Money.new!(@currency, "7.00")}
      ])

      assert_money(balance_as_of(cash.id), Money.new!(@currency, "25.00"), "self-cancelling legs")
    end

    property "a journal built only from self-transfers leaves the balance untouched" do
      check all(
              amounts <- StreamData.list_of(amount_gen(), min_length: 1, max_length: 5),
              max_runs: 60
            ) do
        acct = account("self_transfer")

        legs =
          Enum.flat_map(amounts, fn amount ->
            [
              %{account_id: acct.id, side: :debit, amount: amount},
              %{account_id: acct.id, side: :credit, amount: amount}
            ]
          end)

        assert {:ok, _} = post(legs)
        assert_money(balance_as_of(acct.id), @zero, "a self-transfer moved the balance")
      end
    end
  end

  describe "duplicate identical legs" do
    test "two byte-identical legs both count" do
      cash = account("dup")
      other = account("dup_other")

      leg = %{account_id: cash.id, side: :debit, amount: Money.new!(@currency, "5.00")}

      assert {:ok, transaction} =
               post([
                 leg,
                 leg,
                 %{account_id: other.id, side: :credit, amount: Money.new!(@currency, "10.00")}
               ])

      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 3
      assert_money(balance_as_of(cash.id), Money.new!(@currency, "10.00"), "duplicate legs")
    end
  end

  describe "degenerate shapes" do
    test "a journal whose legs are all zero posts and moves nothing" do
      a = account("all_zero_a")
      b = account("all_zero_b")

      assert {:ok, transaction} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "0.00")},
                 %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "0.00")}
               ])

      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 2
      assert_money(balance_as_of(a.id), @zero, "all-zero journal")
      assert_money(balance_as_of(b.id), @zero, "all-zero journal")
    end

    test "a 50-leg journal conserves" do
      pool = accounts(50, "wide")
      {debits, credits} = Enum.split(pool, 25)

      legs =
        Enum.map(
          debits,
          &%{account_id: &1.id, side: :debit, amount: Money.new!(@currency, "2.00")}
        ) ++
          Enum.map(
            credits,
            &%{account_id: &1.id, side: :credit, amount: Money.new!(@currency, "2.00")}
          )

      assert {:ok, transaction} = post(legs)
      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 50

      assert_money(sum_money(Enum.map(pool, &balance_as_of(&1.id))), @zero, "50-leg journal")
    end
  end

  describe "amount scale" do
    # Both `amount` and `balance` are the `money_with_currency` composite, whose
    # numeric half is arbitrary-precision. There is no scale at which this stops
    # being exact, and no rounding to a currency's own digits either — 0.005 USD
    # survives as 0.005, neither 0.01 nor 0.00.
    test "amounts from 1e-12 to 1e29 round-trip through post and balance_as_of exactly" do
      for literal <- [
            "0.01",
            "0.005",
            "0.000000000001",
            "999999999999.99",
            "123456789012345678901234567890.12"
          ] do
        amount = Money.new!(@currency, literal)
        a = account("scale_a")
        b = account("scale_b")

        assert {:ok, _} =
                 post([
                   %{account_id: a.id, side: :debit, amount: amount},
                   %{account_id: b.id, side: :credit, amount: amount}
                 ])

        balance = balance_as_of(a.id)

        assert Decimal.equal?(balance.amount, amount.amount),
               "#{literal} came back as #{inspect(balance.amount)}"

        assert balance.currency == @currency
      end
    end

    test "a hundred sub-cent legs sum without drift" do
      a = account("drift_a")
      b = account("drift_b")
      leg_amount = Money.new!(@currency, "0.0000001")

      legs =
        Enum.map(1..100, fn _ -> %{account_id: a.id, side: :debit, amount: leg_amount} end) ++
          [%{account_id: b.id, side: :credit, amount: Money.mult!(leg_amount, 100)}]

      assert {:ok, _} = post(legs)

      assert Decimal.equal?(balance_as_of(a.id).amount, Decimal.new("0.00001")),
             "100 x 0.0000001 came back as #{inspect(balance_as_of(a.id).amount)}"
    end
  end

  describe "backdating within the Transaction path" do
    test "a backdated journal ripples through the account's later balance rows" do
      a = account("backdate_a")
      b = account("backdate_b")

      post!(
        [
          %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "10.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "10.00")}
        ],
        %{posted_at: ~U[2024-06-01 00:00:00.000000Z]}
      )

      post!(
        [
          %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "5.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "5.00")}
        ],
        %{posted_at: ~U[2024-01-01 00:00:00.000000Z]}
      )

      assert_money(
        balance_as_of(a.id, ~U[2024-03-01 00:00:00.000000Z]),
        Money.new!(@currency, "5.00"),
        "as of a date between the two journals"
      )

      assert_money(balance_as_of(a.id), Money.new!(@currency, "15.00"), "final balance")
    end

    test "balance_as_of is quantized to whole milliseconds" do
      # Entry ids are ULIDs, whose time half is a 48-bit MILLISECOND stamp — but
      # `Entry.timestamp` and the `balance_as_of` argument are both
      # `:utc_datetime_usec`. So `balance_as_of/1` cannot separate two instants
      # inside one millisecond: an entry stamped .000900 is already counted at
      # .000000. Not a conservation break — every entry is still counted exactly
      # once — but a real resolution limit of a microsecond-typed API, pinned
      # here so it stays a deliberate design point rather than a surprise.
      a = account("subms_a")
      b = account("subms_b")

      post!(
        [
          %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "7.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "7.00")}
        ],
        %{posted_at: ~U[2024-02-02 00:00:00.000900Z]}
      )

      assert_money(
        balance_as_of(a.id, ~U[2024-02-02 00:00:00.000000Z]),
        Money.new!(@currency, "7.00"),
        "an entry 900us in the future of the as-of instant is already counted"
      )

      # The previous millisecond does separate them.
      assert_money(
        balance_as_of(a.id, ~U[2024-02-01 23:59:59.999000Z]),
        @zero,
        "the previous millisecond must not see the entry"
      )
    end
  end

  describe "interleaved Transfer and Transaction writes" do
    test "a Transfer strictly later than every entry lands on top of the entry balances" do
      # The control. Both paths write into the same Balance table, and reading
      # back through `balance_as_of` has to see the union.
      a = account("mix_a")
      b = account("mix_b")

      post!(
        [
          %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "10.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "10.00")}
        ],
        %{posted_at: ~U[2024-01-01 00:00:00.000000Z]}
      )

      transfer!(b, a, Money.new!(@currency, "3.00"), %{
        timestamp: ~U[2024-01-02 00:00:00.000000Z]
      })

      assert_money(balance_as_of(a.id), Money.new!(@currency, "13.00"), "transfer after entries")
      assert_money(balance_as_of(b.id), Money.new!(@currency, "-13.00"), "transfer after entries")
    end

    test "an entry backdated past a Transfer ripples into the transfer's balance row" do
      # The mirror image of the bug below — and this direction works.
      # `:shift_balances_after` filters on
      # `transfer_id > ^after_ulid or entry_id > ^after_ulid`, so a new entry
      # shifts BOTH kinds of later balance row.
      a = account("mix2_a")
      b = account("mix2_b")

      transfer!(b, a, Money.new!(@currency, "3.00"), %{
        timestamp: ~U[2024-01-02 00:00:00.000000Z]
      })

      post!(
        [
          %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "10.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "10.00")}
        ],
        %{posted_at: ~U[2024-01-01 00:00:00.000000Z]}
      )

      assert_money(
        balance_as_of(a.id),
        Money.new!(@currency, "13.00"),
        "entry backdated past a transfer"
      )

      assert_money(
        balance_as_of(b.id),
        Money.new!(@currency, "-13.00"),
        "entry backdated past a transfer"
      )
    end

    test "a Transfer ordered before an entry ripples into the entry's balance row" do
      # Shrunk counterexample: one Transaction, one Transfer, one account on
      # each side, no concurrency, two legs.
      #
      #   VerifyTransfer used to ripple its delta through later balance rows with
      #   its own Balance `:adjust_balance` action, whose filter was
      #
      #       account_id in [^arg(:from_account_id), ^arg(:to_account_id)] and
      #         transfer_id > ^arg(:transfer_id)
      #
      #   An entry-keyed Balance row has `transfer_id IS NULL`, so
      #   `transfer_id > ...` is NULL and the row was never selected. The Entry
      #   path's `:shift_balances_after` covered both kinds of row
      #   (`transfer_id > ... or entry_id > ...`); `:adjust_balance` never was.
      #
      #   Result: the account's LATEST balance row stayed the stale entry-keyed
      #   one, and `balance_as_of` reported a balance short by the entire
      #   transfer — reconstruction from the journals no longer agreed with the
      #   reified balance. Not an upstream defect: upstream has only
      #   transfer-keyed rows, where this filter is complete. The multi-leg
      #   feature added entry-keyed rows and widened its own ripple
      #   (`:shift_balances_after`) to both kinds, but not Transfer's. Fixed
      #   by comparing both columns here too.
      a = account("bug_a")
      b = account("bug_b")

      post!(
        [
          %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "10.00")},
          %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "10.00")}
        ],
        %{posted_at: ~U[2024-01-02 00:00:00.000000Z]}
      )

      transfer!(b, a, Money.new!(@currency, "3.00"), %{
        timestamp: ~U[2024-01-01 00:00:00.000000Z]
      })

      # Entries fold to 10.00 debit; the transfer adds 3.00 (it used to report 10.00).
      assert_money(
        balance_as_of(a.id),
        Money.new!(@currency, "13.00"),
        "a Transfer ordered before an entry is missing from the account's balance"
      )
    end

    test "the same holds with no backdating at all, on a millisecond tie" do
      # The defect above needed no unusual input — only that the Transfer's ULID
      # sorts before an existing entry's. Entry and Transfer ids are ULIDs:
      # 48 bits of millisecond plus 80 RANDOM bits. Two writes inside one
      # millisecond therefore order by coin flip, and whenever the Transfer
      # lost it silently dropped itself from the account's balance.
      #
      # Measured before the fix: 10 of 20 trials wrong. 40 trials here, so the
      # test is deterministic for any practical purpose — unfixed, it could only
      # pass if 40 consecutive coin flips all landed the same way.
      wrong =
        Enum.count(1..40, fn _ ->
          a = account("tie_a")
          b = account("tie_b")
          instant = DateTime.utc_now() |> DateTime.truncate(:millisecond)

          post!(
            [
              %{account_id: a.id, side: :debit, amount: Money.new!(@currency, "10.00")},
              %{account_id: b.id, side: :credit, amount: Money.new!(@currency, "10.00")}
            ],
            %{posted_at: instant}
          )

          transfer!(b, a, Money.new!(@currency, "3.00"), %{timestamp: instant})

          not Money.equal?(balance_as_of(a.id), Money.new!(@currency, "13.00"))
        end)

      assert wrong == 0,
             "#{wrong}/40 same-millisecond Transfer-after-Transaction pairs reported a balance " <>
               "missing the transfer entirely"
    end
  end

  describe "reversal" do
    property "posting a journal and reversing it returns every account to where it was" do
      check all(indexed_legs <- balanced_journal(3), max_runs: 60) do
        pool = accounts(@pool, "reversal")
        original = post!(resolve(indexed_legs, pool))

        assert {:ok, _reversal} =
                 Transaction
                 |> Ash.Changeset.for_create(:reverse, %{original_transaction_id: original.id})
                 |> Ash.create()

        for acct <- pool do
          assert_money(
            balance_as_of(acct.id),
            @zero,
            "#{acct.identifier} did not return to zero after a reversal"
          )
        end
      end
    end
  end
end
