defmodule AshDoubleEntry.Test.Repo.Migrations.AddEntryLineItemId do
  @moduledoc """
  Adds the app-defined `line_item_id` column used by the cascade tests.
  """

  use Ecto.Migration

  def up do
    alter table(:entries) do
      add(:line_item_id, :text)
      add(:internal_note, :text)
    end
  end

  def down do
    alter table(:entries) do
      remove(:line_item_id)
      remove(:internal_note)
    end
  end
end
