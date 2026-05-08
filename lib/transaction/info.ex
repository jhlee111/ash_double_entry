# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Transaction.Info do
  @moduledoc "Introspection helpers for the `transaction` DSL."

  use Spark.InfoGenerator,
    extension: AshDoubleEntry.Transaction,
    sections: [:transaction]
end
