# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Balance.Changes.ShiftBalance do
  @moduledoc false
  # Unconditionally shifts a balance by a signed delta. Used to ripple a
  # backdated entry's effect through the LATER balance rows of one account.
  #
  # Deliberately distinct from AdjustBalance, whose Transfer from/to PAIR
  # semantics (`account_id == from_account_id` -> subtract) would invert the
  # sign when called with a single account.
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
