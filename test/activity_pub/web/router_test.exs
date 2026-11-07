defmodule ActivityPub.Web.RouterTest do
  use ExUnit.Case, async: true

  defmodule RootRouter do
    use ActivityPub.Web, :router

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    pipeline :load_authorization do
    end

    use ActivityPub.Web.Router, url_scheme: ActivityPub.Test.RootURLScheme
  end

  @ap ActivityPub.Web.ActivityPubController
  @incoming ActivityPub.Web.IncomingActivityPubController

  defp route(router, method, path) do
    case Phoenix.Router.route_info(router, method, path, "localhost") do
      %{plug: plug, plug_opts: action, path_params: params} -> {plug, action, params}
      :error -> :error
    end
  end

  describe "a router mounting a custom scheme" do
    test "serves actors at the root" do
      assert route(RootRouter, "GET", "/alice") == {@ap, :actor, %{"username" => "alice"}}

      assert route(RootRouter, "GET", "/alice/followers") ==
               {@ap, :followers, %{"username" => "alice"}}

      assert route(RootRouter, "POST", "/alice/inbox") ==
               {@incoming, :inbox, %{"username" => "alice"}}
    end

    test "matches the shared inbox before an actor of that name" do
      assert route(RootRouter, "POST", "/inbox") == {@incoming, :shared_inbox, %{}}
      assert route(RootRouter, "GET", "/inbox") == {@ap, :maybe_inbox, %{}}
    end

    test "serves objects at arbitrary paths, and minted ones" do
      assert route(RootRouter, "GET", "/posts/2026/11/07/post-slug") ==
               {@ap, :object, %{"path" => ["posts", "2026", "11", "07", "post-slug"]}}

      assert route(RootRouter, "GET", "/objects/abc") == {@ap, :object, %{"uuid" => "abc"}}
    end

    test "mounts none of the default paths" do
      assert {@ap, :object, _} = route(RootRouter, "GET", "/pub/actors/alice")
      assert route(RootRouter, "POST", "/pub/shared_inbox") == :error
    end
  end

  describe "the default test router" do
    test "still serves the default paths" do
      router = ActivityPub.Web.TestRouter

      assert route(router, "GET", "/pub/actors/alice") == {@ap, :actor, %{"username" => "alice"}}
      assert route(router, "GET", "/users/alice") == {@ap, :actor, %{"username" => "alice"}}

      assert route(router, "POST", "/users/alice") ==
               {@incoming, :inbox, %{"username" => "alice"}}

      assert route(router, "POST", "/pub/shared_inbox") == {@incoming, :shared_inbox, %{}}
      assert route(router, "GET", "/pub/objects/abc") == {@ap, :object, %{"uuid" => "abc"}}
      assert route(router, "GET", "/pub/object/abc") == {@ap, :object, %{"uuid" => "abc"}}

      assert route(router, "GET", "/pub/group/01X/outbox") ==
               {@ap, :outbox_by_id, %{"id" => "01X"}}

      assert route(router, "POST", "/pub/group/01X/inbox") ==
               {@incoming, :inbox, %{"actor_id" => "01X"}}
    end
  end
end
