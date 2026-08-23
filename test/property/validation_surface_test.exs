# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.ValidationSurfacePropertyTest do
  @moduledoc """
  Property tests for `Transaction.post`'s validation surface.

  `:post` takes a LIST. Everything this file asks follows from that:

    * a rejection has to say WHICH element of the list it is about,
    * which element is at fault must not depend on where in the list it sits,
    * no rejection may be reachable only after something has been written,
    * and a well-formed journal must not be refused for a shape the library
      never said was illegal.

  Tests tagged `:library_bug` pin defects this file found, reduced to
  deterministic cases, that are not yet fixed; `test_helper.exs` excludes them
  from an ordinary run, and `mix test --include library_bug` runs them.
  """
  use DataCase, async: false
  use ExUnitProperties

  # Heavy properties: ~12 s alone, but a loaded host pushed them past ExUnit's 60 s default.
  @moduletag timeout: 600_000
  @moduletag ownership_timeout: :infinity

  alias AshDoubleEntry.Test.{Account, Balance, Entry, Transaction}

  # ── fixtures (same idioms as test/transaction_cascade_test.exs) ────────────

  defp account(identifier, currency) do
    Account
    |> Ash.Changeset.for_create(:open, %{identifier: identifier, currency: currency})
    |> Ash.create!()
  end

  defp pool(size, currency) do
    for _ <- 1..size do
      account("pool_#{System.unique_integer([:positive])}", currency).id
    end
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
    |> Enum.map(&{&1.__struct__, Map.get(&1, :field) || Map.get(&1, :input), &1.path})
  end

  defp count(resource) do
    resource |> Ash.Query.new() |> Ash.count!(authorize?: false)
  end

  defp row_counts, do: {count(Transaction), count(Entry), count(Balance)}

  # ── generators ────────────────────────────────────────────────────────────

  # Amounts across scales: exactly zero, sub-dollar, ordinary, and large enough
  # that a naive integer representation would be in trouble.
  defp cents do
    frequency([
      {1, constant(0)},
      {4, integer(1..999)},
      {3, integer(1_000..9_999_999)},
      {2, integer(10_000_000..999_999_999_999)}
    ])
  end

  defp money(currency, cents) do
    Money.new!(currency, Decimal.div(Decimal.new(cents), 100))
  end

  defp key_style, do: member_of([:atom, :string, :mixed])

  defp maybe_tag do
    one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 8)])
  end

  # A leg in one of the three spellings a caller can plausibly send: all-atom
  # keys, all-string keys (a JSON body handed straight through), and a mixture.
  defp leg(account_id, side, amount, style, tag) do
    fields =
      [account_id: account_id, side: side, amount: amount] ++
        if(tag, do: [line_item_id: tag], else: [])

    case style do
      :atom ->
        Map.new(fields)

      :string ->
        Map.new(fields, fn {k, v} -> {Atom.to_string(k), stringify(k, v)} end)

      :mixed ->
        Map.new(fields, fn
          {:side, v} -> {"side", stringify(:side, v)}
          {:line_item_id, v} -> {"line_item_id", v}
          {k, v} -> {k, v}
        end)
    end
  end

  defp stringify(:side, side), do: Atom.to_string(side)
  defp stringify(_key, value), do: value

  # A balanced journal of 2..12 legs. The credit side is a random partition of
  # the debit total, so zero-valued legs, lopsided leg counts and repeated
  # accounts all arise on their own rather than being special-cased.
  defp balanced_journal(account_ids, currency) do
    gen all(
          debits <- list_of(cents(), min_length: 1, max_length: 6),
          credit_count <- integer(1..6),
          cuts <- list_of(integer(0..Enum.sum(debits)), length: credit_count - 1),
          accounts <-
            list_of(member_of(account_ids), length: length(debits) + credit_count),
          styles <- list_of(key_style(), length: length(debits) + credit_count),
          tags <- list_of(maybe_tag(), length: length(debits) + credit_count),
          order <- list_of(integer(), length: length(debits) + credit_count)
        ) do
      credits = partition(Enum.sum(debits), cuts)

      sides =
        List.duplicate(:debit, length(debits)) ++ List.duplicate(:credit, length(credits))

      [debits ++ credits, sides, accounts, styles, tags]
      |> Enum.zip()
      |> Enum.map(fn {amount, side, account_id, style, tag} ->
        leg(account_id, side, money(currency, amount), style, tag)
      end)
      |> shuffle(order)
    end
  end

  defp partition(total, cuts) do
    ([0] ++ Enum.sort(cuts) ++ [total])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [low, high] -> high - low end)
  end

  defp shuffle(list, order),
    do: Enum.sort_by(Enum.zip(list, order), &elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  # A journal whose legs are interchangeable: `pairs` debits and `pairs` credits,
  # every one the same amount. Injecting a fault at a random index then varies the
  # INDEX and nothing else, which is what the "names its leg" property is about.
  defp uniform_journal(account_ids, currency) do
    gen all(
          pairs <- integer(2..5),
          amount <- integer(100..999_999),
          accounts <- list_of(member_of(account_ids), length: pairs * 2),
          order <- list_of(integer(), length: pairs * 2)
        ) do
      sides = List.duplicate(:debit, pairs) ++ List.duplicate(:credit, pairs)

      Enum.zip(sides, accounts)
      |> Enum.map(fn {side, account_id} ->
        %{account_id: account_id, side: side, amount: money(currency, amount)}
      end)
      |> shuffle(order)
    end
  end

  # ── fault injection ───────────────────────────────────────────────────────

  # Kinds the library validates per leg. Each keeps the journal otherwise valid,
  # so the named check really is the one that rejects it — a fault that also
  # unbalanced the journal would be caught by the balance check first and prove
  # nothing about leg naming.
  @per_leg_kinds [:unknown_key, :owned_key, :unknown_account, :negative_amount]

  # Kinds `validate_shape/1` handles. Same per-leg nature — `side` and `amount`
  # belong to exactly one leg — but see the `:library_bug` tests below.
  @shape_kinds [:bad_side, :no_amount, :non_money_amount]

  defp inject(legs, index, :unknown_key),
    do: List.update_at(legs, index, &Map.put(&1, :no_such_field, "x"))

  defp inject(legs, index, :owned_key),
    do: List.update_at(legs, index, &Map.put(&1, :timestamp, ~U[2001-01-01 00:00:00.000000Z]))

  defp inject(legs, index, :unknown_account),
    do: List.update_at(legs, index, &Map.put(&1, :account_id, Ash.UUID.generate()))

  defp inject(legs, index, :bad_side),
    do: List.update_at(legs, index, &Map.put(&1, :side, :sideways))

  defp inject(legs, index, :no_amount),
    do: List.update_at(legs, index, &Map.delete(&1, :amount))

  defp inject(legs, index, :non_money_amount),
    do: List.update_at(legs, index, &Map.put(&1, :amount, "10.00"))

  defp inject(legs, index, :negative_amount) do
    leg = Enum.at(legs, index)

    # Move the flipped magnitude onto another leg of the same side, so Σdebits
    # still equals Σcredits and only the sign is wrong.
    {other, other_index} =
      legs
      |> Enum.with_index()
      |> Enum.find(fn {l, i} -> i != index and l.side == leg.side end)

    legs
    |> List.replace_at(index, %{leg | amount: Money.mult!(leg.amount, -1)})
    |> List.replace_at(other_index, %{
      other
      | amount: Money.add!(other.amount, Money.mult!(leg.amount, 2))
    })
  end

  defp fault_signature(:unknown_key), do: {Ash.Error.Invalid.NoSuchInput, :no_such_field}
  defp fault_signature(:owned_key), do: {Ash.Error.Changes.InvalidAttribute, :timestamp}
  defp fault_signature(:unknown_account), do: {Ash.Error.Changes.InvalidAttribute, :account_id}
  defp fault_signature(:negative_amount), do: {Ash.Error.Changes.InvalidAttribute, :amount}

  setup do
    %{usd: pool(4, "USD"), eur: pool(3, "EUR")}
  end

  # ── 1. every rejection names its leg ──────────────────────────────────────

  describe "every rejection names its leg" do
    property "a per-leg fault at a random index is reported at [:entries, index]", %{usd: usd} do
      check all(
              legs <- uniform_journal(usd, :USD),
              kind <- member_of(@per_leg_kinds),
              index <- integer(0..(length(legs) - 1)),
              max_runs: 400
            ) do
        result = post(inject(legs, index, kind))

        assert {:error, %Ash.Error.Invalid{}} = result

        {module, field} = fault_signature(kind)

        assert {module, field, [:entries, index]} in leaf_summaries(result),
               """
               a #{kind} at leg #{index} of #{length(legs)} did not name its leg.
               leaves: #{inspect(leaf_summaries(result))}
               """
      end
    end

    # `validate_currency/1` only lets a journal through when every leg agrees, so
    # a currency the ACCOUNTS do not hold is necessarily wrong on every leg. All
    # of them must be named, not just the first one found.
    property "a journal in a currency none of its accounts holds names every leg", %{usd: usd} do
      check all(legs <- balanced_journal(usd, :EUR), max_runs: 150) do
        result = post(legs)

        assert {:error, %Ash.Error.Invalid{}} = result

        named =
          for {_module, :amount, [:entries, i]} <- leaf_summaries(result), do: i

        assert Enum.sort(named) == Enum.to_list(0..(length(legs) - 1))
      end
    end

    # A journal-level fault has no single leg to blame, so an empty path is the
    # honest answer. Pinned so that "no path" stays a deliberate choice for these
    # two and does not quietly spread to checks that CAN name a leg.
    test "an unbalanced journal and a mixed-currency journal report no leg, by nature", %{
      usd: [a, b | _]
    } do
      unbalanced =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: b, side: :credit, amount: Money.new!(:USD, "9.00")}
        ])

      assert [{Ash.Error.Changes.InvalidChanges, nil, []}] = leaf_summaries(unbalanced)

      mixed =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "10.00")},
          %{account_id: b, side: :credit, amount: Money.new!(:EUR, "10.00")}
        ])

      assert [{Ash.Error.Changes.InvalidChanges, nil, []}] = leaf_summaries(mixed)
    end

    # ── LIBRARY BUG: shape faults are per-leg but are reported journal-wide ──
    #
    # `side` and `amount` live on exactly one leg, and every other per-leg check
    # in this extension reports at `[:entries, index]` — negative amount, unknown
    # key, transaction-owned key, unknown account, currency-vs-account. The three
    # `validate_shape/1` faults are the only ones that do not: they come back as
    # a bare `Ash.Error.Changes.InvalidChanges` with `path: []` and a message that
    # says "Every entry must ...", naming none of them.
    #
    # Shrunk counterexample (deterministic, below): a 2-leg journal whose SECOND
    # leg has `side: :sideways` yields exactly
    #   [{Ash.Error.Changes.InvalidChanges, nil, []}]
    # so a caller with a 50-leg import batch is told only that one of the fifty
    # is wrong. Pre-existing — `validate_shape/1` is unchanged at b43cb8c and
    # reports the same pathless error there.
    @tag :library_bug
    property "shape faults name their leg too", %{usd: usd} do
      check all(
              legs <- uniform_journal(usd, :USD),
              kind <- member_of(@shape_kinds),
              index <- integer(0..(length(legs) - 1)),
              max_runs: 250
            ) do
        result = post(inject(legs, index, kind))

        assert {:error, _} = result

        assert Enum.any?(leaf_summaries(result), fn {_m, _f, path} ->
                 path == [:entries, index]
               end),
               """
               a #{kind} at leg #{index} of #{length(legs)} was reported with no leg path.
               leaves: #{inspect(leaf_summaries(result))}
               """
      end
    end

    @tag :library_bug
    test "shrunk: a bad side on leg 1 of 2 is reported with an empty path", %{usd: [a, b | _]} do
      result =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "1.00")},
          %{account_id: b, side: :sideways, amount: Money.new!(:USD, "1.00")}
        ])

      assert Enum.any?(leaf_summaries(result), &match?({_, _, [:entries, 1]}, &1)),
             "got #{inspect(leaf_summaries(result))}"
    end

    @tag :library_bug
    test "shrunk: a missing amount on leg 1 of 2 is reported with an empty path", %{
      usd: [a, b | _]
    } do
      result =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "1.00")},
          %{account_id: b, side: :credit}
        ])

      assert Enum.any?(leaf_summaries(result), &match?({_, _, [:entries, 1]}, &1)),
             "got #{inspect(leaf_summaries(result))}"
    end
  end

  # ── 2. order independence ─────────────────────────────────────────────────

  describe "order independence" do
    # Two faults on two different legs. Reordering the list must not change WHICH
    # legs are reported or what they are reported for — only the indices those
    # legs now sit at. Faults are compared by the leg they were injected into,
    # recovered through the permutation.
    property "which legs are blamed does not depend on the order they are sent in", %{usd: usd} do
      check all(
              legs <- uniform_journal(usd, :USD),
              kinds <-
                uniq_list_of(member_of([:unknown_key, :owned_key, :unknown_account]), length: 2),
              faults <- uniq_list_of(integer(0..(length(legs) - 1)), length: 2),
              order <- list_of(integer(), length: length(legs)),
              max_runs: 250
            ) do
        [kind_a, kind_b] = kinds
        [index_a, index_b] = faults

        canonical =
          legs
          |> inject(index_a, kind_a)
          |> inject(index_b, kind_b)

        permutation = Enum.sort_by(0..(length(legs) - 1), &Enum.at(order, &1))
        permuted = Enum.map(permutation, &Enum.at(canonical, &1))

        assert blamed(post(canonical), 0..(length(legs) - 1) |> Enum.to_list()) ==
                 blamed(post(permuted), permutation)
      end
    end

    # `{module, field, ORIGINAL leg index}` — the reported index is mapped back
    # through the permutation so the two runs are comparable.
    defp blamed(result, permutation) do
      result
      |> leaf_summaries()
      |> Enum.map(fn
        {module, field, [:entries, i]} -> {module, field, Enum.at(permutation, i)}
        {module, field, path} -> {module, field, path}
      end)
      |> MapSet.new()
    end
  end

  # ── 3. no validation is reachable only after a write ──────────────────────

  describe "nothing is written by a rejected journal" do
    property "every rejection kind leaves the transaction, entry and balance counts alone", %{
      usd: usd
    } do
      check all(
              legs <- uniform_journal(usd, :USD),
              kind <- member_of(@per_leg_kinds ++ @shape_kinds),
              index <- integer(0..(length(legs) - 1)),
              max_runs: 400
            ) do
        before = row_counts()

        assert {:error, _} = post(inject(legs, index, kind))

        assert row_counts() == before, "#{kind} at leg #{index} left rows behind"
      end
    end

    test "and so do the journal-level rejections", %{usd: [a, b | _]} do
      before = row_counts()

      assert {:error, _} = post([])

      assert {:error, _} =
               post([%{account_id: a, side: :debit, amount: Money.new!(:USD, "0.00")}])

      assert {:error, _} =
               post([
                 %{account_id: a, side: :debit, amount: Money.new!(:USD, "10.00")},
                 %{account_id: b, side: :credit, amount: Money.new!(:USD, "9.00")}
               ])

      assert row_counts() == before
    end
  end

  # ── 4. nothing valid is refused ───────────────────────────────────────────

  describe "nothing valid is refused" do
    property "any balanced single-currency journal over existing accounts posts", %{
      usd: usd,
      eur: eur
    } do
      check all(
              {currency, ids} <- member_of([{:USD, usd}, {:EUR, eur}]),
              legs <- balanced_journal(ids, currency),
              max_runs: 250
            ) do
        case post(legs) do
          {:ok, transaction} ->
            entries = transaction |> Ash.load!(:entries) |> Map.get(:entries)

            assert length(entries) == length(legs)

            assert entries |> Enum.map(&{&1.side, Money.to_string!(&1.amount)}) |> Enum.sort() ==
                     legs |> Enum.map(&expected_leg/1) |> Enum.sort()

          {:error, error} ->
            flunk("""
            a valid journal was refused.
            legs: #{inspect(legs, pretty: true)}
            leaves: #{inspect(leaf_summaries(error))}
            """)
        end
      end
    end

    defp expected_leg(leg) do
      side = leg[:side] || leg["side"]
      amount = leg[:amount] || leg["amount"]

      {if(is_binary(side), do: String.to_existing_atom(side), else: side),
       Money.to_string!(amount)}
    end

    test "a 50-leg journal posts", %{usd: usd} do
      [a | _] = usd

      legs =
        [%{account_id: a, side: :debit, amount: Money.new!(:USD, "49.00")}] ++
          for i <- 1..49 do
            %{
              account_id: Enum.at(usd, rem(i, length(usd))),
              side: :credit,
              amount: Money.new!(:USD, "1.00")
            }
          end

      assert {:ok, transaction} = post(legs)
      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 50
    end

    test "the same account on both sides of one journal posts and nets out", %{usd: [a, b | _]} do
      assert {:ok, _} =
               post([
                 %{account_id: a, side: :debit, amount: Money.new!(:USD, "10.00")},
                 %{account_id: a, side: :credit, amount: Money.new!(:USD, "4.00")},
                 %{account_id: b, side: :credit, amount: Money.new!(:USD, "6.00")}
               ])

      reloaded = Account |> Ash.get!(a, authorize?: false) |> Ash.load!(:balance_as_of)

      assert Money.equal?(reloaded.balance_as_of, Money.new!(:USD, "6.00"))
    end

    test "an all-zero journal posts — zero is a magnitude", %{usd: [a, b | _]} do
      assert {:ok, transaction} =
               post([
                 %{account_id: a, side: :debit, amount: Money.new!(:USD, "0.00")},
                 %{account_id: b, side: :credit, amount: Money.new!(:USD, "0.00")}
               ])

      assert transaction |> Ash.load!(:entries) |> Map.get(:entries) |> length() == 2
    end

    test "a very large amount posts", %{usd: [a, b | _]} do
      big = Money.new!(:USD, Decimal.new("123456789012345678901234.99"))

      assert {:ok, _} =
               post([
                 %{account_id: a, side: :debit, amount: big},
                 %{account_id: b, side: :credit, amount: big}
               ])
    end
  end

  # ── 5. edge cases on the boundary of the surface ──────────────────────────

  describe "edge cases" do
    test "a key that is neither an atom nor a string is rejected at its leg", %{usd: [a, b | _]} do
      result =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "1.00")},
          %{1 => :junk, :account_id => b, :side => :credit, :amount => Money.new!(:USD, "1.00")}
        ])

      assert {Ash.Error.Invalid.NoSuchInput, 1, [:entries, 1]} in leaf_summaries(result)
    end

    test "a nil account_id is rejected at its leg rather than crashing", %{usd: [a | _]} do
      result =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "1.00")},
          %{side: :credit, amount: Money.new!(:USD, "1.00")}
        ])

      assert {Ash.Error.Changes.InvalidAttribute, :account_id, [:entries, 1]} in leaf_summaries(
               result
             )
    end

    test "an entries list of one, and of none, is refused with nothing written", %{usd: [a | _]} do
      before = row_counts()

      assert {:error, %Ash.Error.Invalid{}} = post([])

      assert {:error, %Ash.Error.Invalid{}} =
               post([%{account_id: a, side: :debit, amount: Money.new!(:USD, "0.00")}])

      assert row_counts() == before
    end

    test "a nil entries argument is refused", %{usd: _} do
      assert {:error, %Ash.Error.Invalid{}} = post(nil)
    end

    # Both spellings of `side` are accepted individually, so a leg carrying both
    # is ambiguous. Atom wins; the string is dropped without a word. Pinned as
    # characterisation, not asserted as correct — if this is ever tightened into
    # a rejection, this test should be the thing that notices.
    test "when a leg carries a field under both spellings, the atom key wins silently", %{
      usd: [a, b | _]
    } do
      assert {:ok, transaction} =
               post([
                 %{
                   :account_id => a,
                   :side => :debit,
                   "side" => "credit",
                   :amount => Money.new!(:USD, "1.00")
                 },
                 %{account_id: b, side: :credit, amount: Money.new!(:USD, "1.00")}
               ])

      entries = transaction |> Ash.load!(:entries) |> Map.get(:entries)
      assert Enum.find(entries, &(&1.account_id == a)).side == :debit
    end

    # ── Regression pin: a non-UUID account_id once escaped as an exception ────
    #
    # The up-front lock (f74cf06) built `Ash.Query.filter(id in ^ids)` from
    # caller-supplied `account_id` values and called `Ash.read!`, so a value the
    # `:uuid` type could not cast raised `InvalidFilterValue` out of the hook
    # instead of returning — a 500 where the documented `{:error, _}` shape
    # belongs, and with no leg named. Fixed in 7733f4f: each id is cast against
    # the Account's id type first and a failing leg is reported at its index.
    test "shrunk: a non-UUID account_id returns an error rather than raising", %{usd: [a | _]} do
      result =
        post([
          %{account_id: a, side: :debit, amount: Money.new!(:USD, "1.00")},
          %{account_id: "not-a-uuid", side: :credit, amount: Money.new!(:USD, "1.00")}
        ])

      assert {:error, _} = result

      assert {Ash.Error.Changes.InvalidAttribute, :account_id, [:entries, 1]} in leaf_summaries(
               result
             )
    end

    # ── Regression pin: the account-currency check was raw string equality ────
    #
    # `Account.currency` is an unconstrained string with no normalisation, and
    # the released Transfer path reads it through `Money.new!/2`, which accepts
    # "usd" as :USD. `validate_legs_against_accounts/2` once compared it with
    # `to_string(amount.currency) != account.currency`, so an account opened as
    # "usd" could never be posted to at all. Fixed in feb5fd1: the stored code is
    # normalised the way Transfer reads it before the comparison.
    test "shrunk: an account whose currency is spelled differently is still postable" do
      a = account("lower_#{System.unique_integer([:positive])}", "usd")
      b = account("lower_#{System.unique_integer([:positive])}", "usd")

      assert {:ok, _} =
               post([
                 %{account_id: a.id, side: :debit, amount: Money.new!(:USD, "1.00")},
                 %{account_id: b.id, side: :credit, amount: Money.new!(:USD, "1.00")}
               ])
    end
  end
end
