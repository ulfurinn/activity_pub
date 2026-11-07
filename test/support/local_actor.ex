defmodule ActivityPub.LocalActor do
  @moduledoc """
  The actors of `ActivityPub.TestAdapter`, standing in for the users of a host app.

  Each row's `id` is a ULID, as the pointer ids of a host app are, so that the library tells it apart from the UUID of an `ap_object` row. Local actors have `local: true`; a remote actor gets a row too (`local: false`), once it is known, so that it has a pointer id to follow and be followed by. `followers` holds the pointer ids of an actor's followers, and `blocked` those of the actors it blocks.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  import ActivityPub.Utils

  @type t :: %__MODULE__{}

  @primary_key {:id, Needle.UID, autogenerate: true}

  schema "local_actor" do
    field(:data, :map)
    field(:local, :boolean)
    field(:username, :string)
    field(:keys, :string)
    field(:followers, {:array, :string}, default: [])
    field(:blocked, {:array, :string}, default: [])
  end

  def get(id: id) when is_binary(id) do
    if is_uid?(id), do: repo().get(__MODULE__, id)
  end

  def get(ap_id: ap_id) when is_binary(ap_id) do
    repo().one(
      from(actor in __MODULE__,
        where: fragment("(?)->>'id' = ?", actor.data, ^ap_id)
      )
    )
  end

  def get(username: username) when is_binary(username) do
    repo().one(from(actor in __MODULE__, where: actor.username == ^username and actor.local))
  end

  def get(_), do: nil

  def get_cached(username: username), do: get(username: username)

  def list(ids) when is_list(ids) do
    ids = Enum.filter(ids, &is_uid?/1)
    repo().all(from(actor in __MODULE__, where: actor.id in ^ids))
  end

  @doc "The pointer ids of the actors following the actor with `pointer_id` among their followers."
  def following_ids(pointer_id) when is_binary(pointer_id) do
    repo().all(
      from(actor in __MODULE__,
        where: ^pointer_id in actor.followers,
        select: actor.id
      )
    )
  end

  def insert(attrs) do
    attrs
    |> changeset()
    |> repo().insert()
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
  end

  def changeset(object, attrs) do
    object
    |> cast(attrs, [:data, :local, :username, :keys, :followers, :blocked])
    |> validate_required([:data, :username])
  end

  def update(object, attrs) do
    object
    |> change(attrs)
    |> repo().update()
  end

  @doc "Saves `keys` for the actor only if it has none yet, in one statement, and returns the actor with the keys then stored."
  def put_new_keys(%__MODULE__{id: id}, keys) when is_binary(keys) do
    from(actor in __MODULE__, where: actor.id == ^id and is_nil(actor.keys))
    |> repo().update_all(set: [keys: keys])

    {:ok, repo().get!(__MODULE__, id)}
  end

  @doc "Records `follower_id` (a pointer id) as a follower of `followee`."
  def add_follower(%__MODULE__{} = followee, follower_id) when is_binary(follower_id) do
    __MODULE__.update(followee, %{followers: Enum.uniq([follower_id | followee.followers])})
  end

  def remove_follower(%__MODULE__{} = followee, follower_id) when is_binary(follower_id) do
    __MODULE__.update(followee, %{followers: List.delete(followee.followers, follower_id)})
  end

  def add_blocked(%__MODULE__{} = blocker, blocked_id) when is_binary(blocked_id) do
    __MODULE__.update(blocker, %{blocked: Enum.uniq([blocked_id | blocker.blocked])})
  end

  def remove_blocked(%__MODULE__{} = blocker, blocked_id) when is_binary(blocked_id) do
    __MODULE__.update(blocker, %{blocked: List.delete(blocker.blocked, blocked_id)})
  end
end
