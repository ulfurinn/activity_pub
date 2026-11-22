defmodule ActivityPub.Web.EndpointTest do
  use ActivityPub.Web.ConnCase, async: true

  test "the test endpoint dispatches to the router" do
    conn = get(build_conn(), "/.well-known/host-meta")

    assert conn.state == :sent
    assert conn.status == 200
  end
end
