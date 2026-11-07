defmodule ActivityPub.Test.URLScheme do
  @moduledoc "The default URL scheme, also serving host-supplied object ids under `/posts`, as a host keeping the URLs of its posts would."
  use ActivityPub.Web.URLScheme

  def object_paths, do: ["/posts/*path" | super()]
end
