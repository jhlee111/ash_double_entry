# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry.Changes.VerifyEntry do
  @moduledoc false
  # Locks the affected account and updates the Balance row when an Entry is created.
  use Ash.Resource.Change
  require Ash.Query

  def change(changeset, _opts, context) do
    if changeset.context[:ash_double_entry][:skip_balance_updates] do
      changeset
    else
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
          |> Ash.Query.set_context(%{ash_double_entry?: true})
          |> Ash.Query.for_read(
            :lock_accounts,
            %{},
            Ash.Context.to_opts(context, authorize?: false, domain: changeset.domain)
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
          Ash.Context.to_opts(context,
            domain: changeset.domain,
            authorize?: false,
            upsert_fields: [:balance],
            return_errors?: true,
            stop_on_error?: true
          )
        )
        |> case do
          %Ash.BulkResult{status: :success} -> {:ok, result}
          %Ash.BulkResult{errors: errors} -> {:error, errors}
        end
      end)
    end
  end
end
