defmodule ActivityPub.Web.URLScheme do
  @moduledoc """
  The paths under which the library serves local actors, objects and collections, and mints ids for them.

  A host that needs its own URL layout (e.g. to keep the URLs of an AP implementation it is replacing) implements this behaviour and selects it at compile time:

      config :activity_pub, :url_scheme, MyApp.APUrls

  Both `ActivityPub.Web.Router` (which routes are mounted) and the id builders (`ActivityPub.Web.URLs`) read it, so served and minted URLs can't disagree. Changing it requires recompiling the `activity_pub` dependency and the host router.

  Every callback returns a Phoenix-style path template (a full path, with `:param` and `*glob` segments), or `nil` for a family the host doesn't want mounted. Param names are fixed, since the controllers read them:

  | callback | params |
  |---|---|
  | `actor/0`, `actor_inbox/0`, `actor_outbox/0`, `actor_followers/0`, `actor_following/0`, `actor_mls_messages/0` | `:username` |
  | `actor_by_id/1` (the inbox, outbox etc. are mounted under it) | `:id` |
  | `object/0`, `activity/0` | `:uuid` |
  | `collection/0` | `:type`, `:uuid` |
  | `shared_inbox/0`, `shared_outbox/0`, `remote_interaction/0`, `proxy_remote_object/0` | none |
  | `object_paths/0` | any: objects served there are looked up by their full URL |

  `use ActivityPub.Web.URLScheme` defines every callback with the library's default layout (`ActivityPub.Web.URLScheme.Default`), all overridable, so a host only overrides what differs. The actor's inbox, outbox and collections default to children of `actor/0`.

      defmodule MyApp.APUrls do
        use ActivityPub.Web.URLScheme

        def actor, do: "/:username"
        def actor_by_id(_type), do: nil
        def object, do: "/objects/:uuid"
        def object_paths, do: ["/*path"]
        def shared_inbox, do: "/inbox"
        def shared_outbox, do: nil
        def aliases, do: []
      end
  """

  @typedoc "A Phoenix-style path template, or `nil` when the family isn't mounted."
  @type template :: String.t() | nil

  @doc "The local actor document, by username."
  @callback actor() :: template
  @doc "The actor's inbox (GET answers that only POST is supported, POST delivers)."
  @callback actor_inbox() :: template
  @doc "The actor's outbox (GET reads it, POST is C2S)."
  @callback actor_outbox() :: template
  @callback actor_followers() :: template
  @callback actor_following() :: template
  @doc "MLS-over-ActivityPub `mls:messages`."
  @callback actor_mls_messages() :: template
  @doc "The actor document by pointer id, one family per AP actor type (see `actor_types/0`). Its inbox, outbox, followers, following and mls_messages are mounted as children."
  @callback actor_by_id(type :: String.t()) :: template
  @doc "Template for the ids the library mints for objects and activities created without one. Also served."
  @callback object() :: template
  @doc "Further templates served by the object action. Objects are looked up by the full request URL first, so host-supplied ids at arbitrary paths can be served by a glob here."
  @callback object_paths() :: [String.t()]
  @doc "The FEP-1b12 shape of a stored announce, derived from its id under `object/0`."
  @callback activity() :: template
  @doc "Lib-owned generic collections (e.g. MLS keyPackages)."
  @callback collection() :: template
  @callback shared_inbox() :: template
  @callback shared_outbox() :: template
  @callback remote_interaction() :: template
  @callback proxy_remote_object() :: template
  @doc "Extra, non-canonical templates per family (e.g. `actor: [\"/users/:username\"]`), served but never minted."
  @callback aliases() :: keyword([String.t()])

  @actor_types ~w(person group organization service application)

  @doc "The actor types with an `actor_by_id/1` family."
  def actor_types, do: @actor_types

  @doc "The default base path of the library's routes: `AP_BASE_PATH`, or `/pub`."
  def base_path, do: System.get_env("AP_BASE_PATH", "/pub")

  @doc false
  def child(nil, _), do: nil
  def child(template, segment), do: String.trim_trailing(template, "/") <> "/" <> segment

  defmacro __using__(_opts) do
    quote do
      @behaviour ActivityPub.Web.URLScheme
      import ActivityPub.Web.URLScheme, only: [base_path: 0, child: 2]

      @impl true
      def actor, do: base_path() <> "/actors/:username"
      @impl true
      def actor_inbox, do: child(actor(), "inbox")
      @impl true
      def actor_outbox, do: child(actor(), "outbox")
      @impl true
      def actor_followers, do: child(actor(), "followers")
      @impl true
      def actor_following, do: child(actor(), "following")
      @impl true
      def actor_mls_messages, do: child(actor(), "mls_messages")
      @impl true
      def actor_by_id(type), do: base_path() <> "/" <> type <> "/:id"
      @impl true
      def object, do: base_path() <> "/objects/:uuid"
      # singular is not canonical
      @impl true
      def object_paths, do: [base_path() <> "/object/:uuid"]
      @impl true
      def activity, do: base_path() <> "/activity/:uuid"
      @impl true
      def collection, do: base_path() <> "/collections/:type/:uuid"
      @impl true
      def shared_inbox, do: base_path() <> "/shared_inbox"
      @impl true
      def shared_outbox, do: base_path() <> "/shared_outbox"
      @impl true
      def remote_interaction, do: base_path() <> "/remote_interaction"
      @impl true
      def proxy_remote_object, do: base_path() <> "/proxy_remote_object"

      # `/actor/:username` is a non-canonical singular, `/users/...` is for interop with Mastodon clients and AP testing tools, and Mastodon hardcodes `/authorize_interaction`
      @impl true
      def aliases,
        do: [
          actor: [base_path() <> "/actor/:username", "/users/:username"],
          actor_inbox: ["/users/:username/inbox", "/users/:username"],
          actor_outbox: ["/users/:username/outbox"],
          remote_interaction: ["/authorize_interaction"]
        ]

      defoverridable actor: 0,
                     actor_inbox: 0,
                     actor_outbox: 0,
                     actor_followers: 0,
                     actor_following: 0,
                     actor_mls_messages: 0,
                     actor_by_id: 1,
                     object: 0,
                     object_paths: 0,
                     activity: 0,
                     collection: 0,
                     shared_inbox: 0,
                     shared_outbox: 0,
                     remote_interaction: 0,
                     proxy_remote_object: 0,
                     aliases: 0
    end
  end
end

defmodule ActivityPub.Web.URLScheme.Default do
  @moduledoc "The library's default URL layout, under `AP_BASE_PATH` (`/pub`)."
  use ActivityPub.Web.URLScheme
end
