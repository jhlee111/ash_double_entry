<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

### Added
- `AshDoubleEntry.Transaction` extension — post multi-leg journal entries with N debit/credit Entries via `Transaction.post`. Validates `Σ debits == Σ credits` per currency.
- `AshDoubleEntry.Entry` extension — represents one debit or credit posting within a Transaction. Created only via Transaction.post (no exposed direct create).
- `Transaction.reverse` action — creates a flipped-side reversing Transaction with `reverses_transaction_id` set.
- `Balance` resource gains optional `entry_resource` config + `:entry_id` FK + `(account_id, entry_id)` identity (alongside existing `transfer_id` setup — fully additive). `:transfer_id` relaxed to nullable so entry-driven Balance rows don't require a Transfer.
- `Account.balance_as_of_ulid` and `:balance_as_of` calculations now read from the union of transfer-keyed and entry-keyed Balance rows (transparent to existing Transfer users; new for multi-leg users).
- `mix ash_double_entry.gen.multi_leg_migration` generator — creates `transactions` + `entries` tables.
- New tutorial: `documentation/tutorials/multi-leg-journal-entries.md`.
- Pointer in getting-started tutorial to the multi-leg tutorial.
- `entry.create_accept` — additional attributes accepted when an Entry is created, carried through from the corresponding entry map given to `Transaction.post` and copied off the original's legs by `Transaction.reverse`. Lets an application hang its own dimensions (a line item id, a cost centre) off individual legs of a journal. Like every other field of a cascaded Entry they are written under the domain's authorization posture — bypassed on `:by_default`/`:when_requested` domains, authorized on `authorize :always` domains, where an Entry create policy runs against the cascade (`accessing_from(YourTransaction, :entries)` allows only the cascade).

### Changed
- Existing `Transfer` API and behavior unchanged. Within the (unreleased) multi-leg feature, `Transaction.post` changed in four observable ways:
  - A key on an entry map that the Entry `:create` action does not accept is now rejected, reported at that leg's own index, instead of being silently discarded. This includes `timestamp` and `transaction_id`, which are derived from the transaction and were previously ignored or overridden without comment.
  - Per-leg errors are now pathed `[:entries, index]`. They were previously `[index]` for changeset failures and `[]` — no index at all — for database-constraint failures.
  - `entries` comes back loaded on the `:post` result rather than `%Ash.NotLoaded{}`. The order is Ash's and is not a documented guarantee; do not depend on it.
  - An entry map missing `amount`, or carrying a `side` that is neither debit nor credit, is now a validation error.
  - Every account a journal touches is locked **up front, in one batched statement, before any row of the journal is inserted**, so two concurrent journals over the same accounts queue instead of deadlocking. The lock runs in the caller's context — tenant, actor, tracer — as `Transfer`'s does, so multitenant resources work. `VerifyEntry`'s per-leg lock is now a re-lock of a row the transaction already holds. (`Transfer` itself locks inside an after_action and does not get this protection.) (#4)
  - A leg whose `Money` currency differs from its account's, or whose account does not exist, is a validation error at `[:entries, index]`. The first used to surface as `Ash.Error.Unknown` wrapping `Money.add!`'s `ArgumentError` from inside `VerifyEntry`, the second as a database constraint — neither named the leg. (#5) The account's stored currency code is normalised the way `Transfer` reads it (`Money.new!/2`), so an account opened with `"usd"` still posts. A leg whose `account_id` does not cast to the account's id type is reported at its index as invalid instead of raising out of the lock query. Previously the first raised a `FunctionClauseError` and the second fell out of both sides of the balance check, so an unbalanced journal could post.
  - Every internal call the extension makes — the account lock, the cascaded Entry creates, the Balance upsert and shift, the reversal's read — is now domain-aware (`authorize?: authorize?(changeset.domain)`, as `Transfer` already was) instead of hardcoding `authorize?: false`. `Transaction.post` and `Transaction.reverse` could not run **at all** on a domain configured `authorize :always`; Ash refuses a bare `authorize?: false` there. (#3)
  - `skip_balance_updates` now reaches the cascaded Entries. Ash hands a managed child only the `:shared` slice of its parent's context, so a flag set the ordinary way never arrived and balance rows were written anyway, silently. (#8) It is shared scoped to the Entry resource, so a consumer-managed child on the same changeset (a Transfer managed off the Transaction, say) keeps maintaining its own balances. A `shared` key set on `Transaction.post` now also reaches the Balance writes, as it does on the Transfer path.

## [v1.0.18](https://github.com/ash-project/ash_double_entry/compare/v1.0.17...v1.0.18) (2026-07-13)




## [v1.0.17](https://github.com/ash-project/ash_double_entry/compare/v1.0.16...v1.0.17) (2026-04-12)




### Bug Fixes:

* explicitly prevent transfers to the same account by Zach Daniel

### Improvements:

* Make read_transfers pagination optional (required?: false) (#159) by olivermt

## [v1.0.16](https://github.com/ash-project/ash_double_entry/compare/v1.0.15...v1.0.16) (2026-01-21)




### Bug Fixes:

* #150: added `before?/1` clauses to the three transformers for `SetRelationshipSource` (#151) by Simon Bergström

## [v1.0.15](https://github.com/ash-project/ash_double_entry/compare/v1.0.14...v1.0.15) (2025-06-04)




### Bug Fixes:

* use `{:not_atomic` to trigger the non atomic version of transfer update

## [v1.0.14](https://github.com/ash-project/ash_double_entry/compare/v1.0.13...v1.0.14) (2025-04-10)




### Bug Fixes:

* use data from result for properly atomic transfer verification

## [v1.0.13](https://github.com/ash-project/ash_double_entry/compare/v1.0.12...v1.0.13) (2025-04-10)




### Improvements:

* install latest ash_money

## [v1.0.12](https://github.com/ash-project/ash_double_entry/compare/v1.0.11...v1.0.12) (2025-02-24)




### Bug Fixes:

* don't include VerifyTransfer in the codegen

## [v1.0.11](https://github.com/ash-project/ash_double_entry/compare/v1.0.10...v1.0.11) (2025-02-24)




### Bug Fixes:

* use `utc_datetime_usec` in balance_as_of in installer

## [v1.0.10](https://github.com/ash-project/ash_double_entry/compare/v1.0.9...v1.0.10) (2025-01-26)




### Bug Fixes:

* use correct module reference in installer(#82)

* Use correct argument name for :balance_as_of calc in installer

## [v1.0.9](https://github.com/ash-project/ash_double_entry/compare/v1.0.8...v1.0.9) (2025-01-13)




### Improvements:

* proper reference for section order config in installer

## [v1.0.8](https://github.com/ash-project/ash_double_entry/compare/v1.0.7...v1.0.8) (2025-01-13)




### Improvements:

* add igniter installer

## [v1.0.7](https://github.com/ash-project/ash_double_entry/compare/v1.0.6...v1.0.7) (2025-01-06)




### Bug Fixes:

* add `dump_to_embedded` logic for `AshDoubleEntry.ULID`

* do negation manually instead of in expression

## [v1.0.6](https://github.com/ash-project/ash_double_entry/compare/v1.0.5...v1.0.6) (2024-08-03)




### Bug Fixes:

* properly set authorize option when updating transfers

## [v1.0.5](https://github.com/ash-project/ash_double_entry/compare/v1.0.4...v1.0.5) (2024-08-03)




### Bug Fixes:

* set `authorize?` properly when creating balances

## [v1.0.4](https://github.com/ash-project/ash_double_entry/compare/v1.0.3...v1.0.4) (2024-07-03)




### Bug Fixes:

* better validations around atomics

### Improvements:

* allow skipping balance updates on request

* don't destroy balances by default

## [v1.0.3](https://github.com/ash-project/ash_double_entry/compare/v1.0.2...v1.0.3) (2024-06-23)




### Bug Fixes:

* set a default for `create_accept`

### Improvements:

* use a guaranteed-last ulid for `balance_as_of` calculation

* accept attributes on transfer create

* don't use raising variations of resource calls

## [v1.0.2](https://github.com/ash-project/ash_double_entry/compare/v1.0.1...v1.0.2) (2024-06-18)

### Improvements:

- set context indicating that `ash_double_entry?` is performing an action

## [v1.0.1](https://github.com/ash-project/ash_double_entry/compare/v1.0.0...v1.0.1) (2024-05-11)

### Bug Fixes:

- [AshDoubleEntry.Balance] use `a + -b`, instead of `a - b` (which is not supported by our AshPostgresExtension)

## [v1.0.0](https://github.com/ash-project/ash_double_entry/compare/v1.0.0-rc.1...v1.0.0) (2024-05-10)

## [v1.0.0-rc.1](https://github.com/ash-project/ash_double_entry/compare/v1.0.0-rc.0...v1.0.0-rc.1) (2024-04-29)

### Improvements:

- update to support new atomics & bulk actions

## [v1.0.0-rc.0](https://github.com/ash-project/ash_double_entry/compare/v0.2.4...v1.0.0-rc.0) (2024-04-01)

### Breaking Changes:

- update to Ash 3.0

### Bug Fixes:

- correct amount_delta calculation from destorying (#13)

## [v0.2.4](https://github.com/ash-project/ash_double_entry/compare/v0.2.3...v0.2.4) (2024-02-14)

### Bug Fixes:

- properly update future balances from destroys

- incorrect balance when adding transfer later (#12)

## [v0.2.3](https://github.com/ash-project/ash_double_entry/compare/v0.2.2...v0.2.3) (2023-12-23)

### Bug Fixes:

- make expression pure

### Improvements:

- support updating transfer's amount (#8)

## [v0.2.2](https://github.com/ash-project/ash_double_entry/compare/v0.2.1...v0.2.2) (2023-12-10)

### Improvements:

- support updating transfers, but not important fields

## [v0.2.1](https://github.com/ash-project/ash_double_entry/compare/v0.2.0...v0.2.1) (2023-12-10)

### Bug Fixes:

- use Money..add! For correct return

- properly set context on account read in balance verification

### Improvements:

- support destroying transfers

- set `context_to_opts` when constructing the query

## [v0.2.0](https://github.com/ash-project/ash_double_entry/compare/v0.1.2...v0.2.0) (2023-12-06)

### Features:

- use AshMoney

### Bug Fixes:

- ensure transformers run before `BelongsToAttribute`

- update ash for fix

### Improvements:

- migrate to AshMoney

- update ash

## [v0.1.2](https://github.com/ash-project/ash_double_entry/compare/v0.1.1...v0.1.2) (2023-08-19)

- Documentation updates & AshHq indexing fixes

## [v0.1.1](https://github.com/ash-project/ash_double_entry/compare/v0.1.0...v0.1.1) (2023-08-19)

### Bug Fixes:

- properly calculate balance_as_of_ulid when transfer is to or from account

## [v0.1.0](https://github.com/ash-project/ash_double_entry/compare/v0.1.0...v0.1.0) (2023-08-19)

### Bug Fixes:

- create balances after transfer is created

- don't require pagination

### Improvements:

- add CI & check commands

- wrap up initial implementaiton, add guides

- initial test suite & functionality
