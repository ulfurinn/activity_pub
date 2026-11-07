defmodule ActivityPub.Web.ObjectPathsTest do
  @moduledoc "An object whose id the host chose is served at that id, under a template of the URL scheme's `object_paths/0` (`/posts/*path` in tests)."
  use ActivityPub.Web.ConnCase, async: false

  import ActivityPub.Factory

  setup do
    clear_config([:reject_unsigned], false)
  end

  defp fetch(path) do
    build_conn()
    |> put_req_header("accept", "application/activity+json")
    |> get(path)
  end

  test "an object with a host-supplied id is served at it" do
    id = ActivityPub.Web.base_url() <> "/posts/2026/11/07/post-slug"
    insert(:note, data: %{"id" => id})

    assert %{"id" => ^id, "type" => "Note"} =
             fetch("/posts/2026/11/07/post-slug") |> json_response(200)
  end

  test "a path with no object is not found" do
    assert fetch("/posts/2026/11/07/nothing-here") |> json_response(404)
  end

  test "the uuid-named object paths still resolve" do
    %{data: %{"id" => id}} = insert(:note)
    uuid = id |> String.split("/") |> List.last()

    assert %{"id" => ^id} = fetch("/pub/object/#{uuid}") |> json_response(200)
  end
end
