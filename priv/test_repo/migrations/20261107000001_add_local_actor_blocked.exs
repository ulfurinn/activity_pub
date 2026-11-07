defmodule ActivityPub.Repo.Migrations.AddLocalActorBlocked do
  @moduledoc false
  use Ecto.Migration

  # who each actor of `ActivityPub.TestAdapter` blocks (test only, as is the `local_actor` table)
  def change do
    alter table("local_actor") do
      add_if_not_exists(:blocked, {:array, :string}, default: [])
    end
  end
end
