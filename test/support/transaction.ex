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
    repo AshDoubleEntry.Test.Repo
  end

  transaction do
    account_resource AshDoubleEntry.Test.Account
    # entry_resource: re-enable in Task 10 once AshDoubleEntry.Test.Entry exists.
    # The Spark schema marks this :required, so we point at a known placeholder
    # for now; the empty transformer doesn't validate the target's identity.
    entry_resource AshDoubleEntry.Test.Transfer
    balance_resource AshDoubleEntry.Test.Balance
  end
end
