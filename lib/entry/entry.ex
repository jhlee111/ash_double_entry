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
