defmodule ActivityPub.Web.Router do
  @moduledoc """
  Mounts the library's routes into the host's router: `use ActivityPub.Web.Router`.

  The paths come from the configured `ActivityPub.Web.URLScheme` (see `ActivityPub.Web.URLs.route_specs/1`), so they match the ids the library mints. The host router must define the `:browser` and `:load_authorization` pipelines.

  `url_scheme: Module` mounts another scheme's routes, for testing one: the ids the library mints still follow the configured scheme, so a router serving any other would not find them.
  """

  defmacro __using__(opts) do
    scheme =
      Keyword.get(opts, :url_scheme, ActivityPub.Web.URLs.scheme()) |> Macro.expand(__CALLER__)

    Code.ensure_compiled!(scheme)

    routes =
      for {verb, path, controller, action, pipelines} <- ActivityPub.Web.URLs.route_specs(scheme) do
        quote do
          scope "/" do
            pipe_through(unquote(pipelines))
            unquote({verb, [], [path, controller, action]})
          end
        end
      end

    quote do
      # recompile the host router when the scheme changes
      require unquote(scheme)

      # should be already defined in the actual router which is calling this macro
      # pipeline :browser do
      #   plug(:accepts, ["html"])
      # end

      pipeline :html_only do
        plug(:accepts, ["html"])
      end

      pipeline :webfinger do
        plug(:accepts, ["json", "jrd+json", "activity+json", "ld+json"])
      end

      # host-meta accepts any content type since it always returns XML
      pipeline :host_meta do
        plug(:accepts, ~w(xml xrd+xml html json activity+json ld+json jrd+json))
      end

      pipeline :activity_json do
        plug(:accepts, ["json", "activity+json", "ld+json"])
      end

      pipeline :activity_json_or_html do
        plug(:accepts, ["json", "activity+json", "ld+json", "html"])
      end

      pipeline :signed_activity_pub_incoming do
        plug(ActivityPub.Web.Plugs.FetchHTTPSignaturePlug)
        plug(ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug)
        plug(ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug)
      end

      pipeline :signed_activity_pub_fetch do
        plug(ActivityPub.Web.Plugs.FetchHTTPSignaturePlug)
        plug(ActivityPub.Web.Plugs.MappedSignatureToIdentityPlug)
        plug(ActivityPub.Web.Plugs.EnsureHTTPSignaturePlug)
      end

      scope "/.well-known", ActivityPub.Web do
        pipe_through(:webfinger)

        get("/webfinger", WebFingerController, :webfinger)
      end

      scope "/.well-known", ActivityPub.Web do
        pipe_through(:host_meta)

        get("/host-meta", WebFingerController, :host_meta)
      end

      unquote_splicing(routes)
    end
  end
end
