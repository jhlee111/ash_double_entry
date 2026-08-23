# SPDX-FileCopyrightText: 2023 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox

  setup tags do
    DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  @spec setup_sandbox(any) :: :ok
  def setup_sandbox(tags) do
    start_supervised!(AshDoubleEntry.Test.Repo)

    # A property holds its sandbox connection for the whole `check all`, which on
    # a loaded host runs past the sandbox's 120 s `:ownership_timeout`; ExUnit's
    # own `timeout` tag remains the ceiling. Opt in with
    # `@moduletag ownership_timeout: :infinity`.
    pid =
      Sandbox.start_owner!(AshDoubleEntry.Test.Repo,
        shared: not tags[:async],
        ownership_timeout: tags[:ownership_timeout] || 120_000
      )

    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
