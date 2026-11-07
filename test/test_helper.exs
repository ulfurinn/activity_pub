# import ActivityPub.Test.Helpers
import ActivityPub.Utils

{:ok, _} = Application.ensure_all_started(:ex_machina)

Repatch.setup()

# tests of what only Bonfire's adapter does (`:bonfire`), or an adapter with E2EE support (`:e2ee`), are left out when testing with `ActivityPub.TestAdapter`
host_only =
  if ActivityPub.Federator.Adapter.adapter() == ActivityPub.TestAdapter,
    do: [:bonfire, :e2ee],
    else: []

ExUnit.start(
  exclude: [:skip, :todo, :fixme, :test_instance, :live_federation] ++ host_only,
  capture_log: true
)

{:ok, _} = Ecto.Adapters.Postgres.ensure_all_started(repo(), :temporary)

# This cleans up the test database and loads the schema
Mix.Task.run("ecto.create")
Mix.Task.run("ecto.migrate")
# Mix.Task.run("ecto.load")

# Start a process ONLY for our test run.
# {:ok, _pid} = repo().start_link() # already started at this point

Ecto.Adapters.SQL.Sandbox.mode(repo(), :manual)
