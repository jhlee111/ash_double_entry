# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Test.StrictDomain do
  @moduledoc """
  A parallel set of resources under `authorize :always`, for #3.

  It has to be a parallel SET, not just a second domain: Ash resolves the
  domain from the resource itself before the `:domain` option
  (`Ash.Actions.Helpers`: `Ash.Resource.Info.domain(resource) || opts[:domain]`),
  so passing `domain:` at an already-declared resource is silently ignored and
  any test written that way is vacuous.

  The strict resources share the ordinary tables — nothing here is about
  storage, only about how the domain is configured.
  """
  use Ash.Domain

  authorization do
    authorize :always
  end

  resources do
    resource AshDoubleEntry.Test.StrictAccount
    resource AshDoubleEntry.Test.StrictBalance
    resource AshDoubleEntry.Test.StrictTransaction
    resource AshDoubleEntry.Test.StrictEntry
  end
end

defmodule AshDoubleEntry.Test.StrictAccount do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.StrictDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Account]

  postgres do
    table "accounts"
    repo(AshDoubleEntry.Test.Repo)
  end

  account do
    pre_check_identities_with AshDoubleEntry.Test.StrictDomain
    transfer_resource AshDoubleEntry.Test.Transfer
    balance_resource AshDoubleEntry.Test.StrictBalance
    open_action_accept [:allow_zero_balance]
  end

  attributes do
    attribute :allow_zero_balance, :boolean do
      default true
    end
  end
end

defmodule AshDoubleEntry.Test.StrictBalance do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.StrictDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Balance]

  postgres do
    table "balances"
    repo(AshDoubleEntry.Test.Repo)
  end

  balance do
    transfer_resource AshDoubleEntry.Test.Transfer
    account_resource AshDoubleEntry.Test.StrictAccount
    entry_resource AshDoubleEntry.Test.StrictEntry
  end

  actions do
    defaults [:destroy]
  end
end

defmodule AshDoubleEntry.Test.StrictTransaction do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.StrictDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Transaction]

  postgres do
    table "transactions"
    repo(AshDoubleEntry.Test.Repo)
  end

  transaction do
    account_resource AshDoubleEntry.Test.StrictAccount
    entry_resource AshDoubleEntry.Test.StrictEntry
    balance_resource AshDoubleEntry.Test.StrictBalance
    create_accept [:posted_at]
  end
end

defmodule AshDoubleEntry.Test.StrictEntry do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.StrictDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Entry]

  postgres do
    table "entries"
    repo(AshDoubleEntry.Test.Repo)
  end

  entry do
    account_resource AshDoubleEntry.Test.StrictAccount
    transaction_resource AshDoubleEntry.Test.StrictTransaction
  end
end
