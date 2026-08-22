# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry do
  @moduledoc """
  An extension for ledger entries (debit / credit lines belonging to a Transaction).

  Entries are created via `Transaction.post`, never directly. Each Entry
  records `side :: :debit | :credit` and a non-negative `amount`.

  The sign lives in `side`, never in `amount` — a negative amount would put it
  in both places at once, and `Transaction.post` refuses one. Zero is allowed.
  (Red-ink / Storno reversal, where a −100 debit returns an account's turnover
  figure to zero instead of showing 100 on each side, is a real practice but
  not expressible by negating `amount` here; it would need its own marker.)
  """

  @entry %Spark.Dsl.Section{
    name: :entry,
    schema: [
      account_resource: [
        type: {:spark, Ash.Resource},
        doc: "The Account resource each Entry references.",
        required: true
      ],
      transaction_resource: [
        type: {:spark, Ash.Resource},
        doc: "The Transaction resource each Entry belongs to.",
        required: true
      ],
      create_accept: [
        type: {:wrap_list, :atom},
        default: [],
        doc: """
        Additional attributes accepted when an Entry is created.

        Entries are never created directly — `Transaction.post` cascades them. Any
        attribute listed here is carried through from the corresponding entry map
        given to `post`, so an application can hang its own dimensions (a line item
        id, a cost centre, a memo) off individual legs of a journal.

        Like every other field of a cascaded Entry, these are written under the
        domain's authorization posture: bypassed on a `:by_default` or
        `:when_requested` domain, authorized on an `authorize :always` domain —
        where your Entry create policies run against the cascade itself. To allow
        entries to be created only by `Transaction.post` on such a domain, write
        the policy with `accessing_from(YourTransaction, :entries)`.
        """
      ]
    ]
  }

  @sections [@entry]

  @transformers [
    AshDoubleEntry.Entry.Transformers.AddStructure
  ]

  use Spark.Dsl.Extension,
    sections: @sections,
    transformers: @transformers
end
