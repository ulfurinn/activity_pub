defmodule ActivityPub.Web.URLsTest do
  use ExUnit.Case, async: true

  alias ActivityPub.Web.URLs
  alias ActivityPub.Web.URLScheme.Default

  doctest URLs

  # shaped like an RSS gateway whose URLs predate the library: actors at the root, posts at arbitrary paths
  defmodule RootScheme do
    use ActivityPub.Web.URLScheme

    def actor, do: "/:username"
    def actor_by_id(_type), do: nil
    def object, do: "/objects/:uuid"
    def object_paths, do: ["/*path"]
    def activity, do: "/activity/:uuid"
    def collection, do: "/collections/:type/:uuid"
    def shared_inbox, do: "/inbox"
    def shared_outbox, do: nil
    def remote_interaction, do: "/remote_interaction"
    def proxy_remote_object, do: "/proxy_remote_object"
    def aliases, do: []
  end

  defmodule MissingParamScheme do
    use ActivityPub.Web.URLScheme
    def actor, do: "/people/:name"
  end

  defmodule ExtraParamScheme do
    use ActivityPub.Web.URLScheme
    def object, do: "/objects/:year/:uuid"
  end

  @ap ActivityPub.Web.ActivityPubController
  @incoming ActivityPub.Web.IncomingActivityPubController
  @c2s ActivityPub.Web.C2SOutboxController
  @proxy ActivityPub.Web.ProxyRemoteObjectController
  @redirect ActivityPub.Web.RedirectController

  @fetch [:activity_json, :load_authorization, :signed_activity_pub_fetch]
  @fetch_or_html [:activity_json_or_html, :load_authorization, :signed_activity_pub_fetch]
  @signed_in [:activity_json, :load_authorization, :signed_activity_pub_incoming]

  describe "the default scheme" do
    test "mounts the routes the library has always served" do
      by_id =
        for seg <- ~w(person group organization service application) do
          [
            {:get, "/pub/#{seg}/:id", @ap, :actor_by_id, @fetch_or_html},
            {:get, "/pub/#{seg}/:id/followers", @ap, :followers_by_id, @fetch},
            {:get, "/pub/#{seg}/:id/following", @ap, :following_by_id, @fetch},
            {:get, "/pub/#{seg}/:id/outbox", @ap, :outbox_by_id, @fetch},
            {:get, "/pub/#{seg}/:id/inbox", @ap, :maybe_inbox_by_id, @fetch},
            {:get, "/pub/#{seg}/:id/mls_messages", @ap, :mls_messages_by_id, @fetch},
            {:post, "/pub/#{seg}/:actor_id/inbox", @incoming, :inbox, @signed_in},
            {:post, "/pub/#{seg}/:actor_id/outbox", @c2s, :create, @signed_in}
          ]
        end

      expected =
        List.flatten([
          {:get, "/pub/actors/:username/followers", @ap, :followers, @fetch},
          {:get, "/pub/actors/:username/following", @ap, :following, @fetch},
          {:get, "/pub/actors/:username/outbox", @ap, :outbox, @fetch},
          {:get, "/pub/collections/:type/:uuid", @ap, :collection, @fetch},
          {:get, "/pub/actors/:username/inbox", @ap, :maybe_inbox, @fetch},
          {:get, "/pub/actors/:username/mls_messages", @ap, :mls_messages, @fetch},
          {:get, "/pub/objects/:uuid", @ap, :object, @fetch_or_html},
          {:get, "/pub/object/:uuid", @ap, :object, @fetch_or_html},
          {:get, "/pub/activity/:uuid", @ap, :activity_object, @fetch_or_html},
          {:get, "/pub/actors/:username", @ap, :actor, @fetch_or_html},
          {:get, "/pub/actor/:username", @ap, :actor, @fetch_or_html},
          {:get, "/pub/shared_outbox", @ap, :shared_outbox, @fetch_or_html},
          {:get, "/pub/shared_inbox", @ap, :maybe_inbox, @fetch_or_html},
          {:get, "/users/:username", @ap, :actor, @fetch_or_html},
          {:post, "/users/:username", @incoming, :inbox, @signed_in},
          {:post, "/users/:username/inbox", @incoming, :inbox, @signed_in},
          {:post, "/users/:username/outbox", @c2s, :create, @signed_in},
          {:post, "/pub/actors/:username/inbox", @incoming, :inbox, @signed_in},
          {:post, "/pub/shared_inbox", @incoming, :shared_inbox, @signed_in},
          {:post, "/pub/actors/:username/outbox", @c2s, :create, @signed_in},
          {:post, "/pub/proxy_remote_object", @proxy, :proxy, @signed_in},
          {:get, "/pub/proxy_remote_object", @proxy, :proxy, @signed_in},
          {:get, "/pub/remote_interaction", @redirect, :remote_interaction, [:browser]},
          {:post, "/pub/remote_interaction", @redirect, :remote_interaction, [:browser]},
          {:get, "/authorize_interaction", @redirect, :remote_interaction, [:browser]},
          {:post, "/authorize_interaction", @redirect, :remote_interaction, [:browser]},
          by_id
        ])

      specs = URLs.route_specs(Default)

      assert expected -- specs == []

      # the `/users/:username` interop aliases also answer GETs for the inbox and outbox
      assert Enum.sort(specs -- expected) ==
               Enum.sort([
                 {:get, "/users/:username/inbox", @ap, :maybe_inbox, @fetch},
                 {:get, "/users/:username/outbox", @ap, :outbox, @fetch}
               ])
    end

    test "builds the ids it has always minted" do
      assert URLs.path(Default, :actor, username: "alice") == "/pub/actors/alice"
      assert URLs.path(Default, :object, uuid: "abc") == "/pub/objects/abc"
      assert URLs.path(Default, :activity, %{uuid: "abc"}) == "/pub/activity/abc"
      assert URLs.path(Default, {:actor_by_id, "group"}, id: "01X") == "/pub/group/01X"

      assert URLs.path(Default, {:actor_by_id, "group", "outbox"}, id: "01X") ==
               "/pub/group/01X/outbox"

      assert URLs.path(Default, :shared_inbox, []) == "/pub/shared_inbox"
    end
  end

  describe "a custom scheme" do
    test "mounts static paths before params, and globs last" do
      specs = URLs.route_specs(RootScheme)
      gets = for {:get, path, _, action, _} <- specs, do: {path, action}

      index = fn path -> Enum.find_index(gets, &(elem(&1, 0) == path)) end

      assert index.("/inbox") < index.("/:username")
      assert index.("/objects/:uuid") < index.("/:username/followers")
      assert List.last(gets) == {"/*path", :object}

      assert {:post, "/inbox", @incoming, :shared_inbox, @signed_in} in specs
      assert {:post, "/:username/inbox", @incoming, :inbox, @signed_in} in specs
    end

    test "leaves out the families it turns off" do
      paths = for {_, path, _, _, _} <- URLs.route_specs(RootScheme), do: path

      refute "/pub/shared_outbox" in paths
      refute Enum.any?(paths, &String.contains?(&1, ":id"))
      refute Enum.any?(paths, &String.starts_with?(&1, "/users"))
      assert URLs.path(RootScheme, :shared_outbox, []) == nil
    end

    test "rejects a template without the params its controller reads" do
      assert_raise ArgumentError, ~r/:actor.*username/, fn ->
        URLs.route_specs(MissingParamScheme)
      end
    end

    test "rejects a minted template with params it can't fill" do
      assert_raise ArgumentError, ~r/:object/, fn -> URLs.route_specs(ExtraParamScheme) end
    end
  end

  describe "build and match" do
    test "are inverses" do
      for {template, params} <- [
            {"/:username", %{"username" => "alice"}},
            {"/collections/:type/:uuid", %{"type" => "keyPackages", "uuid" => "abc"}},
            {"/posts/*path", %{"path" => "2026/11/07/post-slug"}},
            {"/u/:username", %{"username" => "a b/c"}}
          ] do
        assert URLs.match_template(template, URLs.build(template, params)) == {:ok, params}
      end
    end

    test "matching ignores the query and fragment" do
      assert URLs.match_template("/:username/followers", "/alice/followers?page=2") ==
               {:ok, %{"username" => "alice"}}
    end

    test "a glob needs at least one segment" do
      assert URLs.match_template("/posts/*path", "/posts") == :error
    end

    test "matches full URLs on this instance only" do
      base = ActivityPub.Web.base_url()

      assert URLs.match(RootScheme, :actor, base <> "/alice") == {:ok, %{"username" => "alice"}}
      assert URLs.match(RootScheme, :actor, "https://elsewhere.example/alice") == :error
    end

    test "finds the actor of a by-id URL, and of its collections" do
      base = ActivityPub.Web.base_url()

      assert URLs.match_actor_by_id(Default, base <> "/pub/group/01X") == {:ok, "group", "01X"}

      assert URLs.match_actor_by_id(Default, "/pub/person/01X/followers") ==
               {:ok, "person", "01X"}

      assert URLs.match_actor_by_id(Default, "/pub/actors/alice") == :error
      assert URLs.match_actor_by_id(RootScheme, "/alice") == :error
    end
  end
end
