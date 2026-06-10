# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Entry.Transformers.AddStructure do
  @moduledoc false
  use Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.SetRelationshipSource), do: true
  def before?(Ash.Resource.Transformers.BelongsToAttribute), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(_), do: false

  def transform(dsl) do
    dsl
    |> Ash.Resource.Builder.add_new_attribute(:id, AshDoubleEntry.ULID,
      primary_key?: true,
      allow_nil?: false,
      default: &AshDoubleEntry.ULID.generate/0,
      generated?: false
    )
    |> Ash.Resource.Builder.add_new_attribute(:side, :atom,
      allow_nil?: false,
      constraints: [one_of: [:debit, :credit]]
    )
    |> Ash.Resource.Builder.add_new_attribute(:amount, AshMoney.Types.Money, allow_nil?: false)
    |> Ash.Resource.Builder.add_new_attribute(:timestamp, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0
    )
    |> Ash.Resource.Builder.add_new_attribute(:inserted_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0
    )
    |> Ash.Resource.Builder.add_new_relationship(
      :belongs_to,
      :transaction,
      AshDoubleEntry.Entry.Info.entry_transaction_resource!(dsl),
      attribute_writable?: true,
      define_attribute?: true,
      attribute_type: AshDoubleEntry.ULID,
      allow_nil?: false,
      source_attribute: :transaction_id
    )
    |> Ash.Resource.Builder.add_new_relationship(
      :belongs_to,
      :account,
      AshDoubleEntry.Entry.Info.entry_account_resource!(dsl),
      attribute_writable?: true,
      define_attribute?: true,
      allow_nil?: false,
      source_attribute: :account_id
    )
    |> Ash.Resource.Builder.add_new_action(:create, :create,
      accept: [:transaction_id, :account_id, :side, :amount, :timestamp]
    )
    |> Ash.Resource.Builder.add_change({AshDoubleEntry.Entry.Changes.VerifyEntry, []},
      only_when_valid?: true,
      on: [:create]
    )
    |> add_primary_read_action()
  end

  defp add_primary_read_action({:ok, dsl}), do: add_primary_read_action(dsl)

  defp add_primary_read_action(dsl) do
    if Ash.Resource.Info.primary_action(dsl, :read) do
      {:ok, dsl}
    else
      Ash.Resource.Builder.add_action(dsl, :read, :read,
        primary?: true,
        pagination: Ash.Resource.Builder.build_pagination(keyset?: true, required?: false)
      )
    end
  end
end
