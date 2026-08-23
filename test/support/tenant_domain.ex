# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# A parallel resource set under attribute multitenancy, sharing the ordinary
# tables. `org_id` is nullable on purpose: the plain `AshDoubleEntry.Test.*`
# resources write the same tables and never set it.
defmodule AshDoubleEntry.Test.TenantDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshDoubleEntry.Test.TenantAccount
    resource AshDoubleEntry.Test.TenantBalance
    resource AshDoubleEntry.Test.TenantTransaction
    resource AshDoubleEntry.Test.TenantEntry
  end
end

defmodule AshDoubleEntry.Test.TenantAccount do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.TenantDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Account]

  postgres do
    table "accounts"
    repo(AshDoubleEntry.Test.Repo)
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  account do
    pre_check_identities_with AshDoubleEntry.Test.TenantDomain
    transfer_resource AshDoubleEntry.Test.Transfer
    balance_resource AshDoubleEntry.Test.TenantBalance
    open_action_accept [:allow_zero_balance]
  end

  attributes do
    attribute :org_id, :uuid, public?: true

    attribute :allow_zero_balance, :boolean do
      default true
    end
  end
end

defmodule AshDoubleEntry.Test.TenantBalance do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.TenantDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Balance]

  postgres do
    table "balances"
    repo(AshDoubleEntry.Test.Repo)
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  balance do
    transfer_resource AshDoubleEntry.Test.Transfer
    account_resource AshDoubleEntry.Test.TenantAccount
    entry_resource AshDoubleEntry.Test.TenantEntry
  end

  attributes do
    attribute :org_id, :uuid, public?: true
  end

  actions do
    defaults [:destroy]
  end
end

defmodule AshDoubleEntry.Test.TenantTransaction do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.TenantDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Transaction]

  postgres do
    table "transactions"
    repo(AshDoubleEntry.Test.Repo)
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  transaction do
    account_resource AshDoubleEntry.Test.TenantAccount
    entry_resource AshDoubleEntry.Test.TenantEntry
    balance_resource AshDoubleEntry.Test.TenantBalance
    create_accept [:posted_at]
  end

  attributes do
    attribute :org_id, :uuid, public?: true
  end
end

defmodule AshDoubleEntry.Test.TenantEntry do
  @moduledoc false
  use Ash.Resource,
    domain: AshDoubleEntry.Test.TenantDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Entry]

  postgres do
    table "entries"
    repo(AshDoubleEntry.Test.Repo)
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  entry do
    account_resource AshDoubleEntry.Test.TenantAccount
    transaction_resource AshDoubleEntry.Test.TenantTransaction
  end

  attributes do
    attribute :org_id, :uuid, public?: true
  end
end
