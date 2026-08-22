# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry.Info do
  @moduledoc "Introspection helpers for the `entry` DSL."

  use Spark.InfoGenerator,
    extension: AshDoubleEntry.Entry,
    sections: [:entry]

  # Fields on an Entry that the Transaction owns outright. `transaction_id` is set
  # by the relationship itself — letting a caller supply it would let one journal's
  # leg point at another — and `timestamp` is derived from the Transaction's
  # `posted_at`, because `VerifyEntry` turns it into the Entry ULID that every
  # balance calculation orders by.
  @owned_fields [:transaction_id, :timestamp]

  # Fields the Transaction derives from the caller's entry map rather than copying
  # verbatim, because they may arrive under a string key or as a raw string.
  @derived_fields [:account_id, :side, :amount]

  @doc false
  def owned_fields, do: @owned_fields

  @doc """
  The application-defined inputs of an Entry's `:create` action.

  Everything the action accepts, minus the fields the Transaction owns or derives.
  These are the keys `Transaction.post` carries through verbatim from each entry
  map, and the keys `Transaction.reverse` copies off the original's legs.

  Driven off the action rather than off `create_accept` alone, so that an
  application which replaces the generated `:create` action outright (the
  transformer uses `add_new_action`) is honoured too.
  """
  def entry_app_fields(entry_resource) do
    entry_resource
    |> Ash.Resource.Info.action_inputs(:create)
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&(&1 in @owned_fields or &1 in @derived_fields))
  end

  @doc """
  The full input name set of an Entry's `:create` action, atoms and strings both.

  Used to reject a misspelled key on an entry map. Ash cannot do this for us on the
  managed-relationship path: it narrows each leg with `Map.take/2` against this same
  set and then passes `skip_unknown_inputs`, so an unrecognised key is discarded
  before a child changeset exists and there is no error to raise.
  """
  def entry_create_inputs(entry_resource) do
    Ash.Resource.Info.action_inputs(entry_resource, :create)
  end
end
