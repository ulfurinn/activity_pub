defmodule ActivityPub.Test.RootURLScheme do
  @moduledoc "A URL scheme shaped like an RSS gateway whose URLs predate the library: actors at the root, posts at arbitrary paths."
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
