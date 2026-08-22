# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry do
  @moduledoc """
  An extension for ledger entries (debit / credit lines belonging to a Transaction).

  Entries are created via `Transaction.post`, never directly. Each Entry
  records `side :: :debit | :credit` and a positive `amount`.
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

        These attributes are written with authorization bypassed, the same as every
        other field of a cascaded Entry. Do not list an attribute here that you
        intend to guard with an Entry policy.
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
