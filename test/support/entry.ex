# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Test.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Entry],
    authorizers: [Ash.Policy.Authorizer]

  # Entries are created only by the Transaction cascade, which runs with authorization
  # bypassed outright. These policies pin that: if the bypass were ever removed, every
  # posting test in this suite would start failing rather than the behaviour changing
  # quietly under a feature that hands caller-supplied values to Entry :create.
  policies do
    policy action_type(:create) do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  postgres do
    table "entries"
    repo(AshDoubleEntry.Test.Repo)
  end

  entry do
    account_resource AshDoubleEntry.Test.Account
    transaction_resource AshDoubleEntry.Test.Transaction
    create_accept [:line_item_id]
  end

  attributes do
    # An application-defined dimension hung off an individual leg of a journal.
    attribute :line_item_id, :string, allow_nil?: true, public?: true

    # An app attribute deliberately left OUT of `create_accept`, to pin that the
    # accept list — not merely "is it an attribute?" — is the boundary.
    attribute :internal_note, :string, allow_nil?: true, public?: true
  end
end
