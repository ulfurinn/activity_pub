defmodule ActivityPub.Test.SSRFResolver do
  @moduledoc """
  The name resolver `ReqSSRF` uses in tests (see the `:ssrf` config), so no test touches DNS: the fictional hosts of the fixtures (`mastodon.local`, ...) resolve to a public address, as a real instance's would, and `localhost` to loopback. Mirrors `:inet.getaddrs/3`.
  """

  @public_v4 {93, 184, 215, 14}

  def getaddrs(~c"localhost", :inet, _timeout), do: {:ok, [{127, 0, 0, 1}]}
  def getaddrs(~c"localhost", :inet6, _timeout), do: {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
  def getaddrs(_host, :inet, _timeout), do: {:ok, [@public_v4]}
  def getaddrs(_host, :inet6, _timeout), do: {:error, :nxdomain}
end
