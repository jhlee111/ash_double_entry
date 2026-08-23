# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Test.Transaction do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Transaction]

  postgres do
    table "transactions"
    repo(AshDoubleEntry.Test.Repo)
  end

  transaction do
    account_resource AshDoubleEntry.Test.Account
    entry_resource AshDoubleEntry.Test.Entry
    balance_resource AshDoubleEntry.Test.Balance
    create_accept [:posted_at]
  end

  relationships do
    # Test scaffolding only — see Test.Transfer.
    has_many :settlements, AshDoubleEntry.Test.Transfer do
      destination_attribute :transaction_id
      public? true
    end
  end
end
