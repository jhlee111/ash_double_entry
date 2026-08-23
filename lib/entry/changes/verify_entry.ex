# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry.Changes.VerifyEntry do
  @moduledoc false
  # Locks the affected account and updates the Balance row when an Entry is created.
  use Ash.Resource.Change
  require Ash.Query

  def change(changeset, _opts, context) do
    if skip_balance_updates?(changeset) do
      changeset
    else
      changeset =
        if changeset.action.type == :create do
          timestamp = Ash.Changeset.get_attribute(changeset, :timestamp)

          timestamp =
            case timestamp do
              nil -> System.system_time(:millisecond)
              timestamp -> DateTime.to_unix(timestamp, :millisecond)
            end

          ulid = AshDoubleEntry.ULID.generate(timestamp)

          Ash.Changeset.force_change_attribute(changeset, :id, ulid)
        else
          changeset
        end

      Ash.Changeset.after_action(changeset, fn _changeset, result ->
        delta =
          case result.side do
            :debit -> result.amount
            :credit -> Money.mult!(result.amount, -1)
          end

        account_resource =
          AshDoubleEntry.Entry.Info.entry_account_resource!(changeset.resource)

        balance_resource =
          AshDoubleEntry.Account.Info.account_balance_resource!(account_resource)

        [account] =
          account_resource
          |> Ash.Query.filter(id == ^result.account_id)
          |> Ash.Query.set_context(%{ash_double_entry?: true, private: %{internal?: true}})
          |> Ash.Query.for_read(
            :lock_accounts,
            %{},
            Ash.Context.to_opts(context,
              authorize?: authorize?(changeset.domain),
              domain: changeset.domain
            )
          )
          |> Ash.Query.load(balance_as_of_ulid: %{ulid: result.id})
          |> Ash.read!()

        old_balance =
          account.balance_as_of_ulid || Money.new!(0, result.amount.currency)

        new_balance = Money.add!(old_balance, delta)

        Ash.bulk_create(
          [
            %{
              account_id: account.id,
              entry_id: result.id,
              balance: new_balance
            }
          ],
          balance_resource,
          :upsert_balance,
          context
          |> Ash.Context.to_opts(
            domain: changeset.domain,
            authorize?: authorize?(changeset.domain),
            upsert_fields: [:balance],
            return_errors?: true,
            stop_on_error?: true
          )
          |> mark_internal()
        )
        |> case do
          %Ash.BulkResult{status: :success} ->
            # Ripple a (possibly backdated) entry's effect through the LATER
            # balance rows of this account. For now-dated entries the filter
            # matches zero rows — a no-op.
            balance_resource
            |> Ash.bulk_update(
              :shift_balances_after,
              %{
                account_id: account.id,
                delta: delta,
                after_ulid: result.id
              },
              context
              |> Ash.Context.to_opts(
                domain: changeset.domain,
                authorize?: authorize?(changeset.domain),
                strategy: [:atomic, :stream, :atomic_batches],
                return_errors?: true,
                stop_on_error?: true
              )
              |> mark_internal()
            )
            |> case do
              %Ash.BulkResult{status: :success} -> {:ok, result}
              %Ash.BulkResult{errors: errors} -> {:error, errors}
            end

          %Ash.BulkResult{errors: errors} ->
            {:error, errors}
        end
      end)
    end
  end

  # `Ash.Context.to_opts/2` derives `context:` from the caller's `:shared` slice —
  # the channel Ash hands every nested action — and a `context:` override given
  # to it REPLACES that slice wholesale. Merge the extension's marker into what
  # was derived instead, so a `shared` key set on the posting changeset still
  # reaches the Balance writes, as it does on the Transfer path.
  defp mark_internal(opts) do
    Keyword.update(
      opts,
      :context,
      %{private: %{internal?: true}},
      &Map.update(&1, :private, %{internal?: true}, fn private ->
        Map.put(private, :internal?, true)
      end)
    )
  end

  # Set directly on an Entry changeset, or shared by the Transaction cascade —
  # scoped to this resource so the flag does not leak into other nested actions.
  defp skip_balance_updates?(changeset) do
    flags = changeset.context[:ash_double_entry] || %{}
    flags[:skip_balance_updates] || flags[:skip_balance_updates_for] == changeset.resource
  end

  # Mirrors `VerifyTransfer`: on a domain configured `authorize :always` the
  # application has asked for authorization to run, and Ash refuses a bare
  # `authorize?: false` there outright (DomainRequiresAuthorization). Everywhere
  # else — `:by_default`, the ordinary case — the extension's own bookkeeping
  # calls bypass, exactly as they always have.
  defp authorize?(domain), do: Ash.Domain.Info.authorize(domain) == :always
end
