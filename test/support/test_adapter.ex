defmodule ActivityPub.TestAdapter do
  @moduledoc """
  The adapter the library's own tests run with, standing in for a host app: its actors are the rows of `ActivityPub.LocalActor`, and it keeps their follows and blocks, as `handle_activity/1` describes.
  """
  @behaviour ActivityPub.Federator.Adapter

  import Untangle
  import Ecto.Query
  alias ActivityPub.Actor
  alias ActivityPub.LocalActor
  alias ActivityPub.Object
  alias ActivityPub.Utils

  @service_actor_username "service_actor"
  @actor_types ~w(Person Group Organization Application Service)

  def format_actor({:ok, actor}), do: format_actor(actor)

  def format_actor(%LocalActor{local: true} = actor) do
    %Actor{
      id: actor.id,
      data: actor.data,
      local: true,
      keys: actor.keys,
      ap_id: actor.data["id"],
      username: actor.username,
      deactivated: false,
      pointer_id: actor.id
    }
  end

  # a remote actor is as its `ap_object` row has it, with our row's id as its pointer
  def format_actor(%LocalActor{local: false} = actor) do
    case Actor.get_cached(ap_id: actor.data["id"]) do
      {:ok, remote} -> %{remote | pointer_id: actor.id}
      _ -> nil
    end
  end

  def format_actor(_), do: nil

  defp ok_actor(actor) do
    case format_actor(actor) do
      %Actor{} = actor -> {:ok, actor}
      _ -> {:error, :not_found}
    end
  end

  def get_actor_by_username(username), do: ok_actor(LocalActor.get(username: username))

  def get_actor_by_id(id), do: ok_actor(LocalActor.get(id: id))

  def get_actor_by_ap_id(ap_id) do
    case LocalActor.get(ap_id: ap_id) do
      %LocalActor{local: true} = actor -> ok_actor(actor)
      _ -> {:error, :not_found}
    end
  end

  def get_actors_by_ids(ids) do
    ids
    |> LocalActor.list()
    |> Enum.map(&format_actor/1)
    |> Enum.reject(&is_nil/1)
  end

  def maybe_create_remote_actor(%{data: %{"id" => ap_id} = data} = actor) do
    case LocalActor.get(ap_id: ap_id) do
      %LocalActor{} = existing ->
        {:ok, existing}

      nil ->
        with {:ok, row} <-
               LocalActor.insert(%{
                 local: false,
                 data: data,
                 username: Actor.format_username(data) || ap_id
               }) do
          put_pointer(actor, row.id)
          {:ok, row}
        end
    end
  end

  # the remote actor's `ap_object` row points at ours, as a host app's would, so the library can find it by pointer id
  defp put_pointer(%{id: object_id}, pointer_id) when is_binary(object_id) do
    if Utils.is_uuid?(object_id) do
      from(o in Object, where: o.id == ^object_id and is_nil(o.pointer_id))
      |> Utils.repo().update_all(set: [pointer_id: pointer_id])
    end
  end

  defp put_pointer(_, _), do: nil

  def update_local_actor(actor, %{keys: keys, keep_stored_keys: true}) do
    with %LocalActor{} = row <- local_row(actor),
         {:ok, row} <- LocalActor.put_new_keys(row, keys) do
      ok_actor(row)
    else
      _ -> {:error, :not_found}
    end
  end

  def update_local_actor(actor, params) do
    params = Map.delete(params, :keep_stored_keys)

    params =
      case params do
        # the data of the actor itself, as `Factory.add_alias/2` gives it
        %{"id" => _} = data -> %{data: data}
        params -> params
      end

    with %LocalActor{} = row <- local_row(actor),
         {:ok, row} <- LocalActor.update(row, params) do
      ok_actor(row)
    else
      _ -> {:error, :not_found}
    end
  end

  defp local_row(%LocalActor{id: id}), do: LocalActor.get(id: id)
  defp local_row(%{user: %LocalActor{id: id}}), do: LocalActor.get(id: id)
  defp local_row(%{pointer_id: id}) when is_binary(id), do: LocalActor.get(id: id)

  defp local_row(%{username: username}) when is_binary(username),
    do: LocalActor.get(username: username)

  defp local_row(%{data: %{"id" => ap_id}}), do: LocalActor.get(ap_id: ap_id)
  defp local_row(_), do: nil

  def update_remote_actor(_object), do: :ok

  # the host's own record of the remote actor (as `Factory.add_alias/2` changes it), not the actor's document, which is what its server says
  def update_remote_actor(actor, %{data: data}) do
    with %LocalActor{} = row <- row_for(actor),
         {:ok, row} <- LocalActor.update(row, %{data: data}) do
      {:ok, row}
    end
  end

  @doc """
  Keeps the follow graph and blocks, as a host app would: a remote actor's `Follow` of one of ours is recorded and accepted at once, unless ours approves followers by hand (`manuallyApprovesFollowers`, see `Factory.local_actor/1`'s `request_before_follow`), and rejected if ours blocks them; an `Accept` records a follow, and a `Reject` or the `Undo` of a `Follow` forgets it. A `Block` is recorded, and its `Undo` forgotten. A `Flag` is taken only if it names something of ours. Anything else is accepted.

  What it takes is linked to a record "on the host" (a `pointer_id`, see `link_to_host/1`), as a host app links what it stores, since the library takes an object without one as never handed over.
  """
  def handle_activity(%Object{} = activity) do
    case handle(activity) do
      {:ok, _} = ok ->
        link_to_host(activity)
        maybe_publish_c2s(activity)
        ok

      other ->
        other
    end
  end

  defp handle(%Object{data: %{"type" => "Follow"} = data} = follow) do
    case LocalActor.get(ap_id: Object.get_ap_id(data["object"])) do
      %LocalActor{local: true} = followed ->
        cond do
          blocked?(followed, data["actor"]) ->
            {:reject, "blocked"}

          data["state"] in ["accept", "reject"] or
              followed.data["manuallyApprovesFollowers"] == true ->
            {:ok, nil}

          true ->
            with {:ok, _} <- follow(data["actor"], followed),
                 {:ok, followed_actor} <- ok_actor(followed),
                 {:ok, _accept} <-
                   ActivityPub.accept(%{
                     actor: followed_actor,
                     to: [data["actor"]],
                     object: follow,
                     local: true
                   }) do
              {:ok, nil}
            end
        end

      _ ->
        {:ok, nil}
    end
  end

  defp handle(%Object{data: %{"type" => "Accept", "object" => accepted}}) do
    with %{"type" => "Follow", "actor" => follower, "object" => followed} <- data_of(accepted) do
      follow(follower, Object.get_ap_id(followed))
    end

    {:ok, nil}
  end

  defp handle(%Object{data: %{"type" => "Block", "actor" => blocker, "object" => blocked}}) do
    block(blocker, Object.get_ap_id(blocked))
    {:ok, nil}
  end

  defp handle(%Object{data: %{"type" => type, "object" => object}})
       when type in ["Reject", "Undo"] do
    case data_of(object) do
      %{"type" => "Follow", "actor" => follower, "object" => followed} ->
        unfollow(follower, Object.get_ap_id(followed))

      %{"type" => "Block", "actor" => blocker, "object" => blocked} when type == "Undo" ->
        unblock(blocker, Object.get_ap_id(blocked))

      _ ->
        nil
    end

    {:ok, nil}
  end

  # an actor moving: their local followers follow the target instead (remote ones are moved by their own server); a move of nobody but remote followers fails
  defp handle(%Object{data: %{"type" => "Move", "object" => origin, "target" => target}}) do
    with %LocalActor{followers: [_ | _] = followers} = origin <- row_for(Object.get_ap_id(origin)) do
      local_ids = followers |> LocalActor.list() |> Enum.filter(& &1.local) |> Enum.map(& &1.id)

      if local_ids == [] do
        {:error, :move_failed}
      else
        for id <- local_ids do
          follow(%LocalActor{id: id}, Object.get_ap_id(target))
          unfollow(%LocalActor{id: id}, origin)
        end

        {:ok, nil}
      end
    else
      _ -> {:ok, nil}
    end
  end

  # a report is taken only if it names something of ours
  defp handle(%Object{data: %{"type" => "Flag", "object" => flagged}}) do
    if flagged |> List.wrap() |> Enum.any?(&ours?/1),
      do: {:ok, nil},
      else: {:error, :not_found}
  end

  defp handle(_activity), do: {:ok, nil}

  # one of ours handed over is one a client sent in (C2S), whose delivery the library leaves to the host; not one relayed back by a group, nor a `Move`, which the library delivers itself
  defp maybe_publish_c2s(
         %Object{local: true, relayed_by: nil, data: %{"type" => type}} = activity
       )
       when type != "Move",
       do: ActivityPub.Federator.publish(activity)

  defp maybe_publish_c2s(_activity), do: nil

  @doc "Gives the activity, and the object it carries, a pointer id of their own if they have none, as the host app's records of them; actors get theirs from `maybe_create_remote_actor/1`."
  def link_to_host(%Object{data: data} = activity) do
    ap_ids =
      [data["id"], Object.get_ap_id(data["object"])]
      |> Enum.filter(&is_binary/1)

    from(o in Object,
      where: fragment("(?)->>'id'", o.data) in ^ap_ids and is_nil(o.pointer_id),
      select: o
    )
    |> Utils.repo().all()
    |> Enum.reject(&match?(%{data: %{"type" => type}} when type in @actor_types, &1))
    |> Enum.each(fn object ->
      from(o in Object, where: o.id == ^object.id and is_nil(o.pointer_id))
      |> Utils.repo().update_all(set: [pointer_id: Needle.UID.generate()])

      Object.invalidate_cache(object)
    end)

    activity
  end

  defp ours?(ref) do
    case Object.get_ap_id(ref) do
      ap_id when is_binary(ap_id) ->
        match?(%LocalActor{local: true}, LocalActor.get(ap_id: ap_id)) or
          match?({:ok, %Object{local: true}}, Object.get_cached(ap_id: ap_id))

      _ ->
        false
    end
  end

  defp data_of(%{"type" => _} = data), do: data

  defp data_of(id) when is_binary(id) do
    case Object.get_cached(ap_id: id) do
      {:ok, %{data: data}} -> data
      _ -> nil
    end
  end

  defp data_of(_), do: nil

  def get_follower_local_ids(actor, _purpose_or_current_actor \\ nil) do
    case local_row(actor) do
      %LocalActor{followers: followers} -> followers
      _ -> []
    end
  end

  def get_follower_local_ids(actor, purpose_or_current_actor, opts),
    do: get_follower_local_ids(actor, purpose_or_current_actor) |> page(opts)

  def get_following_local_ids(actor, _purpose_or_current_actor \\ nil) do
    case local_row(actor) do
      %LocalActor{id: id} -> LocalActor.following_ids(id)
      _ -> []
    end
  end

  def get_following_local_ids(actor, purpose_or_current_actor, opts),
    do: get_following_local_ids(actor, purpose_or_current_actor) |> page(opts)

  def count_followers(actor, purpose_or_current_actor),
    do: length(get_follower_local_ids(actor, purpose_or_current_actor))

  def count_following(actor, purpose_or_current_actor),
    do: length(get_following_local_ids(actor, purpose_or_current_actor))

  defp page(ids, opts) do
    case {opts[:page], opts[:page_size]} do
      {page, size} when is_integer(page) and page > 0 and is_integer(size) ->
        ids |> Enum.sort() |> Enum.slice((page - 1) * size, size)

      _ ->
        Enum.sort(ids)
    end
  end

  @doc "The ap_ids of the actors with these pointer ids, in their order, without making or caching `Actor`s."
  def get_actor_ap_ids_by_ids(ids) do
    by_id = ids |> LocalActor.list() |> Map.new(&{&1.id, &1.data["id"]})

    ids
    |> Enum.map(&by_id[&1])
    |> Enum.reject(&is_nil/1)
  end

  @doc "Records `follower` as following `followee`; either can be local or remote."
  def follow(follower, followee) do
    with {:ok, follower_id} <- pointer_id(follower),
         %LocalActor{} = followee <- row_for(followee) do
      LocalActor.add_follower(followee, follower_id)
    else
      e -> error(e, "Could not record the follow")
    end
  end

  def unfollow(follower, followee) do
    with {:ok, follower_id} <- pointer_id(follower),
         %LocalActor{} = followee <- row_for(followee) do
      LocalActor.remove_follower(followee, follower_id)
    end
  end

  def following?(follower, followee) do
    with {:ok, follower_id} <- pointer_id(follower),
         %LocalActor{followers: followers} <- row_for(followee) do
      follower_id in followers
    else
      _ -> false
    end
  end

  @doc """
  What `ActivityPub.Test.Helpers.follow/2` does with this adapter: `follower` sends a `Follow` (stored, and delivered if they are ours), which takes effect at once unless `followee` is ours and approves followers by hand (then it waits for an `Accept`).
  """
  def make_follow(follower, followee) do
    with {:ok, follower_actor} <- actor_of(follower),
         {:ok, followee_actor} <- actor_of(followee),
         {:ok, activity} <-
           ActivityPub.follow(%{
             actor: follower_actor,
             object: followee_actor,
             local: follower_actor.local
           }) do
      unless followee_actor.local and
               followee_actor.data["manuallyApprovesFollowers"] == true,
             do: follow(follower_actor, followee_actor)

      {:ok, activity}
    end
  end

  defp actor_of(%{actor: %Actor{} = actor}), do: {:ok, actor}
  defp actor_of(%Actor{} = actor), do: {:ok, actor}
  defp actor_of(actor), do: Actor.get_cached(ap_id: Utils.ap_id(actor))

  @doc "Records that `blocker` blocks `blocked`; either can be local or remote."
  def block(blocker, blocked) do
    with %LocalActor{} = blocker <- row_for(blocker),
         {:ok, blocked_id} <- pointer_id(blocked) do
      LocalActor.add_blocked(blocker, blocked_id)
    else
      e -> error(e, "Could not record the block")
    end
  end

  def unblock(blocker, blocked) do
    with %LocalActor{} = blocker <- row_for(blocker),
         {:ok, blocked_id} <- pointer_id(blocked) do
      LocalActor.remove_blocked(blocker, blocked_id)
    end
  end

  def blocked?(blocker, blocked) do
    with %LocalActor{blocked: blocked_ids} <- row_for(blocker),
         {:ok, blocked_id} <- pointer_id(blocked) do
      blocked_id in blocked_ids
    else
      _ -> false
    end
  end

  defp pointer_id(actor) do
    case row_for(actor) do
      %LocalActor{id: id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  # our row for an actor as stored now (the struct given may be older than the last follow), made for a remote actor we don't have one for yet
  defp row_for(%{user: %LocalActor{id: id}}), do: LocalActor.get(id: id)
  defp row_for(%LocalActor{id: id}), do: LocalActor.get(id: id)

  defp row_for(actor) do
    ap_id = Utils.ap_id(actor)

    case is_binary(ap_id) && LocalActor.get(ap_id: ap_id) do
      %LocalActor{} = row ->
        row

      _ ->
        with true <- is_binary(ap_id),
             {:ok, %Actor{local: false} = remote} <- Actor.get_cached(ap_id: ap_id),
             {:ok, row} <- maybe_create_remote_actor(remote) do
          Actor.invalidate_cache(remote)
          row
        else
          _ -> nil
        end
    end
  end

  def get_or_create_service_actor() do
    case get_actor_by_username(@service_actor_username) do
      {:ok, actor} ->
        {:ok, actor}

      _ ->
        %{data: data} =
          ActivityPub.Factory.build(:local_actor, %{
            username: @service_actor_username,
            type: "Application"
          })

        with {:ok, row} <-
               LocalActor.insert(%{local: true, data: data, username: @service_actor_username}) do
          ok_actor(row)
        end
    end
  end

  def get_redirect_url(%{data: %{"id" => ap_id}}), do: ap_id
  def get_redirect_url(%{"id" => ap_id}), do: ap_id

  def get_redirect_url(username_or_id) when is_binary(username_or_id) do
    case LocalActor.get(username: username_or_id) || LocalActor.get(id: username_or_id) do
      %LocalActor{data: %{"id" => ap_id}} -> ap_id
      _ -> nil
    end
  end

  def get_redirect_url(_), do: nil

  def maybe_publish_object(_id, _opts), do: {:error, :not_found}

  def get_locale(), do: "en"

  def base_url(), do: ActivityPub.Web.Endpoint.url()
end
