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

    # This read happens while the changeset is being built, not in a hook: the
    # reversing legs have to be on the changeset before VerifyTransaction can
    # validate them. So the caller's actor and tenant must arrive with
    # `for_create/3` — the contract Ash gives every build-time change — whereas
    # `post`, whose reads run in hooks, also honours them given to `Ash.create/2`.
    original =
      changeset.resource
      |> Ash.Query.filter(id == ^original_id)
      |> Ash.Query.load(:entries)
      |> Ash.Query.set_context(%{private: %{internal?: true}})
      |> Ash.read_one!(
        Ash.Context.to_opts(context,
          authorize?: authorize?(changeset.domain),
          domain: changeset.domain
        )
      )

    case original do
      nil ->
        Ash.Changeset.add_error(changeset, message: "original transaction not found")

      %{entries: entries} ->
        # Carry the original legs' application-defined fields onto the reversing
        # legs. A reversal mirrors the journal it reverses, so a leg that credited
        # one order line has to debit that same line — without this, an application
        # can tell which line a charge belonged to but not which line a refund
        # cancelled, which is the whole reason for hanging a dimension off a leg.
        app_fields =
          changeset.resource
          |> AshDoubleEntry.Transaction.Info.transaction_entry_resource!()
          |> AshDoubleEntry.Entry.Info.entry_app_fields()

        flipped_entries =
          Enum.map(entries, fn e ->
            e
            |> Map.take(app_fields)
            |> Map.merge(%{
              account_id: e.account_id,
              side: flip_side(e.side),
              amount: e.amount
            })
          end)

        changeset
        |> Ash.Changeset.set_argument(:entries, flipped_entries)
        |> Ash.Changeset.force_change_attribute(:reverses_transaction_id, original_id)
    end
  end

  defp flip_side(:debit), do: :credit
  defp flip_side(:credit), do: :debit

  # Mirrors `VerifyTransfer`: on a domain configured `authorize :always` the
  # application has asked for authorization to run, and Ash refuses a bare
  # `authorize?: false` there outright (DomainRequiresAuthorization). Everywhere
  # else — `:by_default`, the ordinary case — the extension's own bookkeeping
  # calls bypass, exactly as they always have.
  defp authorize?(domain), do: Ash.Domain.Info.authorize(domain) == :always
end
