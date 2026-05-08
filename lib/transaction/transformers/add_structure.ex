# SPDX-FileCopyrightText: 2026 ash_double_entry contributors <https://github.com/ash-project/ash_double_entry/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshDoubleEntry.Transaction.Transformers.AddStructure do
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
    |> Ash.Resource.Builder.add_new_attribute(:posted_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0
    )
    |> Ash.Resource.Builder.add_new_attribute(:inserted_at, :utc_datetime_usec,
      allow_nil?: false,
      default: &DateTime.utc_now/0
    )
    |> Ash.Resource.Builder.add_new_relationship(
      :belongs_to,
      :reverses_transaction,
      Spark.Dsl.Transformer.get_persisted(dsl, :module),
      attribute_writable?: true,
      define_attribute?: true,
      attribute_type: AshDoubleEntry.ULID,
      allow_nil?: true,
      source_attribute: :reverses_transaction_id
    )
    |> Ash.Resource.Builder.add_new_relationship(
      :has_many,
      :entries,
      AshDoubleEntry.Transaction.Info.transaction_entry_resource!(dsl),
      destination_attribute: :transaction_id
    )
    |> Ash.Resource.Builder.add_new_action(:create, :post,
      accept: AshDoubleEntry.Transaction.Info.transaction_create_accept!(dsl),
      arguments: [
        Ash.Resource.Builder.build_action_argument(
          :entries,
          {:array, :map},
          allow_nil?: false
        )
      ],
      changes: [
        Ash.Resource.Builder.build_change(
          {AshDoubleEntry.Transaction.Changes.VerifyTransaction, []}
        )
      ]
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
