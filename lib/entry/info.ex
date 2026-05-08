# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry.Info do
  @moduledoc "Introspection helpers for the `entry` DSL."

  use Spark.InfoGenerator,
    extension: AshDoubleEntry.Entry,
    sections: [:entry]
end
