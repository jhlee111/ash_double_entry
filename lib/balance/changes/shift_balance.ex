# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Balance.Changes.ShiftBalance do
  @moduledoc false
  # Unconditionally shifts a balance by a signed delta — the one ripple the
  # library runs through the LATER balance rows of an account. Entries run it
  # once with their signed delta; a Transfer runs it once per account, minus on
  # the source and plus on the destination.
  use Ash.Resource.Change

  def change(changeset, _, _) do
    delta = changeset.arguments.delta

    Ash.Changeset.force_change_attribute(
      changeset,
      :balance,
      Money.add!(changeset.data.balance, delta)
    )
  end

  def atomic(changeset, opts, _) do
    delta = changeset.arguments.delta

    if Ash.Expr.expr?(delta) do
      raise """
      Delta is dynamic. The balance shift logic does not support this.

      Expected a literal money value, got an expression: #{inspect(delta)}
      """
    end

    if opts[:can_add_money?] do
      {:atomic, %{balance: expr(^atomic_ref(:balance) + ^delta)}}
    else
      {:not_atomic, "Data layer cannot add money, so balance cannot be shifted atomically"}
    end
  end
end
