# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Transaction.Changes.ReverseTransaction do
  @moduledoc false
  # On :reverse action — loads original Transaction's entries, flips sides,
  # then delegates to VerifyTransaction by setting the :entries argument.
  use Ash.Resource.Change
  require Ash.Query

  def change(changeset, _opts, context) do
    original_id = Ash.Changeset.get_argument(changeset, :original_transaction_id)

    original =
      changeset.resource
      |> Ash.Query.filter(id == ^original_id)
      |> Ash.Query.load(:entries)
      |> Ash.read_one!(
        Ash.Context.to_opts(context, authorize?: false, domain: changeset.domain)
      )

    case original do
      nil ->
        Ash.Changeset.add_error(changeset, message: "original transaction not found")

      %{entries: entries} ->
        flipped_entries =
          Enum.map(entries, fn e ->
            %{
              account_id: e.account_id,
              side: flip_side(e.side),
              amount: e.amount
            }
          end)

        changeset
        |> Ash.Changeset.set_argument(:entries, flipped_entries)
        |> Ash.Changeset.force_change_attribute(:reverses_transaction_id, original_id)
    end
  end

  defp flip_side(:debit), do: :credit
  defp flip_side(:credit), do: :debit
end
