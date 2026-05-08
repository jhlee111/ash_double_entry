# Multi-Leg Journal Entries

When a single business event affects more than two accounts — for example
a sale where cash is collected, revenue is recognized, and sales tax is
set aside as a liability — post a multi-leg `Transaction` directly. A
`Transaction` groups any number of `Entry` rows and enforces the
double-entry invariant: `Σ debits == Σ credits` per currency.

## Defining the resources

Add `AshDoubleEntry.Transaction` and `AshDoubleEntry.Entry` extensions
to two new resources, parallel to your existing `Account` / `Balance`:

```elixir
defmodule MyApp.Ledger.Transaction do
  use Ash.Resource,
    domain: MyApp.Ledger,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Transaction]

  postgres do
    table "transactions"
    repo MyApp.Repo
  end

  transaction do
    account_resource MyApp.Ledger.Account
    entry_resource MyApp.Ledger.Entry
    balance_resource MyApp.Ledger.Balance
  end
end

defmodule MyApp.Ledger.Entry do
  use Ash.Resource,
    domain: MyApp.Ledger,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshDoubleEntry.Entry]

  postgres do
    table "entries"
    repo MyApp.Repo
  end

  entry do
    account_resource MyApp.Ledger.Account
    transaction_resource MyApp.Ledger.Transaction
  end
end
```

Add `entry_resource MyApp.Ledger.Entry` to your existing `Balance`
resource's `balance do … end` block to enable entry-keyed Balance rows.

Generate the migration:

```bash
mix ash_double_entry.gen.multi_leg_migration
mix ecto.migrate
```

## Posting a Transaction

```elixir
{:ok, transaction} =
  MyApp.Ledger.Transaction
  |> Ash.Changeset.for_create(:post, %{
    entries: [
      %{account_id: cash.id,    side: :debit,  amount: Money.new!(:USD, 108_00)},
      %{account_id: revenue.id, side: :credit, amount: Money.new!(:USD, 100_00)},
      %{account_id: tax.id,     side: :credit, amount: Money.new!(:USD, 8_00)}
    ]
  })
  |> Ash.create()

transaction = Ash.load!(transaction, :entries)
assert length(transaction.entries) == 3
```

The change validates `Σ debits == Σ credits` per currency; an unbalanced
posting returns `{:error, _}`.

## Reversing a Transaction

```elixir
{:ok, reversal} =
  MyApp.Ledger.Transaction
  |> Ash.Changeset.for_create(:reverse, %{original_transaction_id: original.id})
  |> Ash.create()

assert reversal.reverses_transaction_id == original.id
```

## When to use Transaction vs Transfer

Use `Transfer.create` for simple two-account transfers; use
`Transaction.post` directly when the journal entry has more than two
sides (typical for retail sales with sales tax, payroll with multiple
deductions, COGS posting, etc.).

## Sign convention

The library is bookkeeping-agnostic: an Account's balance is increased
by `:debit` Entries and decreased by `:credit` Entries. To map this to
accounting "natural" balances (where a revenue account's positive
balance equals its credit total), apply a sign-flip on the application
side based on your account-type taxonomy.
