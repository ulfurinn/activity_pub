defmodule ActivityPub.Test.HttpRequestMock do
  import Untangle
  alias ActivityPub.Fixtures
  import Fixtures

  # alias Phoenix.ConnTest

  # alias ActivityPub.Utils

  def request(env) do
    debug(env, "Attempting mock request")

    case env do
      %{
        method: :get,
        url: "http://mastodon.local/hello",
        headers: [{"content-type", "application/json"}, _]
      } ->
        Tesla.Mock.json(%{"my" => "hello"})

      %Tesla.Env{
        url: url,
        method: method,
        headers: headers,
        query: query,
        body: body
      } ->
        with nil <- apply(Fixtures, method, [url, query, body, headers]) do
          case fixtures_generic()[url] do
            nil ->
              none(url, query, body, headers)

            fun ->
              fun.(url)
          end
        else
          other ->
            other
        end
    end

    # |> IO.inspect(label: "moccck")
  end
end
