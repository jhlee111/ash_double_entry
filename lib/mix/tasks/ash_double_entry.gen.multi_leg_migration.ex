# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshDoubleEntry.Gen.MultiLegMigration do
  @moduledoc """
  Generates an Ecto migration creating `transactions` + `entries` tables.

  Usage:

      mix ash_double_entry.gen.multi_leg_migration \\
        --transactions-table transactions \\
        --entries-table entries \\
        --accounts-table accounts

  This is a starter migration. If you have an existing `transfers` table
  and want to backfill 1 Transaction + 2 Entries per Transfer, edit the
  generated migration to add the backfill SQL (an example is included as
  a comment block).
  """
  use Mix.Task

  @shortdoc "Generate a multi-leg journal entry migration."

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          transactions_table: :string,
          entries_table: :string,
          accounts_table: :string
        ]
      )

    transactions_table = Keyword.get(opts, :transactions_table, "transactions")
    entries_table = Keyword.get(opts, :entries_table, "entries")
    accounts_table = Keyword.get(opts, :accounts_table, "accounts")

    timestamp =
      DateTime.utc_now()
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()
      |> String.replace(~r/[-:T.]/, "")
      |> String.slice(0, 14)

    file = "priv/repo/migrations/#{timestamp}_add_multi_leg_journal_entries.exs"
    content = generate(transactions_table, entries_table, accounts_table)

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)

    Mix.shell().info("Generated #{file}")
  end

  defp generate(tx_table, e_table, acc_table) do
    """
    defmodule MyApp.Repo.Migrations.AddMultiLegJournalEntries do
      use Ecto.Migration

      def up do
        create_if_not_exists table(:#{tx_table}, primary_key: false) do
          add :id, :string, primary_key: true, null: false
          add :posted_at, :utc_datetime_usec, null: false
          add :inserted_at, :utc_datetime_usec, null: false
          add :reverses_transaction_id,
              references(:#{tx_table}, type: :string, on_delete: :nilify_all)
        end

        create_if_not_exists table(:#{e_table}, primary_key: false) do
          add :id, :string, primary_key: true, null: false
          add :transaction_id,
              references(:#{tx_table}, type: :string, on_delete: :delete_all),
              null: false
          add :account_id, references(:#{acc_table}, on_delete: :restrict), null: false
          add :side, :string, null: false
          add :amount, :decimal, precision: 18, scale: 4, null: false
          add :amount_currency, :string, null: false
          add :inserted_at, :utc_datetime_usec, null: false
        end

        create_if_not_exists index(:#{e_table}, [:transaction_id])
        create_if_not_exists index(:#{e_table}, [:account_id])

        # If you have an existing `transfers` table and want to backfill
        # 1 Transaction + 2 Entries per Transfer, uncomment and adapt:
        #
        # execute(\"\"\"
        # INSERT INTO #{tx_table} (id, posted_at, inserted_at)
        # SELECT t.id, t.timestamp, t.inserted_at
        # FROM transfers t
        # WHERE NOT EXISTS (SELECT 1 FROM #{tx_table} tx WHERE tx.id = t.id)
        # \"\"\")
        #
        # execute(\"\"\"
        # INSERT INTO #{e_table} (id, transaction_id, account_id, side, amount, amount_currency, inserted_at)
        # SELECT t.id || '-d', t.id, t.to_account_id, 'debit',
        #        (t.amount).amount, (t.amount).currency, t.inserted_at
        # FROM transfers t
        # WHERE NOT EXISTS (SELECT 1 FROM #{e_table} e WHERE e.id = t.id || '-d')
        # \"\"\")
        #
        # execute(\"\"\"
        # INSERT INTO #{e_table} (id, transaction_id, account_id, side, amount, amount_currency, inserted_at)
        # SELECT t.id || '-c', t.id, t.from_account_id, 'credit',
        #        (t.amount).amount, (t.amount).currency, t.inserted_at
        # FROM transfers t
        # WHERE NOT EXISTS (SELECT 1 FROM #{e_table} e WHERE e.id = t.id || '-c')
        # \"\"\")
      end

      def down do
        drop_if_exists index(:#{e_table}, [:account_id])
        drop_if_exists index(:#{e_table}, [:transaction_id])
        drop_if_exists table(:#{e_table})
        drop_if_exists table(:#{tx_table})
      end
    end
    """
  end
end
