defmodule ActivityPub.Web.URLs do
  @moduledoc """
  Builds, parses and routes local URLs from the configured `ActivityPub.Web.URLScheme`.

  A family names one kind of URL: an atom for the callbacks of the scheme (`:actor`, `:actor_inbox`, `:object`, `:collection`, `:shared_inbox`, ...), `{:actor_by_id, type}` for an actor by pointer id, or `{:actor_by_id, type, sub}` for one of its collections (`"inbox"`, `"outbox"`, `"followers"`, `"following"`, `"mls_messages"`).

  Functions taking a scheme work on any `ActivityPub.Web.URLScheme`; the others use the configured one (`scheme/0`).
  """

  alias ActivityPub.Web.URLScheme

  @scheme Application.compile_env(:activity_pub, :url_scheme, URLScheme.Default)

  @doc "The configured `ActivityPub.Web.URLScheme` (`config :activity_pub, :url_scheme, Module`), read at compile time."
  def scheme, do: @scheme

  @actor_families [
    :actor,
    :actor_inbox,
    :actor_outbox,
    :actor_followers,
    :actor_following,
    :actor_mls_messages
  ]
  @families @actor_families ++
              [
                :object,
                :activity,
                :collection,
                :shared_inbox,
                :shared_outbox,
                :remote_interaction,
                :proxy_remote_object
              ]
  @actor_by_id_subs ~w(inbox outbox followers following mls_messages)

  ### Templates ###

  @doc "The scheme's template for a family, or `nil` when it isn't mounted."
  def template(scheme \\ @scheme, family)

  def template(scheme, family) when family in @families, do: apply(scheme, family, [])
  def template(scheme, {:actor_by_id, type}), do: scheme.actor_by_id(type)

  def template(scheme, {:actor_by_id, type, sub}) when sub in @actor_by_id_subs,
    do: URLScheme.child(scheme.actor_by_id(type), sub)

  @doc "The params a family's template must have, so the controllers find what they read (and the minted ids can be built)."
  def required_params(family) when family in @actor_families, do: ["username"]
  def required_params(family) when family in [:object, :activity], do: ["uuid"]
  def required_params(:collection), do: ["type", "uuid"]
  def required_params({:actor_by_id, _}), do: ["id"]
  def required_params({:actor_by_id, _, _}), do: ["id"]
  def required_params(_), do: []

  ### Building ###

  @doc """
  The path of a family's URL, or `nil` when the family isn't mounted.

      iex> ActivityPub.Web.URLs.path(ActivityPub.Web.URLScheme.Default, :actor_followers, username: "alice")
      "/pub/actors/alice/followers"
  """
  def path(scheme, family, params) do
    case template(scheme, family) do
      nil -> nil
      template -> build(template, params)
    end
  end

  def path(family, params), do: path(@scheme, family, params)

  @doc "The full URL (`ActivityPub.Web.base_url/0` + path) of a family, or `nil` when the family isn't mounted."
  def url(scheme, family, params) do
    case path(scheme, family, params) do
      nil -> nil
      path -> base_url() <> path
    end
  end

  def url(family, params), do: url(@scheme, family, params)

  def actor_url(username), do: url(:actor, username: username)
  def actor_by_id_url(type, id), do: url({:actor_by_id, type}, id: id)
  def object_url(uuid), do: url(:object, uuid: uuid)
  def activity_url(uuid), do: url(:activity, uuid: uuid)
  def collection_url(type, uuid), do: url(:collection, type: type, uuid: uuid)
  def shared_inbox_url, do: url(:shared_inbox, [])
  def shared_outbox_url, do: url(:shared_outbox, [])
  def remote_interaction_url, do: url(:remote_interaction, [])

  @doc """
  Fills a template's params in. A glob takes a list of segments or a `/`-separated string.

      iex> ActivityPub.Web.URLs.build("/posts/*path", %{"path" => "2026/11/my post"})
      "/posts/2026/11/my%20post"
  """
  def build(template, params) do
    params = stringify_keys(params)

    "/" <>
      Enum.map_join(parse(template), "/", fn
        {:static, segment} ->
          segment

        {:param, name} ->
          encode(fetch_param!(params, name, template))

        {:glob, name} ->
          fetch_param!(params, name, template) |> glob_segments() |> Enum.map_join("/", &encode/1)
      end)
  end

  ### Parsing ###

  @doc """
  The params of a local URL (or path) of a family, or `:error` when it isn't one.

      iex> ActivityPub.Web.URLs.match(ActivityPub.Web.URLScheme.Default, :collection, "/pub/collections/keyPackages/abc")
      {:ok, %{"type" => "keyPackages", "uuid" => "abc"}}
  """
  def match(scheme, family, url_or_path) do
    with template when is_binary(template) <- template(scheme, family),
         {:ok, path} <- local_path(url_or_path) do
      match_template(template, path)
    else
      _ -> :error
    end
  end

  def match(family, url_or_path), do: match(@scheme, family, url_or_path)

  @doc "Matches a path against a template, giving its params, or `:error`."
  def match_template(template, path) when is_binary(template) and is_binary(path) do
    segments =
      (URI.parse(path).path || "/")
      |> String.split("/", trim: true)
      |> Enum.map(&URI.decode/1)

    do_match(parse(template), segments, %{})
  end

  @doc "The actor type and id of a local URL (or path) of an actor by id, or of one of its collections, or `:error`."
  def match_actor_by_id(scheme \\ @scheme, url_or_path) do
    with {:ok, path} <- local_path(url_or_path) do
      Enum.find_value(URLScheme.actor_types(), :error, fn type ->
        with template when is_binary(template) <- scheme.actor_by_id(type),
             {:ok, %{"id" => id}} <-
               (case match_template(template, path) do
                  {:ok, _} = ok -> ok
                  :error -> match_template(URLScheme.child(template, "*_rest"), path)
                end) do
          {:ok, type, id}
        else
          _ -> nil
        end
      end)
    end
  end

  @doc "The URL a request was made to, without its query: the id of an object served at its id."
  def request_url(%{request_path: path}), do: base_url() <> path

  @doc "The path of a URL on this instance (or a path, as is), or `:error` for another host's."
  def local_path("/" <> _ = path), do: {:ok, path}

  def local_path(url) when is_binary(url) do
    base = String.trim_trailing(base_url(), "/")
    size = byte_size(base)

    case url do
      <<^base::binary-size(^size)>> ->
        {:ok, "/"}

      <<^base::binary-size(^size), "/", _::binary>> ->
        {:ok, binary_part(url, size, byte_size(url) - size)}

      <<^base::binary-size(^size), sep, _::binary>> when sep in [??, ?#] ->
        {:ok, "/"}

      _ ->
        :error
    end
  end

  def local_path(_), do: :error

  ### Routing ###

  @fetch [:activity_json, :load_authorization, :signed_activity_pub_fetch]
  @fetch_or_html [:activity_json_or_html, :load_authorization, :signed_activity_pub_fetch]
  @incoming [:activity_json, :load_authorization, :signed_activity_pub_incoming]
  @browser [:browser]

  @ap ActivityPub.Web.ActivityPubController
  @incoming_ctrl ActivityPub.Web.IncomingActivityPubController
  @c2s ActivityPub.Web.C2SOutboxController
  @proxy ActivityPub.Web.ProxyRemoteObjectController
  @redirect ActivityPub.Web.RedirectController

  defp routes(:actor), do: [{:get, @ap, :actor, @fetch_or_html}]

  defp routes(:actor_inbox),
    do: [{:get, @ap, :maybe_inbox, @fetch}, {:post, @incoming_ctrl, :inbox, @incoming}]

  defp routes(:actor_outbox),
    do: [{:get, @ap, :outbox, @fetch}, {:post, @c2s, :create, @incoming}]

  defp routes(:actor_followers), do: [{:get, @ap, :followers, @fetch}]
  defp routes(:actor_following), do: [{:get, @ap, :following, @fetch}]
  defp routes(:actor_mls_messages), do: [{:get, @ap, :mls_messages, @fetch}]
  defp routes(:object), do: [{:get, @ap, :object, @fetch_or_html}]
  defp routes(:activity), do: [{:get, @ap, :activity_object, @fetch_or_html}]
  defp routes(:collection), do: [{:get, @ap, :collection, @fetch}]

  defp routes(:shared_inbox),
    do: [
      {:get, @ap, :maybe_inbox, @fetch_or_html},
      {:post, @incoming_ctrl, :shared_inbox, @incoming}
    ]

  defp routes(:shared_outbox), do: [{:get, @ap, :shared_outbox, @fetch_or_html}]

  defp routes(:remote_interaction),
    do: [
      {:get, @redirect, :remote_interaction, @browser},
      {:post, @redirect, :remote_interaction, @browser}
    ]

  defp routes(:proxy_remote_object),
    do: [{:post, @proxy, :proxy, @incoming}, {:get, @proxy, :proxy, @incoming}]

  defp routes({:actor_by_id, _}), do: [{:get, @ap, :actor_by_id, @fetch_or_html}]
  defp routes({:actor_by_id, _, "followers"}), do: [{:get, @ap, :followers_by_id, @fetch}]
  defp routes({:actor_by_id, _, "following"}), do: [{:get, @ap, :following_by_id, @fetch}]
  defp routes({:actor_by_id, _, "mls_messages"}), do: [{:get, @ap, :mls_messages_by_id, @fetch}]

  # the POSTs name the actor `:actor_id`, NOT `:id`: Phoenix merges path params into `conn.params`, so `:id` clobbered the posted AP document's own "id" (every activity delivered to such an inbox got stored under the ACTOR's id)
  defp routes({:actor_by_id, _, "inbox"}),
    do: [
      {:get, @ap, :maybe_inbox_by_id, @fetch},
      {:post, @incoming_ctrl, :inbox, @incoming, rename: {"id", "actor_id"}}
    ]

  defp routes({:actor_by_id, _, "outbox"}),
    do: [
      {:get, @ap, :outbox_by_id, @fetch},
      {:post, @c2s, :create, @incoming, rename: {"id", "actor_id"}}
    ]

  @doc """
  The routes a scheme mounts, as `{verb, path, controller, action, pipelines}`, most specific first: comparing segment by segment, a static segment before a `:param` before a `*glob`, so e.g. `GET /inbox` is matched before `GET /:username`, and a glob comes last. Canonical templates come before aliases, and a route whose verb and shape is already mounted is dropped.

  Raises `ArgumentError` when a template lacks a param its controller reads.
  """
  def route_specs(scheme) do
    by_id_families =
      for type <- URLScheme.actor_types(),
          family <- [
            {:actor_by_id, type} | Enum.map(@actor_by_id_subs, &{:actor_by_id, type, &1})
          ],
          do: family

    canonical =
      for family <- @families ++ by_id_families,
          template <- [template(scheme, family)],
          template != nil,
          do: {family, validate!(scheme, family, template, :exact)}

    aliases =
      for {family, templates} <- scheme.aliases(),
          template <- List.wrap(templates),
          do: {family, validate!(scheme, family, template, :subset)}

    object_paths =
      for template <- scheme.object_paths(),
          do: {:object, validate!(scheme, :object_paths, template, :none)}

    (canonical ++ aliases ++ object_paths)
    |> Enum.flat_map(fn {family, template} ->
      for route <- routes(family) do
        case route do
          {verb, controller, action, pipelines} ->
            {verb, template, controller, action, pipelines}

          {verb, controller, action, pipelines, rename: {from, to}} ->
            {verb, rename_param(template, from, to), controller, action, pipelines}
        end
      end
    end)
    |> Enum.sort_by(fn {_, template, _, _, _} -> rank(template) end)
    |> Enum.uniq_by(fn {verb, template, _, _, _} -> {verb, shape(template)} end)
  end

  defp validate!(scheme, family, template, mode) do
    unless is_binary(template) and String.starts_with?(template, "/") do
      raise ArgumentError,
            "#{inspect(scheme)}: the template for #{inspect(family)} must be a path starting with `/`, got: #{inspect(template)}"
    end

    params = for {kind, name} <- parse(template), kind in [:param, :glob], do: name
    required = required_params(family)

    ok? =
      case mode do
        :exact -> Enum.sort(params) == Enum.sort(required)
        :subset -> Enum.all?(required, &(&1 in params))
        :none -> true
      end

    unless ok? do
      raise ArgumentError,
            "#{inspect(scheme)}: the template #{inspect(template)} for #{inspect(family)} must have the params #{inspect(required)}" <>
              if(mode == :exact, do: " and no others", else: "")
    end

    template
  end

  defp rank(template),
    do:
      Enum.map(parse(template), fn
        {:static, _} -> 0
        {:param, _} -> 1
        {:glob, _} -> 2
      end)

  defp shape(template),
    do:
      Enum.map(parse(template), fn
        {:static, s} -> s
        {:param, _} -> :param
        {:glob, _} -> :glob
      end)

  defp rename_param(template, from, to) do
    "/" <>
      Enum.map_join(parse(template), "/", fn
        {:param, ^from} -> ":" <> to
        {:param, name} -> ":" <> name
        {:glob, name} -> "*" <> name
        {:static, s} -> s
      end)
  end

  ### Helpers ###

  defp parse(template) do
    template
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name -> {:param, name}
      "*" <> name -> {:glob, name}
      segment -> {:static, segment}
    end)
  end

  defp do_match([], [], acc), do: {:ok, acc}

  defp do_match([{:glob, name}], [_ | _] = rest, acc),
    do: {:ok, Map.put(acc, name, Enum.join(rest, "/"))}

  defp do_match([{:static, s} | template], [s | path], acc), do: do_match(template, path, acc)

  defp do_match([{:param, name} | template], [value | path], acc),
    do: do_match(template, path, Map.put(acc, name, value))

  defp do_match(_, _, _), do: :error

  defp fetch_param!(params, name, template) do
    case Map.fetch(params, name) do
      {:ok, value} when not is_nil(value) ->
        value

      _ ->
        raise ArgumentError,
              "missing param #{inspect(name)} for URL template #{inspect(template)}"
    end
  end

  defp glob_segments(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp glob_segments(value), do: value |> to_string() |> String.split("/", trim: true)

  # a path segment (RFC 3986 `pchar`): unreserved, sub-delims, `:` and `@` stay as they are
  defp encode(value),
    do: URI.encode(to_string(value), &(URI.char_unreserved?(&1) or &1 in ~c"!$&'()*+,;=:@"))

  defp stringify_keys(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp base_url, do: ActivityPub.Web.base_url()
end
