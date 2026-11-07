defmodule ActivityPub.Repo.Migrations.AddObjectsTable do
  @moduledoc false
  use Ecto.Migration

  # `ActivityPub.Migrations.up/0` creates its indexes concurrently, which cannot run in a transaction
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    ActivityPub.Migrations.up()
    ActivityPub.Migrations.prepare_test()
  end

  def down do
    ActivityPub.Migrations.down()
  end
end
