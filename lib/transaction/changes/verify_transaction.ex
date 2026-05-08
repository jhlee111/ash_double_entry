# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Transaction.Changes.VerifyTransaction do
  @moduledoc false
  # Validates Σ debits == Σ credits per currency, then cascades Entry creation.
  use Ash.Resource.Change
  require Ash.Query

  def change(changeset, _opts, context) do
    entries = Ash.Changeset.get_argument(changeset, :entries) || []

    case validate_entries(entries) do
      :ok ->
        Ash.Changeset.after_action(changeset, fn _changeset, transaction ->
          cascade_entries(transaction, entries, changeset.resource, changeset.domain, context)
        end)

      {:error, msg} ->
        Ash.Changeset.add_error(changeset, message: msg)
    end
  end

  defp validate_entries([]), do: {:error, "Transaction must have at least 2 entries"}
  defp validate_entries([_]), do: {:error, "Transaction must have at least 2 entries"}

  defp validate_entries(entries) do
    with :ok <- validate_currency(entries) do
      validate_balance(entries)
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

  defp entry_currency(%{amount: %Money{} = m}), do: m.currency
  defp entry_currency(%{"amount" => %Money{} = m}), do: m.currency

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

  defp entry_side(%{side: side}), do: side
  defp entry_side(%{"side" => side}) when is_binary(side), do: String.to_atom(side)
  defp entry_side(%{"side" => side}) when is_atom(side), do: side

  defp entry_amount(%{amount: amount}), do: amount
  defp entry_amount(%{"amount" => amount}), do: amount

  defp cascade_entries(transaction, entries, transaction_resource, domain, context) do
    entry_resource =
      AshDoubleEntry.Transaction.Info.transaction_entry_resource!(transaction_resource)

    entry_inputs =
      Enum.map(entries, fn e ->
        %{
          transaction_id: transaction.id,
          account_id: Map.get(e, :account_id) || Map.get(e, "account_id"),
          side: entry_side(e),
          amount: entry_amount(e)
        }
      end)

    Ash.bulk_create(
      entry_inputs,
      entry_resource,
      :create,
      Ash.Context.to_opts(context,
        domain: domain,
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true
      )
    )
    |> case do
      %Ash.BulkResult{status: :success} -> {:ok, transaction}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end
end
