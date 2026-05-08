# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Test.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Entry]

  postgres do
    table "entries"
    repo AshDoubleEntry.Test.Repo
  end

  entry do
    account_resource AshDoubleEntry.Test.Account
    transaction_resource AshDoubleEntry.Test.Transaction
  end
end
