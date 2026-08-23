# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Property.TimeOrderingTest do
  @moduledoc """
  Time, ordering and backdating.

  Every historical balance question this library answers is answered by ULID
  ordering: `VerifyEntry` derives each Entry's id from its `timestamp`,
  `balance_as_of_ulid` reads the newest Balance row at or below a ULID, and
  `shift_balances_after` ripples a backdated entry's delta through the rows
  that sort after it.

  These properties attack that machinery from the outside — only through
  `Transaction.post` and `Account.balance_as_of` — and assert the one thing a
  ledger may never get wrong: the balance as of an instant is the fold over
  exactly the entries that happened at or before it, no matter what order the
  journals were written in.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias AshDoubleEntry.Test.{Account, Balance, Entry, Transaction}

  require Ash.Query

  @moduletag timeout: :infinity

  # Deliberately NOT `use DataCase`. A property holds its sandbox connection for
  # the whole `check all`, which is far longer than one ordinary test — past
  # `:ownership_timeout`, whose 60s default would reclaim the connection
  # mid-property and surface as a bogus "cannot find ownership process" failure.
  # Everything else matches `DataCase.setup_sandbox/1`.
  setup do
    start_supervised!(AshDoubleEntry.Test.Repo)

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(AshDoubleEntry.Test.Repo,
        shared: true,
        ownership_timeout: :infinity
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # A whole second, well inside the ULID's 48-bit millisecond range.
  # 2020-09-13T12:26:40.000000Z
  @base_ms 1_600_000_000_000

  # ---------------------------------------------------------------- fixtures

  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp account(identifier, currency \\ "USD") do
    Account
    |> Ash.Changeset.for_create(:open, %{identifier: uniq(identifier), currency: currency})
    |> Ash.create!()
  end

  defp post(entries, attrs) do
    Transaction
    |> Ash.Changeset.for_create(:post, Map.put(attrs, :entries, entries))
    |> Ash.create()
  end

  defp post!(entries, attrs \\ %{}) do
    {:ok, transaction} = post(entries, attrs)
    transaction
  end

  # A plain two-leg journal: `cents` debited from `debit`, credited to `credit`.
  # `at` of `nil` leaves `posted_at` to its default.
  defp journal!(debit, credit, cents, at) do
    legs = [
      %{account_id: debit.id, side: :debit, amount: money(cents)},
      %{account_id: credit.id, side: :credit, amount: money(cents)}
    ]

    case at do
      nil -> post!(legs)
      %DateTime{} -> post!(legs, %{posted_at: at})
    end
  end

  # The released two-leg primitive: `from` is debited, `to` is credited.
  defp transfer!(from, to, cents, at) do
    AshDoubleEntry.Test.Transfer
    |> Ash.Changeset.for_create(:transfer, %{
      amount: money(cents),
      from_account_id: from.id,
      to_account_id: to.id,
      timestamp: at
    })
    |> Ash.create!()
  end

  defp money(cents), do: Money.new!(:USD, Decimal.new(1, abs(cents), -2))

  # `@base_ms + offset` as a `utc_datetime_usec`.
  defp at(offset_ms), do: DateTime.from_unix!(@base_ms + offset_ms, :millisecond)

  defp balance_at(account, %DateTime{} = timestamp) do
    Account
    |> Ash.get!(account.id, load: [balance_as_of: %{timestamp: timestamp}], authorize?: false)
    |> Map.get(:balance_as_of)
  end

  defp cents_of(%Money{} = money) do
    money |> Money.to_decimal() |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
  end

  # The generated Balance read requires pagination, hence the explicit page.
  defp balance_rows(account) do
    Balance
    |> Ash.Query.filter(account_id == ^account.id)
    |> Ash.Query.load(:effective_ulid)
    |> Ash.read!(authorize?: false, page: [limit: 500])
    |> Map.get(:results)
    |> Enum.sort_by(& &1.effective_ulid)
  end

  # Every run of a `check all` shares one sandbox transaction, so without this
  # the ledger grows monotonically across runs and each `shift_balances_after`
  # UPDATE re-scans a bigger `balances` table: run time becomes quadratic in
  # `max_runs` and swings by two orders of magnitude with the seed. Clearing
  # between runs makes each run cost the same as the first.
  defp reset_ledger! do
    for table <- ~w(balances entries transfers transactions accounts) do
      AshDoubleEntry.Test.Repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  defp count(resource, account) do
    resource
    |> Ash.Query.filter(account_id == ^account.id)
    |> Ash.count!(authorize?: false)
  end

  # --------------------------------------------------------------- generators

  # Whole-millisecond slots one second apart, so that a probe can always sit
  # strictly between two of them. Slot collisions are allowed on purpose:
  # several journals sharing an instant is the interesting case.
  defp slot, do: integer(0..8)

  defp cents, do: integer(1..500_000)

  defp journal_spec, do: tuple({slot(), cents()})

  defp journal_specs(range \\ 1..6), do: list_of(journal_spec(), length: range)

  # One leg of a multi-leg journal: which account of the pool, which side, how
  # much. Zero is included on purpose — a zero-amount leg is legal.
  defp leg_spec, do: tuple({integer(0..2), member_of([:debit, :credit]), integer(0..200_000)})

  # The generated legs plus one leg on `balancer` that makes the journal
  # balance. The balancing leg is `credit 0` when the legs already balance,
  # which is both legal and the minimal thing to add.
  defp legs(accounts, balancer, leg_specs) do
    diff =
      Enum.reduce(leg_specs, 0, fn
        {_, :debit, c}, acc -> acc + c
        {_, :credit, c}, acc -> acc - c
      end)

    balancing =
      if diff >= 0 do
        %{account_id: balancer.id, side: :credit, amount: money(diff)}
      else
        %{account_id: balancer.id, side: :debit, amount: money(-diff)}
      end

    Enum.map(leg_specs, fn {idx, side, c} ->
      %{account_id: Enum.at(accounts, idx).id, side: side, amount: money(c)}
    end) ++ [balancing]
  end

  # `{account_index, signed_cents}` for every leg, balancing leg included.
  # The balancer's index is `length(accounts)`, i.e. 3 for a pool of 3.
  defp deltas(leg_specs) do
    diff =
      Enum.reduce(leg_specs, 0, fn
        {_, :debit, c}, acc -> acc + c
        {_, :credit, c}, acc -> acc - c
      end)

    Enum.map(leg_specs, fn
      {idx, :debit, c} -> {idx, c}
      {idx, :credit, c} -> {idx, -c}
    end) ++ [{3, -diff}]
  end

  # Every probe instant worth asking about for a set of slots: half a second
  # before each slot, exactly on each slot, half a second after the last.
  defp probes(slots) do
    slots = Enum.sort(Enum.uniq(slots))

    Enum.flat_map(slots, fn s -> [s * 1000 - 500, s * 1000] end) ++
      [List.last(slots) * 1000 + 500]
  end

  defp expected_cents(specs, probe_ms) do
    specs
    |> Enum.filter(fn {slot, _} -> slot * 1000 <= probe_ms end)
    |> Enum.map(fn {_, c} -> c end)
    |> Enum.sum()
  end

  # ---------------------------------------------------------------- properties
  #
  # `max_runs` is tuned, not arbitrary: at the counts below the file runs in
  # about a minute against a local Postgres. `reset_ledger!/0` at the top of
  # every property body is what keeps that cost linear in the run count — see
  # its comment — so these can be raised for a soak without the run time
  # exploding, which is exactly what happened before it was there.

  describe "balance_as_of is the fold over entries at or before the instant" do
    property "for journals written in an arbitrary order, at arbitrary instants" do
      check all(
              specs <- journal_specs(),
              write_order <- shuffled_indices(length(specs)),
              max_runs: 200
            ) do
        reset_ledger!()
        cash = account("cash")
        revenue = account("revenue")

        for i <- write_order do
          {slot, c} = Enum.at(specs, i)
          journal!(cash, revenue, c, at(slot * 1000))
        end

        for probe_ms <- probes(Enum.map(specs, &elem(&1, 0))) do
          expected = expected_cents(specs, probe_ms)
          # Bound once: an `assert x, msg` message is evaluated eagerly, so
          # putting the query in the message would run it on every pass.
          actual = cents_of(balance_at(cash, at(probe_ms)))

          assert actual == expected,
                 """
                 cash balance as of +#{probe_ms}ms was #{actual}, expected #{expected}
                 specs (slot, cents): #{inspect(specs)}
                 write order: #{inspect(write_order)}
                 """

          assert cents_of(balance_at(revenue, at(probe_ms))) == -expected
        end
      end
    end

    property "and for a fresh account, before every entry, the balance is zero" do
      check all(specs <- journal_specs(), max_runs: 120) do
        reset_ledger!()
        cash = account("cash")
        revenue = account("revenue")

        for {slot, c} <- specs, do: journal!(cash, revenue, c, at(slot * 1000))

        assert cents_of(balance_at(cash, at(-10_000))) == 0
        assert cents_of(balance_at(revenue, at(-10_000))) == 0
      end
    end
  end

  describe "the final state does not depend on the order journals were written in" do
    # The strongest statement of what the `:shift_balances_after` ripple is for.
    # Distinct milliseconds, so that ULID order *is* time order and the whole
    # running-balance sequence — not just the total — has to match.

    property "two write orders produce the same running-balance sequence" do
      check all(
              slots <- uniq_list_of(integer(0..20), length: 2..6),
              amounts <- list_of(cents(), length: length(slots)),
              order_a <- shuffled_indices(length(slots)),
              order_b <- shuffled_indices(length(slots)),
              max_runs: 120
            ) do
        specs = Enum.zip(slots, amounts)

        run = fn order ->
          # Each order starts from an empty ledger, so the two runs are
          # compared on their own terms and not through each other's rows.
          reset_ledger!()
          cash = account("cash")
          revenue = account("revenue")

          for i <- order do
            {slot, c} = Enum.at(specs, i)
            journal!(cash, revenue, c, at(slot * 1000))
          end

          {Enum.map(balance_rows(cash), &cents_of(&1.balance)),
           Enum.map(balance_rows(revenue), &cents_of(&1.balance))}
        end

        a = run.(order_a)
        b = run.(order_b)

        assert a == b,
               """
               write order changed the balance history.
               specs (slot, cents): #{inspect(specs)}
               order A #{inspect(order_a)} -> #{inspect(a)}
               order B #{inspect(order_b)} -> #{inspect(b)}
               """

        # and the sequence really is the running sum, in time order
        expected =
          specs
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_reduce(0, fn {_, c}, acc -> {acc + c, acc + c} end)
          |> elem(0)

        assert elem(a, 0) == expected
      end
    end
  end

  describe "several journals sharing one instant" do
    property "each is counted exactly once, and the shared instant includes them all" do
      check all(amounts <- list_of(cents(), length: 2..8), max_runs: 150) do
        reset_ledger!()
        cash = account("cash")
        revenue = account("revenue")
        instant = at(5_000)

        for c <- amounts, do: journal!(cash, revenue, c, instant)

        total = Enum.sum(amounts)

        assert cents_of(balance_at(cash, instant)) == total
        assert cents_of(balance_at(cash, at(4_999))) == 0
        assert cents_of(balance_at(cash, at(5_001))) == total

        # exactly one Entry and one Balance row per journal per account
        assert count(Entry, cash) == length(amounts)
        assert count(Balance, cash) == length(amounts)
        assert length(balance_rows(cash)) == length(amounts)
      end
    end
  end

  describe "an account on both sides of the same journal" do
    # Two legs, same account, same instant — so two Balance rows whose ULIDs
    # share a millisecond and are ordered only by their random suffix. If the
    # ripple mishandles a row it inserted moments earlier in the same journal,
    # a self-cancelling journal will not cancel.

    property "a self-cancelling leg pair leaves every balance untouched" do
      check all(
              specs <- journal_specs(1..4),
              self_specs <- journal_specs(1..3),
              max_runs: 150
            ) do
        reset_ledger!()
        cash = account("cash")
        revenue = account("revenue")

        for {slot, c} <- specs, do: journal!(cash, revenue, c, at(slot * 1000))

        for {slot, c} <- self_specs do
          post!(
            [
              %{account_id: cash.id, side: :debit, amount: money(c)},
              %{account_id: cash.id, side: :credit, amount: money(c)}
            ],
            %{posted_at: at(slot * 1000)}
          )
        end

        for probe_ms <- probes(Enum.map(specs ++ self_specs, &elem(&1, 0))) do
          assert cents_of(balance_at(cash, at(probe_ms))) == expected_cents(specs, probe_ms)
        end
      end
    end
  end

  describe "backdating into a populated account" do
    property "a journal backdated into the middle repairs every later balance" do
      check all(
              slots <- uniq_list_of(integer(0..20), length: 3..8),
              amounts <- list_of(cents(), length: length(slots)),
              insert_slot <- integer(0..20),
              insert_cents <- cents(),
              max_runs: 150
            ) do
        reset_ledger!()
        cash = account("cash")
        revenue = account("revenue")

        specs = Enum.zip(slots, amounts)

        # Fill the account in time order first, so the backdated journal really
        # is landing behind existing rows rather than merely being out of order.
        for {slot, c} <- Enum.sort_by(specs, &elem(&1, 0)) do
          journal!(cash, revenue, c, at(slot * 1000))
        end

        journal!(cash, revenue, insert_cents, at(insert_slot * 1000))

        all_specs = [{insert_slot, insert_cents} | specs]

        for probe_ms <- probes(Enum.map(all_specs, &elem(&1, 0))) do
          assert cents_of(balance_at(cash, at(probe_ms))) == expected_cents(all_specs, probe_ms),
                 """
                 backdating {#{insert_slot}, #{insert_cents}} into #{inspect(Enum.sort(specs))}
                 broke the balance as of +#{probe_ms}ms
                 """
        end
      end
    end
  end

  describe "balanced N-leg journals with account reuse" do
    # The general shape: 2..13 legs, random sides, random amounts (zero
    # included — a zero leg is legal), drawn from a small pool of accounts so
    # that the SAME account is routinely debited and credited inside one
    # journal. Several such journals at arbitrary instants, written in
    # arbitrary order. Every account's balance at every probe must still be
    # the fold over its own legs at or before that instant.

    property "every account's balance at every instant is the fold over its own legs" do
      check all(
              journals <-
                list_of(tuple({slot(), list_of(leg_spec(), length: 1..12)}), length: 1..4),
              order <- shuffled_indices(length(journals)),
              max_runs: 100
            ) do
        reset_ledger!()
        accounts = Enum.map(1..3, fn i -> account("pool#{i}") end)
        balancer = account("balancer")

        for i <- order do
          {slot, leg_specs} = Enum.at(journals, i)
          post!(legs(accounts, balancer, leg_specs), %{posted_at: at(slot * 1000)})
        end

        for probe_ms <- probes(Enum.map(journals, &elem(&1, 0))),
            {acct, idx} <- Enum.with_index(accounts ++ [balancer]) do
          expected =
            journals
            |> Enum.filter(fn {slot, _} -> slot * 1000 <= probe_ms end)
            |> Enum.flat_map(fn {_, leg_specs} -> deltas(leg_specs) end)
            |> Enum.filter(fn {i, _} -> i == idx end)
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()

          actual = cents_of(balance_at(acct, at(probe_ms)))

          assert actual == expected,
                 """
                 account ##{idx} as of +#{probe_ms}ms was #{actual}, expected #{expected}
                 journals: #{inspect(journals)}
                 write order: #{inspect(order)}
                 """
        end
      end
    end

    test "a fifty-leg journal, backdated behind an existing one, still folds correctly" do
      accounts = Enum.map(1..3, fn i -> account("wide#{i}") end)
      balancer = account("wide_balancer")

      leg_specs =
        Enum.map(1..50, fn i ->
          {rem(i, 3), if(rem(i, 2) == 0, do: :debit, else: :credit), i * 11}
        end)

      post!(legs(accounts, balancer, [{0, :debit, 1_000}]), %{posted_at: at(20_000)})
      post!(legs(accounts, balancer, leg_specs), %{posted_at: at(10_000)})

      for {acct, idx} <- Enum.with_index(accounts ++ [balancer]) do
        wide =
          deltas(leg_specs)
          |> Enum.filter(&(elem(&1, 0) == idx))
          |> Enum.map(&elem(&1, 1))
          |> Enum.sum()

        later =
          deltas([{0, :debit, 1_000}])
          |> Enum.filter(&(elem(&1, 0) == idx))
          |> Enum.map(&elem(&1, 1))
          |> Enum.sum()

        assert cents_of(balance_at(acct, at(5_000))) == 0
        assert cents_of(balance_at(acct, at(10_000))) == wide
        assert cents_of(balance_at(acct, at(30_000))) == wide + later
      end
    end
  end

  describe "amount scale" do
    # 0.01 up to a trillion dollars, in one account, backdated in random order.

    property "balances stay exact across the whole representable range" do
      check all(
              slots <- uniq_list_of(integer(0..12), length: 2..6),
              exponents <- list_of(integer(0..14), length: length(slots)),
              order <- shuffled_indices(length(slots)),
              max_runs: 100
            ) do
        reset_ledger!()

        specs =
          Enum.zip(slots, Enum.map(exponents, fn e -> Integer.pow(10, e) end))

        cash = account("cash")
        revenue = account("revenue")

        for i <- order do
          {slot, c} = Enum.at(specs, i)
          journal!(cash, revenue, c, at(slot * 1000))
        end

        for probe_ms <- probes(slots) do
          assert cents_of(balance_at(cash, at(probe_ms))) == expected_cents(specs, probe_ms)
        end
      end
    end
  end

  # --------------------------------------------------------------- edge cases

  describe "edge cases" do
    test "a journal backdated before every existing entry" do
      cash = account("cash")
      revenue = account("revenue")

      journal!(cash, revenue, 1_000, at(10_000))
      journal!(cash, revenue, 2_000, at(20_000))
      journal!(cash, revenue, 500, at(0))

      assert cents_of(balance_at(cash, at(-1))) == 0
      assert cents_of(balance_at(cash, at(0))) == 500
      assert cents_of(balance_at(cash, at(10_000))) == 1_500
      assert cents_of(balance_at(cash, at(20_000))) == 3_500
      assert Enum.map(balance_rows(cash), &cents_of(&1.balance)) == [500, 1_500, 3_500]
    end

    test "a journal dated in the future is invisible until its instant arrives" do
      cash = account("cash")
      revenue = account("revenue")

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      journal!(cash, revenue, 700, future)

      assert cents_of(balance_at(cash, DateTime.utc_now())) == 0
      assert cents_of(balance_at(cash, future)) == 700

      # and `balance_as_of` with no argument (defaulting to now) agrees
      loaded = Ash.get!(Account, cash.id, load: :balance_as_of, authorize?: false)
      assert cents_of(loaded.balance_as_of) == 0
    end

    test "posted_at defaulted matches posted_at supplied as the same instant" do
      supplied = account("supplied")
      defaulted = account("defaulted")
      revenue = account("revenue")

      # 5ms of slack: `balance_as_of` only resolves to the millisecond (see the
      # "known defects" section), so an instant in the same millisecond as the
      # post would not be a clean "before".
      before = DateTime.add(DateTime.utc_now(), -5, :millisecond)
      journal!(defaulted, revenue, 900, nil)
      journal!(supplied, revenue, 900, DateTime.utc_now())

      # Both were stamped between `before` and now, and both are visible now.
      assert cents_of(balance_at(defaulted, DateTime.utc_now())) == 900
      assert cents_of(balance_at(supplied, DateTime.utc_now())) == 900
      assert cents_of(balance_at(defaulted, before)) == 0

      [entry] = Entry |> Ash.Query.filter(account_id == ^defaulted.id) |> Ash.read!()
      refute is_nil(entry.timestamp)
      assert DateTime.compare(entry.timestamp, before) in [:gt, :eq]
    end

    test "two journals in the same millisecond but different microseconds both land" do
      cash = account("cash")
      revenue = account("revenue")

      earlier = DateTime.from_unix!(@base_ms * 1000 + 100, :microsecond)
      later = DateTime.from_unix!(@base_ms * 1000 + 900, :microsecond)

      journal!(cash, revenue, 300, earlier)
      journal!(cash, revenue, 400, later)

      # Both are inside the same millisecond, so the millisecond as a whole
      # carries their sum, and each is written exactly once.
      assert cents_of(balance_at(cash, later)) == 700
      assert cents_of(balance_at(cash, at(1))) == 700
      assert cents_of(balance_at(cash, at(-1))) == 0
      assert count(Entry, cash) == 2
      assert count(Balance, cash) == 2
    end

    test "a backdated journal on an account with many existing entries" do
      cash = account("cash")
      revenue = account("revenue")

      for slot <- 1..30, do: journal!(cash, revenue, 100, at(slot * 1000))

      assert cents_of(balance_at(cash, at(31_000))) == 3_000

      journal!(cash, revenue, 55, at(15_500))

      assert cents_of(balance_at(cash, at(15_000))) == 1_500
      assert cents_of(balance_at(cash, at(15_500))) == 1_555
      assert cents_of(balance_at(cash, at(16_000))) == 1_655
      assert cents_of(balance_at(cash, at(31_000))) == 3_055

      expected =
        Enum.map(1..15, &(&1 * 100)) ++ [1_555] ++ Enum.map(16..30, &(&1 * 100 + 55))

      assert Enum.map(balance_rows(cash), &cents_of(&1.balance)) == expected
    end

    test "a reversal is dated now, not at the original's instant" do
      cash = account("cash")
      revenue = account("revenue")

      original = journal!(cash, revenue, 1_200, at(0))

      {:ok, _reversal} =
        Transaction
        |> Ash.Changeset.for_create(:reverse, %{original_transaction_id: original.id})
        |> Ash.create()

      # The original still stands as of its own instant...
      assert cents_of(balance_at(cash, at(0))) == 1_200
      # ...and the reversal cancels it only from the moment it was posted.
      assert cents_of(balance_at(cash, DateTime.utc_now())) == 0
    end
  end

  # ------------------------------------------------- demonstrated library bugs

  describe "known defects" do
    @tag :library_bug
    test "balance_as_of ignores sub-millisecond precision and over-counts" do
      # `balance_as_of` is documented to take a `utc_datetime_usec`, and Entry
      # `timestamp` is a `utc_datetime_usec` too. But
      # `AshDoubleEntry.Account.Calculations.BalanceAsOf.ulid/1` calls
      # `ULID.generate_last/1`, which does `DateTime.to_unix(t, :millisecond)`
      # and then fills the low 80 bits with 0xFF. Every instant inside a
      # millisecond therefore maps to the SAME comparator: the last possible
      # ULID of that millisecond.
      #
      # So asking for the balance at 12:26:40.000100 returns a number that
      # includes an entry stamped 12:26:40.000900 — an entry that had not
      # happened yet at the instant asked about.
      cash = account("cash")
      revenue = account("revenue")

      early = DateTime.from_unix!(@base_ms * 1000 + 100, :microsecond)
      late = DateTime.from_unix!(@base_ms * 1000 + 900, :microsecond)

      journal!(cash, revenue, 300, early)
      journal!(cash, revenue, 400, late)

      assert cents_of(balance_at(cash, early)) == 300,
             "as of #{inspect(early)} only the 300 entry has happened, but the balance " <>
               "reports #{cents_of(balance_at(cash, early))}"
    end

    test "a backdated Entry DOES ripple through a later transfer-keyed balance" do
      # The control for the next test. `:shift_balances_after`'s filter is
      # `transfer_id > after_ulid or entry_id > after_ulid`, so a backdated
      # Entry repairs later rows of BOTH kinds. This direction is sound.
      cash = account("cash")
      revenue = account("revenue")

      transfer!(revenue, cash, 1_000, at(10_000))
      journal!(cash, revenue, 300, at(5_000))

      assert cents_of(balance_at(cash, at(7_000))) == 300
      assert cents_of(balance_at(cash, at(20_000))) == 1_300
    end

    test "a backdated Transfer ripples through later entry-keyed balances too" do
      # The mirror image of the test above. It used to lose money:
      #
      # `:adjust_balance` — the ripple VerifyTransfer runs — filtered on
      # `account_id in [from, to] and transfer_id > ^arg(:transfer_id)`. An
      # entry-keyed Balance row has `transfer_id` NULL, so `NULL > ulid` is
      # NULL and the row was never selected. `:shift_balances_after`, added for
      # the Entry path, deliberately covers both kinds
      # (`transfer_id > ... or entry_id > ...`); `:adjust_balance` now does too.
      #
      # Mixing the two paths on one account is a configuration the library
      # explicitly supports: `Balance` takes both a `transfer_resource` and an
      # `entry_resource`, `BalanceAsOfUlid` documents itself as reading "the
      # union of transfer-keyed and entry-keyed Balance rows", and
      # `maybe_add_shift_action`'s own comment says "one account can receive
      # both kinds". It is also the unavoidable shape of any application
      # migrating from `Transfer` to `Transaction`.
      cash = account("cash")
      revenue = account("revenue")

      journal!(cash, revenue, 1_000, at(10_000))
      transfer!(revenue, cash, 300, at(5_000))

      # the transfer's own row is right...
      assert cents_of(balance_at(cash, at(7_000))) == 300

      # ...and the entry-keyed row that sorts after it is shifted as well, so
      # the account's CURRENT balance includes the transfer.
      assert cents_of(balance_at(cash, at(20_000))) == 1_300,
             "the backdated transfer's 300 never reached the later entry-keyed balance"
    end

    @tag :library_bug
    test "a posted_at before 1970 wraps the ULID's unsigned timestamp and sorts last" do
      # `ULID.bingenerate/1` builds `<<timestamp::unsigned-size(48), ...>>`. A
      # pre-epoch `DateTime.to_unix(t, :millisecond)` is NEGATIVE, and Erlang
      # truncates it into the unsigned field two's-complement — so 1969 becomes
      # a ULID near 2^48, sorting AFTER every modern entry instead of before it.
      #
      # The write succeeds and reports no error; the ledger's history is simply
      # wrong from then on. A general-purpose ledger has to either support
      # pre-1970 dates or refuse them, not silently reorder history.
      cash = account("cash")
      revenue = account("revenue")

      ancient = ~U[1969-07-20 20:17:40.000000Z]

      journal!(cash, revenue, 100, at(0))
      journal!(cash, revenue, 900, ancient)

      assert cents_of(balance_at(cash, ancient)) == 900
      assert cents_of(balance_at(cash, at(0))) == 1_000

      assert Enum.map(balance_rows(cash), &cents_of(&1.balance)) == [900, 1_000],
             "the 1969 entry did not sort before the 2020 one"
    end
  end

  # ------------------------------------------------------------------ helpers

  # A permutation of 0..n-1, generated so that stream_data can shrink it back
  # toward the identity order.
  defp shuffled_indices(0), do: constant([])

  defp shuffled_indices(n) do
    list_of(integer(0..1_000_000), length: n)
    |> map(fn keys ->
      0..(n - 1)
      |> Enum.zip(keys)
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))
    end)
  end
end
