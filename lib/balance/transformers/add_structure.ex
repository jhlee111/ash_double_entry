# SPDX-FileCopyrightText: 2023 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Balance.Transformers.AddStructure do
  # Adds all the structure required for the resource. See the getting started guide for more.
  @moduledoc false
  use Spark.Dsl.Transformer
  import Spark.Dsl.Builder
  import Ash.Expr

  def before?(Ash.Resource.Transformers.SetRelationshipSource), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.BelongsToAttribute), do: true
  def before?(_), do: false

  def transform(dsl) do
    storage_type =
      if AshDoubleEntry.Balance.Info.balance_money_composite_type?(dsl) do
        :money_with_currency
      else
        :map
      end

    dsl
    |> Ash.Resource.Builder.add_new_attribute(:id, :uuid,
      primary_key?: true,
      writable?: false,
      generated?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0
    )
    |> Ash.Resource.Builder.add_new_attribute(:balance, AshMoney.Types.Money,
      allow_nil?: false,
      constraints: [
        storage_type: storage_type
      ]
    )
    |> Ash.Resource.Builder.add_new_relationship(
      :belongs_to,
      :transfer,
      AshDoubleEntry.Balance.Info.balance_transfer_resource!(dsl),
      attribute_type: AshDoubleEntry.ULID,
      allow_nil?: true,
      attribute_writable?: true
    )
    |> Ash.Resource.Builder.add_new_relationship(
      :belongs_to,
      :account,
      AshDoubleEntry.Balance.Info.balance_account_resource!(dsl),
      allow_nil?: false,
      attribute_writable?: true
    )
    |> add_primary_read_action()
    |> Ash.Resource.Builder.add_new_action(:create, :upsert_balance,
      accept: upsert_accept(dsl),
      upsert?: true,
      upsert_identity: :unique_references
    )
    |> Ash.Resource.Builder.add_new_identity(:unique_references, [:account_id, :transfer_id],
      pre_check_with: pre_check_with(dsl)
    )
    |> maybe_add_entry_relationship()
    |> maybe_add_entry_identity()
    |> add_shift_action()
    |> Ash.Resource.Builder.add_new_calculation(
      :effective_ulid,
      AshDoubleEntry.ULID,
      expr(transfer_id || entry_id)
    )
  end

  defbuilder maybe_add_entry_relationship(dsl) do
    case AshDoubleEntry.Balance.Info.balance_entry_resource(dsl) do
      {:ok, entry_resource} when not is_nil(entry_resource) ->
        Ash.Resource.Builder.add_new_relationship(
          dsl,
          :belongs_to,
          :entry,
          entry_resource,
          attribute_writable?: true,
          define_attribute?: true,
          attribute_type: AshDoubleEntry.ULID,
          allow_nil?: true,
          source_attribute: :entry_id
        )

      _ ->
        {:ok, dsl}
    end
  end

  # The one ripple for a write that lands before existing rows, of either kind:
  # shift one account's LATER balance rows by a signed delta. Entries run it
  # once; a Transfer runs it twice — minus on the source account, plus on the
  # destination. With an entry resource configured an account's rows come in
  # two kinds, keyed by `transfer_id` or by `entry_id`, and the filter has to
  # compare both: a comparison on one column is NULL for rows of the other kind
  # and silently skips them, which is exactly how Transfer's former ripple,
  # `:adjust_balance`, left an account's latest balance stale.
  defbuilder add_shift_action(dsl) do
    Ash.Resource.Builder.add_new_action(dsl, :update, :shift_balances_after,
      changes: [
        Ash.Resource.Builder.build_action_change(
          {Ash.Resource.Change.Filter, filter: shift_filter(dsl)}
        ),
        Ash.Resource.Builder.build_action_change(
          {AshDoubleEntry.Balance.Changes.ShiftBalance,
           can_add_money?: AshDoubleEntry.Balance.Info.balance_data_layer_can_add_money?(dsl)}
        )
      ],
      arguments: [
        Ash.Resource.Builder.build_action_argument(:account_id, :uuid, allow_nil?: false),
        Ash.Resource.Builder.build_action_argument(:delta, AshMoney.Types.Money,
          allow_nil?: false
        ),
        Ash.Resource.Builder.build_action_argument(:after_ulid, AshDoubleEntry.ULID,
          allow_nil?: false
        )
      ]
    )
  end

  defp shift_filter(dsl) do
    case AshDoubleEntry.Balance.Info.balance_entry_resource(dsl) do
      {:ok, entry_resource} when not is_nil(entry_resource) ->
        expr(
          account_id == ^arg(:account_id) and
            (transfer_id > ^arg(:after_ulid) or entry_id > ^arg(:after_ulid))
        )

      _ ->
        expr(account_id == ^arg(:account_id) and transfer_id > ^arg(:after_ulid))
    end
  end

  defbuilder maybe_add_entry_identity(dsl) do
    case AshDoubleEntry.Balance.Info.balance_entry_resource(dsl) do
      {:ok, entry_resource} when not is_nil(entry_resource) ->
        Ash.Resource.Builder.add_new_identity(
          dsl,
          :unique_account_entry,
          [:account_id, :entry_id],
          pre_check_with: pre_check_with(dsl)
        )

      _ ->
        {:ok, dsl}
    end
  end

  defbuilder add_primary_read_action(dsl) do
    if Ash.Resource.Info.primary_action(dsl, :read) do
      {:ok, dsl}
    else
      Ash.Resource.Builder.add_action(dsl, :read, :_autogenerated_primary_read,
        primary?: true,
        pagination: Ash.Resource.Builder.build_pagination(keyset?: true)
      )
    end
  end

  defp upsert_accept(dsl) do
    base = [:balance, :account_id, :transfer_id]

    case AshDoubleEntry.Balance.Info.balance_entry_resource(dsl) do
      {:ok, entry_resource} when not is_nil(entry_resource) -> base ++ [:entry_id]
      _ -> base
    end
  end

  defp pre_check_with(dsl) do
    case AshDoubleEntry.Balance.Info.balance_pre_check_identities_with(dsl) do
      :error ->
        nil

      {:ok, value} ->
        value
    end
  end
end
