# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Transaction.Changes.VerifyTransaction do
  @moduledoc false
  # Validates Σ debits == Σ credits per currency, then cascades Entry creation.
  use Ash.Resource.Change
  require Ash.Query

  def change(changeset, _opts, _context) do
    entries = Ash.Changeset.get_argument(changeset, :entries) || []

    entry_resource =
      AshDoubleEntry.Transaction.Info.transaction_entry_resource!(changeset.resource)

    with :ok <- validate_entries(entries),
         %{valid?: true} = changeset <- validate_entry_inputs(changeset, entries, entry_resource) do
      cascade_entries(changeset, entries, entry_resource)
    else
      {:error, msg} -> Ash.Changeset.add_error(changeset, message: msg)
      %Ash.Changeset{} = changeset -> changeset
    end
  end

  defp validate_entries([]), do: {:error, "Transaction must have at least 2 entries"}
  defp validate_entries([_]), do: {:error, "Transaction must have at least 2 entries"}

  defp validate_entries(entries) do
    with :ok <- validate_shape(entries),
         :ok <- validate_currency(entries) do
      validate_balance(entries)
    end
  end

  # `side` and `amount` are read by the balance check below. Without this a leg
  # missing either one crashed with a FunctionClauseError, and — worse — a leg whose
  # side was neither debit nor credit fell out of both sums, so `validate_balance/1`
  # saw 0 == 0 and passed a journal that does not balance.
  defp validate_shape(entries) do
    cond do
      not Enum.all?(entries, &(entry_side(&1) in [:debit, :credit])) ->
        {:error, "Every entry must have a side of :debit or :credit"}

      not Enum.all?(entries, &match?(%Money{}, entry_amount(&1))) ->
        {:error, "Every entry must have a Money amount"}

      true ->
        :ok
    end
  end

  defp validate_currency(entries) do
    currencies =
      entries
      |> Enum.map(&entry_currency/1)
      |> Enum.uniq()

    case currencies do
      [_one] -> :ok
      _ -> {:error, "All entries in a Transaction must share currency"}
    end
  end

  defp validate_balance(entries) do
    currency = entries |> List.first() |> entry_currency()
    zero = Money.new!(0, currency)

    debit_total =
      entries
      |> Enum.filter(&(entry_side(&1) == :debit))
      |> Enum.reduce(zero, fn e, acc -> Money.add!(acc, entry_amount(e)) end)

    credit_total =
      entries
      |> Enum.filter(&(entry_side(&1) == :credit))
      |> Enum.reduce(zero, fn e, acc -> Money.add!(acc, entry_amount(e)) end)

    if Money.equal?(debit_total, credit_total) do
      :ok
    else
      {:error,
       "Transaction unbalanced: debits=#{inspect(debit_total)}, credits=#{inspect(credit_total)}"}
    end
  end

  # Ash cannot reject a misspelled key on an entry map for us. The managed
  # relationship narrows each leg with `Map.take/2` against the Entry `:create`
  # action's inputs and then passes `skip_unknown_inputs`, so an unrecognised key is
  # discarded before a child changeset exists and there is no error to raise. A typo
  # in an app-defined field would post successfully with that field left NULL.
  defp validate_entry_inputs(changeset, entries, entry_resource) do
    inputs = AshDoubleEntry.Entry.Info.entry_create_inputs(entry_resource)

    owned =
      AshDoubleEntry.Entry.Info.owned_fields()
      |> Enum.flat_map(&[&1, Atom.to_string(&1)])

    entries
    |> Enum.with_index()
    |> Enum.reduce(changeset, fn {entry, index}, changeset ->
      Enum.reduce(caller_keys(entry), changeset, fn key, changeset ->
        cond do
          key in owned ->
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidAttribute.exception(
                field: key,
                message: "is derived from the transaction and cannot be set on an entry"
              ),
              [:entries, index]
            )

          MapSet.member?(inputs, key) ->
            changeset

          true ->
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Invalid.NoSuchInput.exception(
                resource: entry_resource,
                action: :create,
                input: key,
                inputs: inputs
              ),
              [:entries, index]
            )
        end
      end)
    end)
  end

  # A leg given as an Entry struct carries the resource's own field names, not
  # caller-authored keys — there is nothing to misspell, so there is nothing to check.
  defp caller_keys(%_{}), do: []
  defp caller_keys(entry) when is_map(entry), do: Map.keys(entry)

  # `skip_balance_updates` is read off each Entry's own changeset by VerifyEntry,
  # but Ash hands a managed child only the `:shared` slice of its parent's
  # context — so a flag set the ordinary way never reached the cascaded entries
  # and their balance rows were written anyway, silently. Re-setting it under
  # `:shared` is what carries it down. `set_context/2` also merges `:shared`
  # back over the top level, so the parent's own reads are unchanged, and the
  # child sees it at the top level too — VerifyEntry needs no second lookup.
  #
  # It is shared SCOPED TO THE ENTRY RESOURCE, not as the bare flag: `:shared`
  # reaches every nested action on this changeset, including a consumer-managed
  # child the extension knows nothing about — a Transfer managed off the
  # Transaction, say — which maintains its own balances and must keep doing so.
  defp share_skip_balance_updates(changeset, entry_resource) do
    if get_in(changeset.context, [:ash_double_entry, :skip_balance_updates]) do
      Ash.Changeset.set_context(changeset, %{
        shared: %{ash_double_entry: %{skip_balance_updates_for: entry_resource}}
      })
    else
      changeset
    end
  end

  defp cascade_entries(changeset, entries, entry_resource) do
    app_fields = AshDoubleEntry.Entry.Info.entry_app_fields(entry_resource)

    account_resource =
      AshDoubleEntry.Transaction.Info.transaction_account_resource!(changeset.resource)

    id_attribute = Ash.Resource.Info.attribute(account_resource, :id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      # `share_skip_balance_updates/1` runs HERE, not in `change/3`: a caller
      # sets the flag after `for_create` returns, so at change time it is not on
      # the changeset yet. A before_action hook sees the context the caller
      # actually assembled.
      changeset = share_skip_balance_updates(changeset, entry_resource)

      # A leg's account_id is caller data. Cast it against the Account's id type
      # HERE, before it reaches a filter: a value that does not cast used to blow
      # up inside the lock query as `InvalidFilterValue`, raised out of this hook
      # with no leg index — where the Entry changeset would have returned
      # `InvalidAttribute` at the leg. The cast value is also what the lock
      # result is keyed by, so an id the database matches case-insensitively is
      # found again in the map.
      legs = Enum.map(entries, &{&1, cast_account_id(&1, id_attribute)})

      # Lock every account this journal touches FIRST, in one batched FOR UPDATE,
      # before any row of this journal is inserted. That placement is what keeps
      # two concurrent journals over the same accounts from deadlocking: each
      # takes every row it needs in one statement, so one simply waits for the
      # other to commit. The sort only makes the lock order deterministic across
      # query plans — measured, the deadlock rate is 0/240 with or without it.
      # VerifyEntry's later per-leg lock is then a re-lock of a row this
      # transaction already holds, never a wait. (VerifyTransfer does NOT do
      # this: it locks inside an after_action, after the transfer row is in, and
      # two opposite-direction transfers can still deadlock each other.)
      accounts = lock_accounts(legs, account_resource, changeset)

      case validate_legs_against_accounts(legs, accounts) do
        [] ->
          # Read `posted_at` here rather than at change time. Function defaults are
          # applied by `Ash.Changeset.set_defaults(:create, true)` on the way into the
          # action, which runs after changes but before before_action hooks — at change
          # time `posted_at` is still nil unless the caller supplied one.
          posted_at = Ash.Changeset.get_attribute(changeset, :posted_at)
          inputs = Enum.map(entries, &entry_input(&1, posted_at, app_fields))
          cascade(changeset, inputs, posted_at)

        errors ->
          Enum.reduce(errors, changeset, fn {error, path}, changeset ->
            Ash.Changeset.add_error(changeset, error, path)
          end)
      end
    end)
  end

  defp cast_account_id(entry, id_attribute) do
    case Ash.Type.cast_input(id_attribute.type, entry_account_id(entry), id_attribute.constraints) do
      {:ok, id} -> {:ok, id}
      _ -> :error
    end
  end

  # Every read the extension makes on its own behalf runs as the caller — with
  # the tenant, actor and tracer of the action that triggered it — and so must
  # this one: without the tenant, a multitenant Account resource refuses the read
  # outright and `post` is unavailable to that application. The change's own
  # `context` is a snapshot taken at `for_create`, so a tenant or actor handed to
  # `Ash.create/2` instead never appears in it; the changeset this hook is given
  # carries the effective values, in the same places Ash reads them from.
  defp lock_accounts(legs, account_resource, changeset) do
    ids = for {_entry, {:ok, id}} <- legs, not is_nil(id), uniq: true, do: id

    account_resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.set_context(%{ash_double_entry?: true, private: %{internal?: true}})
    |> Ash.Query.for_read(
      :lock_accounts,
      %{},
      Ash.Scope.to_opts(caller_scope(changeset),
        authorize?: authorize?(changeset.domain),
        domain: changeset.domain
      )
    )
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  end

  defp caller_scope(changeset) do
    private = changeset.context[:private] || %{}

    %{
      actor: private[:actor],
      tenant: changeset.tenant,
      tracer: private[:tracer],
      shared: changeset.context[:shared] || %{}
    }
  end

  # With the accounts in hand, two things the journal-level checks cannot see:
  # a leg pointing at an account that does not exist, and a leg whose Money is
  # in a currency its account does not hold. Both used to surface late — the
  # first as a database constraint, the second as Ash.Error.Unknown wrapping
  # Money.add!'s ArgumentError from inside VerifyEntry — and neither named the
  # leg. Now both are validation errors at `[:entries, index]`.
  defp validate_legs_against_accounts(legs, accounts) do
    legs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{entry, cast}, index} ->
      account =
        case cast do
          {:ok, id} -> Map.get(accounts, id)
          :error -> nil
        end

      amount = entry_amount(entry)

      cond do
        cast == :error ->
          [
            {Ash.Error.Changes.InvalidAttribute.exception(
               field: :account_id,
               value: entry_account_id(entry),
               message: "is invalid"
             ), [:entries, index]}
          ]

        is_nil(account) ->
          [
            {Ash.Error.Changes.InvalidAttribute.exception(
               field: :account_id,
               value: entry_account_id(entry),
               message: "does not exist"
             ), [:entries, index]}
          ]

        match?(%Money{}, amount) and amount.currency != account_currency(account) ->
          [
            {Ash.Error.Changes.InvalidAttribute.exception(
               field: :amount,
               value: amount,
               message:
                 "is in #{amount.currency}, but account #{account.identifier} holds #{account.currency}"
             ), [:entries, index]}
          ]

        true ->
          []
      end
    end)
  end

  # `Account.currency` is an unconstrained string, and the released Transfer path
  # only ever reads it through `Money.new!/2`, which normalises case — `"usd"`,
  # `:usd` and `"USD"` all become `:USD`. Compare the way that path reads it, not
  # byte-for-byte: a code the library accepted on `open` has to stay postable. A
  # code Money does not know at all matches no leg, and the mismatch error names
  # it as stored.
  defp account_currency(account) do
    case Money.new(0, account.currency) do
      %Money{currency: currency} -> currency
      {:error, _} -> nil
    end
  end

  defp cascade(changeset, inputs, posted_at) do
    changeset
    |> Ash.Changeset.manage_relationship(:entries, inputs,
      type: :create,
      # Name the action rather than leaning on `type: :create`'s default of the
      # PRIMARY create action — the Entry transformer adds `:create` with
      # `add_new_action/4`, which does not mark it primary.
      on_no_match: {:create, :create},
      on_lookup: :ignore,
      on_match: :ignore,
      on_missing: :ignore,
      authorize?: authorize?(changeset.domain),
      # Ash builds the path as `opts[:error_path] || [opts[:meta][:id] || relationship.name,
      # index]`. `meta[:id]` and the relationship name are both `:entries` today, so this
      # is a no-op — it is here to hold the path steady if the relationship is renamed.
      # `error_path:` is emphatically NOT the option to reach for: it REPLACES the whole
      # path, collapsing every failing leg to `[:entries]` and destroying the index.
      meta: [id: :entries]
    )
    |> Ash.Changeset.after_action(&verify_posted_at(&1, &2, posted_at))
  end

  # Build a fresh plain map. Never merge onto the caller's value: a leg given as an
  # Entry struct would stay a struct, and Ash's managed-relationship create
  # short-circuits on `is_struct(input, destination)` — returning `:ok` having
  # written no Entry row and no Balance row at all, for a Transaction that has
  # already asserted it balances.
  defp entry_input(entry, posted_at, app_fields) do
    app_fields
    |> Enum.reduce(%{}, fn field, input ->
      case fetch_field(entry, field) do
        {:ok, %Ash.NotLoaded{}} -> input
        {:ok, value} -> Map.put(input, field, value)
        :error -> input
      end
    end)
    |> Map.merge(%{
      account_id: entry_account_id(entry),
      side: entry_side(entry),
      amount: entry_amount(entry),
      timestamp: posted_at
    })
  end

  defp fetch_field(entry, field) do
    case Map.fetch(entry, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(entry, Atom.to_string(field))
    end
  end

  # `posted_at` stamps every cascaded Entry's `:timestamp`, and `VerifyEntry` turns
  # that into the Entry ULID that `balance_as_of_ulid` and `shift_balances_after`
  # order by. If anything moved `posted_at` after the cascade was built, the row and
  # its own legs disagree about when the journal happened, and `balance_as_of`
  # silently returns the wrong number for every date in between. Roll back instead.
  defp verify_posted_at(_changeset, %{posted_at: posted_at} = transaction, posted_at) do
    {:ok, transaction}
  end

  defp verify_posted_at(_changeset, transaction, posted_at) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :posted_at,
       message:
         "moved after entries were cascaded — entries are stamped #{inspect(posted_at)} but " <>
           "the transaction persisted #{inspect(transaction.posted_at)}. posted_at must not " <>
           "be changed after AshDoubleEntry's transaction change has run."
     )}
  end

  # Total functions over both atom- and string-keyed entry maps, and over Entry
  # structs. No `String.to_atom/1` on caller-supplied data.
  defp entry_side(%{side: side}), do: normalize_side(side)
  defp entry_side(%{"side" => side}), do: normalize_side(side)
  defp entry_side(_), do: nil

  defp normalize_side(:debit), do: :debit
  defp normalize_side(:credit), do: :credit
  defp normalize_side("debit"), do: :debit
  defp normalize_side("credit"), do: :credit
  defp normalize_side(_), do: nil

  defp entry_amount(%{amount: amount}), do: amount
  defp entry_amount(%{"amount" => amount}), do: amount
  defp entry_amount(_), do: nil

  defp entry_currency(entry) do
    case entry_amount(entry) do
      %Money{currency: currency} -> currency
      _ -> nil
    end
  end

  defp entry_account_id(%{account_id: account_id}), do: account_id
  defp entry_account_id(%{"account_id" => account_id}), do: account_id
  defp entry_account_id(_), do: nil

  # Mirrors `VerifyTransfer`: on a domain configured `authorize :always` the
  # application has asked for authorization to run, and Ash refuses a bare
  # `authorize?: false` there outright (DomainRequiresAuthorization). Everywhere
  # else — `:by_default`, the ordinary case — the extension's own bookkeeping
  # calls bypass, exactly as they always have.
  defp authorize?(domain), do: Ash.Domain.Info.authorize(domain) == :always
end
