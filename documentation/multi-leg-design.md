# Design: Multi-Leg Journal Entries for AshDoubleEntry

**Date**: 2026-05-08
**Author**: brainstormed with Claude
**Status**: Approved (in conversation; spec doc pending user review)
**Related**:
- ADR-0128 (POS Ledger Shape — depends on this design)
- ADR-0005 (Double-entry ledger over transaction log)
- Martin Fowler — Accounting Transaction pattern
- Repo: GsNet uses ash_double_entry (forked at `/Users/johndev/Dev/ash_double_entry`,
  origin `jhlee111/ash_double_entry`, upstream `ash-project/ash_double_entry`)
- ash_double_entry upstream issues: 158 total, **0 on multi-leg / compound entries**

## Goal

Add native **multi-leg journal entry** support to `ash_double_entry` —
following Martin Fowler's *Accounting Transaction* pattern (Transaction
container + N Entries with `Σ debits == Σ credits` invariant). Existing
`Transfer` API is preserved as a layer (a Transaction with exactly 2
entries) for backward compatibility and as a convenience for
two-account transfers. Implementation lives in the GsNet-owned fork at
`jhlee111/ash_double_entry`; an upstream PR is opened for
`ash-project/ash_double_entry` after the design stabilizes.

## Why

GsNet is building an accounting GL where a single business event posts
multiple debits and credits — e.g., a POS sale `DR Cash $500 / DR Card
$1,041.99 / CR Membership Revenue $1,520 / CR Retail Revenue $19.95 /
CR Sales Tax $2.04` (5–6 legs, ADR-0128). MNET (the legacy system
GsNet replaces) already models this natively: `acc.tbAccSlip` has
`slipNo` (Transaction) + `slipRecNo` (Entry). The pattern is
universal — every textbook double-entry system (Fowler, ledger-cli,
QuickBooks, NetSuite, MNET, GAAP itself) uses Transaction + N Entries.

`ash_double_entry`'s current `Transfer` model (one `from_account` +
one `to_account` per row) is the same shape as TigerBeetle and
envato/double_entry — a *transfer* primitive, not a *journal entry*
primitive. Modeling multi-leg journals on top of pairwise transfers
forces a "holding account boilerplate" pattern, which adds noise
without adding value. The clean solution is to add Transaction + Entry
as first-class resources.

ash_double_entry has **zero issues** opened on multi-leg / compound
journal entries. We are first to articulate this and fork +
upstream-PR is a high-leverage contribution to the ash ecosystem.

## Scope

**In scope (this design):**
- New `AshDoubleEntry.Transaction` extension (DSL + transformers)
- New `AshDoubleEntry.Entry` extension
- Modifications to `AshDoubleEntry.Account` so balance computation
  reads from Entry (not Transfer)
- `AshDoubleEntry.Balance` adapted to reify per-entry balance rows
- `AshDoubleEntry.Transfer` retained: `Transfer.create` internally
  creates a Transaction with 2 Entries. Existing user code keeps
  working without modification.
- Sum-balance invariant: `Σ entries.amount where side == :debit ==
  Σ entries.amount where side == :credit` per Transaction
- Reversal pattern: `reverse(transaction)` creates a new Transaction
  with all entry sides flipped
- Tests + documentation
- Migration script for existing users (transfers → transactions +
  entries)
- Upstream PR

**Out of scope (deferred):**
- Period close / locking entries by date
- Multi-currency journal entries (entries within a transaction must
  share currency in v1)
- Sub-ledgers / hierarchical accounts
- Account types (asset / liability / etc.) — application's concern
- GsNet-specific changes (handled by ADR-0128 amendment, separate
  spec/plan)

## Locked design decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | Transfer is a *layer* over Transaction (internally a Transaction with 2 entries). Existing API preserved. | Backward compatibility for upstream PR; Transfer is mathematically a special case (2-leg) of Transaction (N-leg). |
| **D2** | Entry has `side :: :debit \| :credit` + always-positive `amount`. | SQL gradient, validation simplicity, accountant-friendly, prevents sign mistakes. |
| **D3** | Account has no `account_type` (asset/liability/…). Library is sign-convention-agnostic. | Industry convention (TigerBeetle, envato, ledger-cli all share this). Application layer carries the conventions. |
| **D4** | Balance invariant validated at Ash *cascade time* (not DB constraint). | Multi-row sum constraints are awkward in PostgreSQL; Ash transaction is sufficient. |
| **D5** | Reverse / void = new Transaction with flipped sides; original immutable. | GAAP standard. |
| **D6** | New extension `AshDoubleEntry.Transaction` (parallel to existing Account/Transfer/Balance). | Pattern consistency in ash ecosystem; composable. |

## Data model

### `Account` (existing, modified)

No schema changes. Balance calculation source changes from Transfer to
Entry (transparent — the calculation modules behind `:balance_as_of_ulid`
and `:balance_as_of` are rewritten).

**Sign convention** (library-internal, fixed):
- `entry.side == :debit` → adds to account balance
- `entry.side == :credit` → subtracts from account balance

This is a *bookkeeping* convention, NOT an *accounting* convention.
Asset accounts will read positive (debits accumulate), liability /
revenue / equity accounts will read negative (credits accumulate). The
caller maps this to "natural" accounting balances using sign-flip
helpers external to the library.

### `Transaction` (NEW)

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
    create_accept [:reference_type, :reference_id, :memo]
  end

  attributes do
    attribute :reference_type, :string, allow_nil?: true
    attribute :reference_id, :string, allow_nil?: true
    attribute :memo, :string, allow_nil?: true
  end
end
```

Auto-added by extension:
- `:id` (ULID, time-sortable, primary key)
- `:posted_at` (utc_datetime_usec, default now)
- `:inserted_at` (utc_datetime_usec, default now)
- `has_many :entries`
- `:create` action `:post`, accepts `entries:` argument
  `({:array, :map})` — expands into N Entry rows in a single
  transaction with sum-balance validation
- `:reverse` action — creates a new Transaction whose entries flip
  sides of the source. Stores `reverses_transaction_id`.
- Default `:read` action

Validations:
- `entries` argument required, non-empty (≥ 2)
- All entries share currency (v1 single-currency rule)
- `Σ entries.amount where side == :debit == Σ entries.amount where side == :credit`

### `Entry` (NEW)

```elixir
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

Auto-added:
- `:id` (ULID, primary key, derived from parent transaction's id +
  ordinal — preserves time-ordering and groupability)
- `:transaction_id` (FK)
- `:account_id` (FK)
- `:side` :: `:debit | :credit`
- `:amount` (Money, positive)
- `:inserted_at`
- `belongs_to :transaction`
- `belongs_to :account`

Auto-added by extension's `verify_entry` change (analogous to current
`verify_transfer`):
- Locks the affected accounts (uses Account's `:lock_accounts` read action)
- Updates Balance rows for `(account_id, transaction_id)`

Created **only via Transaction**'s `:post` action — no standalone Entry
create action exposed.

### `Balance` (existing, modified)

Schema unchanged. The cascade behavior changes — instead of being
keyed by `(account_id, transfer_id)`, balance rows are keyed by
`(account_id, entry_id)`. Each Entry generates one Balance row per
affected account.

Internally:
- Old: 1 Transfer → 2 Balance rows (one per pair-end)
- New: 1 Entry → 1 Balance row (cascading from Entry creation)

`balance_as_of_ulid` calculation reads the latest Balance row for the
account where `entry_id <= :ulid` (with the Entry ULID being the
canonical key).

### Balance maintenance and write order

A Balance row is a reified running balance: "this account stood at X
immediately after this write". That is only meaningful with a total
order over an account's writes, and the order is the ULID — 48 bits of
millisecond plus 80 random bits. Two writes inside one millisecond
therefore order by coin flip, and a caller may backdate. Both mean a
new write can land BEFORE rows that already exist.

The library's answer is to repair rather than to forbid: whichever
write lands early, every later row of that account is shifted by its
signed delta, in the same transaction. Two invariants follow, and the
property suite checks both:

- `balance_as_of(account, t)` equals a fold over that account's own
  entries and transfers at or before `t`, for any write order.
- A journal either posts completely or writes nothing — Transaction,
  Entry and Balance rows alike.

**One repair path, not one per writer.** With an `entry_resource`
configured an account's rows come in two kinds, keyed by `transfer_id`
or by `entry_id`, and a comparison against one column is NULL for rows
of the other kind — it skips them silently. Both writers therefore go
through the same `:shift_balances_after` action, whose filter compares
both columns: an Entry runs it once with its signed delta, a Transfer
once per account (minus on the source, plus on the destination). The
fork carried two ripples for a while — `:adjust_balance` for Transfers,
`:shift_balances_after` for entries — and the entry-keyed rows the
multi-leg feature introduced were added to one of them only. A Transfer
that sorted before an existing entry then left that account's latest
balance short by the whole transfer, silently. Duplicated ordering rules
drift; there is now one.

Ordering also decides locking. `Transaction.post` locks every account
the journal touches up front, in one batched `FOR UPDATE` issued before
any row of the journal is inserted, which is what keeps two concurrent
journals over the same accounts from deadlocking. `Transfer` still locks
in an after_action, after its own insert has taken key-share locks on
both accounts, and two opposite-direction transfers can deadlock each
other — [issue #14](https://github.com/jhlee111/ash_double_entry/issues/14).

### `Transfer` (existing, layered)

Schema and DSL unchanged. Internally, `Transfer.create` action now:
1. Creates a Transaction (via `Transaction.post`)
2. Cascades 2 Entries:
   - DR Entry: `account_id = to_account_id, side = :debit, amount = transfer.amount`
   - CR Entry: `account_id = from_account_id, side = :credit, amount = transfer.amount`
3. The `transfers` table row is replaced by a database VIEW or by a
   read-only attribute facade — see "Schema migration" below.

### Schema migration (fork-side, for upstream-PR users with existing data)

For ash_double_entry users with existing `transfers` table data:
1. New tables: `transactions` + `entries`
2. Migration script provided: backfills 1 Transaction + 2 Entries per
   existing Transfer row. Idempotent.
3. `transfers` table:
   - **Default**: replaced by VIEW (`SELECT t.id, t.amount, t.from_account_id, t.to_account_id, … FROM transactions t JOIN entries e1 … JOIN entries e2 …`)
   - **Optional**: keep as physical table (insert into `transfers`
     also populates `transactions` + `entries` via Ash change). Less
     storage-efficient but zero-config for users.
4. Balance recomputation: idempotent task that rebuilds Balance rows
   from Entries.

For GsNet (greenfield, D7): drop `ledger_transfers` table, schema is
`ledger_transactions` + `ledger_entries` only.

## DSL design

### Posting a Transaction

```elixir
MyApp.Ledger.Transaction
|> Ash.Changeset.for_create(:post, %{
  reference_type: "order",
  reference_id: order.id,
  memo: "POS sale",
  entries: [
    %{account_id: cash_account.id,         side: :debit,  amount: Money.new!(:USD, 500_00)},
    %{account_id: card_account.id,         side: :debit,  amount: Money.new!(:USD, 1_041_99)},
    %{account_id: mship_revenue_account.id, side: :credit, amount: Money.new!(:USD, 1_520_00)},
    %{account_id: retail_revenue_account.id, side: :credit, amount: Money.new!(:USD, 19_95)},
    %{account_id: tax_account.id,           side: :credit, amount: Money.new!(:USD, 2_04)}
  ]
})
|> Ash.create!(tenant: tenant_id)
```

Returns the Transaction with `entries` loaded.

### Reversing a Transaction

```elixir
transaction
|> Ash.Changeset.for_update(:reverse, %{memo: "Refund of order #{order.id}"})
|> Ash.update!()
```

Creates a new Transaction with `reverses_transaction_id = original.id`
and entries with sides flipped.

### Reading balance

```elixir
account =
  MyApp.Ledger.Account
  |> MyApp.Ledger.get!(account_id, load: :balance_as_of)

account.balance_as_of  # => Money.new!(:USD, 1_541_99)
```

For multi-leg, balance is the cumulative effect across all entries
(positive for debit-natured net, negative for credit-natured net).

### Convenience: Transfer (legacy, unchanged)

```elixir
MyApp.Ledger.Transfer
|> Ash.Changeset.for_create(:transfer, %{
  amount: Money.new!(:USD, 50_00),
  from_account_id: source.id,
  to_account_id: dest.id
})
|> Ash.create!()
```

Internally creates a Transaction with 2 Entries.

## Validation

The `verify_transaction` change (added by extension) runs on Transaction
`:post`:

1. Materialize `entries` argument to in-memory list.
2. Group by `side`. Compute `debit_total = Σ debit entries.amount`,
   `credit_total = Σ credit entries.amount`.
3. Assert `debit_total == credit_total`. If not, return
   `{:error, "Transaction unbalanced: debits=#{debit_total}, credits=#{credit_total}"}`.
4. Assert all entries share the same currency.
5. Lock affected accounts (single locked-set query).
6. Cascade-create Entries inside the same transaction.
7. Adjust Balance rows for each affected account.

A property test fixture matrix in the upstream PR validates:
- Cash sale (3 entries: DR cash, CR rev, CR tax)
- Multi-tender (4+ entries: DR cash + DR card + N revenue/tax)
- Refund via reverse
- Edge: 2 entries (Transfer compatibility)
- Edge: same account on both sides (allowed; e.g., book transfer)

## Reversal contract

```
Transaction.reverse(t1) creates t2 where:
  t2.reverses_transaction_id == t1.id
  t2.entries == [%{e | side: flip(e.side)} for e in t1.entries]
  posted_at = now (not t1.posted_at)
```

Reversal is itself a Transaction; it can be reversed. Net effect on
account balances after reverse-of-reverse is zero.

## Testing strategy

### Unit tests (in fork)
- `Transaction.post` with N entries → succeeds when balanced
- `Transaction.post` returns error when unbalanced
- `Transaction.post` returns error when entries differ in currency
- `Transaction.post` is atomic (one entry create failure rolls back all)
- `Entry.create` not directly callable (no exposed action)
- `Balance` rows match Entry effects after creation

### Integration tests (in fork)
- 5-leg POS sale produces 1 Transaction + 5 Entries + 5 Balance rows
- Account balance equals expected sum across multi-transaction history
- Reverse(t1) produces zero net effect on all involved accounts
- Concurrent posting on same accounts is serialized (lock works)

### Backward-compat tests
- `Transfer.create` produces a Transaction + 2 Entries
- Old user code (before multi-leg) keeps working
- Account balance is correct under mixed Transfer + Transaction usage

### GsNet integration (separate plan, after fork lands)
- ADR-0128 fixture matrix re-runs against new fork
- Multi-tender scenarios from GH #214 validated
- MNET reverse-sync 1:1 mapping verified

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Upstream PR rejected → fork forever | We treat fork as internal library (user-confirmed). PR is best-effort. |
| Backward-compat breaks for existing ash_double_entry users | Comprehensive Transfer-API tests; migration script idempotent; opt-in schema strategy (view vs physical table). |
| Balance lock contention under high concurrency | Same lock semantics as existing Transfer; verified via concurrent test. |
| Schema migration complexity for existing users | Documented migration path with idempotent script + rollback plan. |
| GsNet timeline impact (1–2 weeks) | User-accepted; pilot delay acknowledged. ADR-0128 v1 ships using this. |

## Rollout plan (high-level — detailed phases in implementation plan)

1. **Fork prep** (~0.5 day) — fork branch off main, README/CHANGELOG entry, decision log.
2. **Transaction extension** (~3 days) — DSL, transformers, Transaction resource, `:post` action, balance validator change.
3. **Entry extension** (~2 days) — DSL, transformers, Entry resource, Balance integration.
4. **Account/Balance migration** (~2 days) — `balance_as_of_*` calculations rewritten to read from entries; Balance row keyed by entry.
5. **Transfer-as-layer** (~1 day) — Transfer.create internally posts Transaction + 2 entries.
6. **Reverse action** (~0.5 day) — `:reverse` action implementation.
7. **Migration script** (~1 day) — for existing users.
8. **Tests + docs** (~2 days) — comprehensive test matrix, getting-started guide update, multi-leg tutorial.
9. **Upstream PR + iteration** (~ongoing) — open PR, respond to review.

Total: ~12 person-days. Fits the 1–2 week budget.

## Open implementation questions

- Entry ULID vs UUID: Transaction is ULID for time-sort. Entry ULIDs
  derived from `transaction_id` + ordinal so all entries of a
  transaction sort together. Confirm this scheme during impl.
- Locking strategy for cross-transaction concurrency: current Transfer
  locks both accounts before update; Transaction locks all involved
  accounts. Verify same correctness guarantees for ≥ 3 accounts.
- VIEW vs physical Transfer table: pick one default for upstream;
  document the other as opt-in. Default to VIEW (less storage,
  cleaner). GsNet drops table entirely (D7).
- DSL section name: `transaction` block analogous to existing
  `account` / `transfer`. Confirm no Spark naming conflict.
- Should `:reverse` accept memo? (Yes — needed for audit context.)

These are surfaced during fork implementation, not blocking on this
spec.

## Decisions log

| D | Decision | One-line why |
|---|---|---|
| D-1 (Transfer's fate) | Layer — Transfer creates Transaction internally (deferred to follow-up) | 2-leg is special case of N-leg |
| D-2 (Entry model) | `side` + positive amount | SQL clarity, no sign mistakes |
| D-3 (Account type) | Library agnostic, application handles types | Matches industry libs (TigerBeetle, envato, ledger-cli) |
| D-4 (Validation site) | Ash cascade time | DB sum constraint is awkward |
| D-5 (Reverse semantic) | New Transaction with flipped sides | GAAP standard, immutable original |
| D-6 (DSL extension) | `AshDoubleEntry.Transaction` separate | Consistency with Account/Transfer/Balance |
| D-7 (Balance maintenance) | One repair path — every writer ripples later rows through `:shift_balances_after` | A per-writer ripple has to know every kind of row that exists; duplicated ordering rules drift |

## What this enables

- Real accounting events that span 3+ accounts (DR Cash / CR Revenue /
  CR Sales Tax) post as one Transaction with N Entries — no holding /
  clearing-account boilerplate.
- Future use cases (ASC 606 deferred revenue per-period recognition,
  COGS posting, gift-card liability entries, multi-tender refunds) all
  fit natural Transaction shapes.
- `ash_double_entry` becomes the only ash-ecosystem ledger library
  with first-class multi-leg journal entries.
