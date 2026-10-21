defmodule PhoenixKitInbox.Members do
  @moduledoc """
  The recipient circle — which users may be addressed through Inbox.

  Not every account in a PhoenixKit app is a colleague: shops have customers,
  portals have clients. Addressing, suggestions and forwarding all go through
  this module, so only **members** can be written to or found.

  ## The default rule

  A user is a member when any role they hold — every held role, not only the
  one a session is acting as — carries the `"inbox"` permission or the
  superadmin key `"*"`, or when they hold the Owner role (Owner has no
  permission rows; core grants it everything in code). Inactive users are
  never addressable, whatever the rule says.

  ## A host rule

      config :phoenix_kit_inbox, recipient_filter: {MyApp.Inbox, :addressable?}

  The function gets a `%PhoenixKit.Users.Auth.User{}` and returns a boolean;
  it **replaces** the default rule. A filter that raises counts as `false` —
  an error must shut a user out, not let them in.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.RolePermission

  @member_keys ["inbox", "*"]

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Whether `user` is inside the recipient circle."
  @spec member?(User.t()) :: boolean()
  def member?(%User{is_active: false}), do: false

  def member?(%User{} = user) do
    case host_filter() do
      nil -> from(u in User, where: u.uuid == ^user.uuid) |> scope_query() |> repo().exists?()
      filter -> host_allows?(filter, user)
    end
  end

  def member?(_), do: false

  @doc """
  Narrows a query over `PhoenixKit.Users.Auth.User` to members, in SQL, when
  the default rule applies; leaves it alone when a host filter is configured
  (apply `keep/1` to the results then). Use the two together:

      query |> Members.scope_query() |> Repo.all() |> Members.keep()
  """
  @spec scope_query(Ecto.Queryable.t()) :: Ecto.Query.t()
  def scope_query(query) do
    case host_filter() do
      nil -> where(query, [u], u.is_active == true and u.uuid in subquery(member_uuids()))
      _filter -> where(query, [u], u.is_active == true)
    end
  end

  @doc "Filters loaded users through the host rule, when one is configured."
  @spec keep([User.t()]) :: [User.t()]
  def keep(users) do
    case host_filter() do
      nil -> users
      filter -> Enum.filter(users, &host_allows?(filter, &1))
    end
  end

  @doc "Whether a host rule replaces the default one (callers then can't limit in SQL)."
  @spec host_filter?() :: boolean()
  def host_filter?, do: host_filter() != nil

  defp member_uuids do
    owner = Role.system_roles().owner

    member_roles =
      from(r in Role,
        left_join: rp in RolePermission,
        on: rp.role_uuid == r.uuid and rp.module_key in ^@member_keys,
        where: r.name == ^owner or not is_nil(rp.uuid),
        select: r.uuid
      )

    from(ra in RoleAssignment,
      where: ra.role_uuid in subquery(member_roles),
      select: ra.user_uuid
    )
  end

  defp host_filter do
    case Application.get_env(:phoenix_kit_inbox, :recipient_filter) do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> {mod, fun}
      _ -> nil
    end
  end

  defp host_allows?({mod, fun}, user) do
    apply(mod, fun, [user]) == true
  rescue
    e ->
      Logger.warning(
        "[Inbox] recipient_filter raised, treating as not a member: #{Exception.message(e)}"
      )

      false
  end
end
