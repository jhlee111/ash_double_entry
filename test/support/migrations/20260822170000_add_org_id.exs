defmodule AshDoubleEntry.Test.Repo.Migrations.AddOrgId do
  @moduledoc """
  Hand-written, not generated: `AshDoubleEntry.Test.Tenant*` share the ordinary
  tables under attribute multitenancy, and `mix ash.codegen` refuses to merge a
  multitenant and a non-multitenant resource on one table ("Conflicting
  configurations for references"). The columns are nullable because the plain
  `AshDoubleEntry.Test.*` resources never set them.
  """
  use Ecto.Migration

  @tables [:accounts, :balances, :entries, :transactions]

  def up do
    for table <- @tables do
      alter table(table) do
        add(:org_id, :uuid)
      end
    end

    # Under attribute multitenancy Ash appends the tenant attribute to every
    # identity, so `:upsert_balance`'s ON CONFLICT target gains `org_id` and needs
    # a unique index of exactly those columns.
    create unique_index(:balances, [:account_id, :transfer_id, :org_id],
             name: "balances_unique_tenant_references_index"
           )

    create unique_index(:balances, [:account_id, :entry_id, :org_id],
             name: "balances_unique_tenant_account_entry_index"
           )
  end

  def down do
    drop(
      unique_index(:balances, [:account_id, :entry_id, :org_id],
        name: "balances_unique_tenant_account_entry_index"
      )
    )

    drop(
      unique_index(:balances, [:account_id, :transfer_id, :org_id],
        name: "balances_unique_tenant_references_index"
      )
    )

    for table <- @tables do
      alter table(table) do
        remove(:org_id)
      end
    end
  end
end
