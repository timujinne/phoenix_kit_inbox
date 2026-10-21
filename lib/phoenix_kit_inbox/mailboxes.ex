defmodule PhoenixKitInbox.Mailboxes do
  @moduledoc """
  Mailbox lifecycle and access control.

  Two ownership models share one table (see
  `PhoenixKitInbox.Schemas.Mailbox`):

    * every user gets exactly one **personal** mailbox, created lazily on first
      visit by `ensure_user_mailbox/1`
    * **shared** mailboxes (`support`, `sales`, …) are created by an admin and
      reached through grants

  Access is a two-level check, matching how `phoenix_kit_calendar` gates other
  people's calendars: the module-level `"inbox"` permission decides whether a
  user can open Inbox at all, and a grant decides which mailboxes they see once
  inside. Ownership always implies `"admin"` access — the owner never needs a
  grant to their own mailbox.

  Every function here takes and returns plain data; the LiveViews own no
  queries of their own.
  """

  import Ecto.Query

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Members
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant

  @type access :: String.t()

  @manage_shared "inbox.manage_shared"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc """
  Fetches a mailbox by uuid.

  Returns `{:error, :mailbox_not_found}` rather than nil so callers can pipe
  through `with` and let `PhoenixKitInbox.Errors` render the reason.
  """
  @spec fetch_mailbox(binary()) :: {:ok, Mailbox.t()} | {:error, :mailbox_not_found}
  def fetch_mailbox(uuid) when is_binary(uuid) do
    # A malformed uuid (a hand-edited `?mailbox=`) is "not found", not a crash.
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Mailbox{} = mailbox <- repo().get(Mailbox, uuid) do
      {:ok, mailbox}
    else
      _ -> {:error, :mailbox_not_found}
    end
  end

  def fetch_mailbox(_), do: {:error, :mailbox_not_found}

  @doc "Fetches a mailbox by its unique slug."
  @spec fetch_mailbox_by_slug(String.t()) :: {:ok, Mailbox.t()} | {:error, :mailbox_not_found}
  def fetch_mailbox_by_slug(slug) when is_binary(slug) do
    case repo().get_by(Mailbox, slug: slug) do
      nil -> {:error, :mailbox_not_found}
      mailbox -> {:ok, mailbox}
    end
  end

  @doc """
  Every mailbox `user_uuid` may open, personal first then shared, each
  alphabetical. Archived and deleted mailboxes are excluded.

  This is the sidebar query — one round trip, no N+1 over grants.
  """
  @spec list_accessible_mailboxes(binary()) :: [Mailbox.t()]
  def list_accessible_mailboxes(user_uuid) when is_binary(user_uuid) do
    granted =
      from(g in MailboxGrant, where: g.user_uuid == ^user_uuid, select: g.mailbox_uuid)

    from(m in Mailbox,
      where: m.status == "active",
      where: m.owner_uuid == ^user_uuid or m.uuid in subquery(granted),
      order_by: [asc: fragment("case when ? = 'user' then 0 else 1 end", m.kind), asc: m.name]
    )
    |> repo().all()
  end

  def list_accessible_mailboxes(_), do: []

  @doc "All shared mailboxes, for the admin management page."
  @spec list_shared_mailboxes() :: [Mailbox.t()]
  def list_shared_mailboxes do
    from(m in Mailbox, where: m.kind == "shared", order_by: [asc: m.name])
    |> repo().all()
  end

  @doc """
  Resolves what someone typed in a To/Cc/Bcc field to a mailbox.

  Accepted, case-insensitively:

    * `"@alice"` — a **username**, the `@` stripped; a shared mailbox's slug
      only when no user has that username
    * `"alice@example.com"` — a user's login **email**, then a shared
      mailbox's `address`
    * `"support"` / `"Customer Support"` — a shared mailbox's slug, name or
      address first, then a username (the pre-`@` behaviour)

  Users are only found inside the recipient circle (`PhoenixKitInbox.Members`):
  a customer account resolves to nothing. Personal mailboxes are reached
  through their user, never through their own `address`, which is a snapshot
  of the owner's email at creation and goes stale when it changes.

  Two candidates for one term — two members whose usernames differ only in
  case (possible on cores before `username` became `citext`), or two shared
  mailboxes with one name — return `{:error, :ambiguous_recipient}` rather
  than an arbitrary pick.

  ## Why users are looked up, not just mailboxes

  Personal mailboxes are created lazily on first visit to Inbox, so a user
  who had never opened the page had no mailbox row. Resolving through the
  user makes an account reachable from the moment it exists; its mailbox is
  created here, on demand, when the first message is addressed to it. That
  write happens outside the send transaction (`Messages.send_message/3`
  resolves recipients before opening it), so a send that later fails leaves
  behind only a mailbox the user would have got on their next visit anyway.
  """
  @spec fetch_mailbox_by_recipient(String.t()) ::
          {:ok, Mailbox.t()} | {:error, :recipient_not_found | :ambiguous_recipient}
  def fetch_mailbox_by_recipient(term) when is_binary(term) do
    case classify_recipient(term) do
      :blank -> {:error, :recipient_not_found}
      {:username, name} -> first_match([&user_by_username/1, &shared_by_handle/1], name)
      {:email, email} -> first_match([&user_by_email/1, &shared_by_address/1], email)
      {:bare, name} -> first_match([&shared_by_any/1, &user_by_username/1], name)
    end
  end

  def fetch_mailbox_by_recipient(_), do: {:error, :recipient_not_found}

  defp classify_recipient(term) do
    case term |> String.trim() |> String.downcase() do
      "" ->
        :blank

      "@" <> name ->
        case String.trim(name) do
          "" -> :blank
          name -> {:username, name}
        end

      normalized ->
        if String.contains?(normalized, "@"), do: {:email, normalized}, else: {:bare, normalized}
    end
  end

  # Each lookup answers {:ok, mailbox}, {:error, :ambiguous_recipient} or
  # :none; the first that is not :none decides.
  defp first_match(lookups, term) do
    Enum.reduce_while(lookups, {:error, :recipient_not_found}, fn lookup, acc ->
      case lookup.(term) do
        :none -> {:cont, acc}
        result -> {:halt, result}
      end
    end)
  end

  defp shared_by_handle(term) do
    shared_matching(term, fn q -> where(q, [m], m.slug == ^term) end)
  end

  defp shared_by_address(term) do
    shared_matching(term, fn q -> where(q, [m], fragment("lower(?)", m.address) == ^term) end)
  end

  # `name` is matched too so a shared mailbox can be addressed the way it is
  # displayed ("Customer Support"), not only by its derived slug.
  defp shared_by_any(term) do
    shared_matching(term, fn q ->
      where(
        q,
        [m],
        fragment("lower(?)", m.address) == ^term or m.slug == ^term or
          fragment("lower(?)", m.name) == ^term
      )
    end)
  end

  # Slug and address are unique, so an exact hit on either wins; several
  # mailboxes sharing a display name are ambiguous.
  defp shared_matching(term, narrow) do
    candidates =
      from(m in Mailbox, where: m.status == "active" and m.kind == "shared")
      |> narrow.()
      |> repo().all()

    exact =
      Enum.find(candidates, &(&1.address && String.downcase(&1.address) == term)) ||
        Enum.find(candidates, &(&1.slug == term))

    case {exact, candidates} do
      {%Mailbox{} = mailbox, _} -> {:ok, mailbox}
      {nil, []} -> :none
      {nil, [mailbox]} -> {:ok, mailbox}
      {nil, _several} -> {:error, :ambiguous_recipient}
    end
  end

  # `lower/1` on both sides rather than `ilike`: this is an equality match,
  # and it stays one on cores where `username` is still a plain string.
  defp user_by_username(term) do
    users_matching(fn q -> where(q, [u], fragment("lower(?)", u.username) == ^term) end)
  end

  defp user_by_email(term) do
    users_matching(fn q -> where(q, [u], fragment("lower(?)", u.email) == ^term) end)
  end

  defp users_matching(narrow) do
    from(u in User, order_by: [asc: u.inserted_at])
    |> narrow.()
    |> Members.scope_query()
    |> repo().all()
    |> Members.keep()
    |> case do
      [] -> :none
      [user] -> mailbox_for_user(user)
      _several -> {:error, :ambiguous_recipient}
    end
  end

  defp mailbox_for_user(user) do
    case ensure_user_mailbox(user) do
      {:ok, mailbox} ->
        {:ok, mailbox}

      # Creation failed. Report it as unresolvable rather than leaking a
      # changeset into a recipient list.
      {:error, _reason} ->
        :none
    end
  end

  @doc """
  The handle that addresses `mailbox` from a To field — `"@username"` (or the
  email, for a user without one) for a personal mailbox, the address or slug
  for a shared one. `nil` for a personal mailbox whose owner is gone.

  Used to prefill a reply; it always resolves back through
  `fetch_mailbox_by_recipient/1` while the owner is a member.
  """
  @spec recipient_handle(Mailbox.t()) :: String.t() | nil
  def recipient_handle(%Mailbox{kind: "user", owner_uuid: owner_uuid})
      when is_binary(owner_uuid) do
    case repo().get(User, owner_uuid) do
      nil -> nil
      user -> user_handle(user)
    end
  end

  def recipient_handle(%Mailbox{kind: "user"}), do: nil
  def recipient_handle(%Mailbox{} = mailbox), do: mailbox.address || mailbox.slug

  @doc "A user's To-field handle: `\"@username\"`, or the email without one."
  @spec user_handle(map()) :: String.t() | nil
  def user_handle(%{username: username}) when is_binary(username) and username != "",
    do: "@" <> username

  def user_handle(%{email: email}), do: email

  @doc """
  Addressable recipients, for the compose field's suggestion list.

  Returns `%{handle: String.t(), label: String.t()}` — `handle` is what goes in
  the To field and resolves through `fetch_mailbox_by_recipient/1`; `label`
  is the human description shown beside it.

  Offers **shared mailboxes and members** (`PhoenixKitInbox.Members`) — users
  outside the recipient circle never appear. A user is offered as
  `"@username"` with their name; their email is shown only when they have
  no username, since it is then the handle itself.

  Covers users who have no mailbox yet: a colleague who never opened Inbox
  is exactly the one a suggestion helps most.
  """
  @spec search_recipients(binary(), String.t(), keyword()) :: [
          %{handle: String.t(), label: String.t()}
        ]
  def search_recipients(user_uuid, term \\ "", opts \\ [])

  def search_recipients(user_uuid, term, opts) when is_binary(user_uuid) do
    limit = Keyword.get(opts, :limit, 20)

    shared = shared_mailbox_suggestions(term, limit)
    users = user_suggestions(user_uuid, term, limit)

    (shared ++ users) |> Enum.uniq_by(& &1.handle) |> Enum.take(limit)
  end

  def search_recipients(_, _, _), do: []

  defp shared_mailbox_suggestions(term, limit) do
    query =
      from(m in Mailbox,
        where: m.status == "active" and m.kind == "shared",
        order_by: [asc: m.name],
        limit: ^limit
      )

    query
    |> filter_by_term(term, fn q, pattern ->
      where(
        q,
        [m],
        ilike(m.name, ^pattern) or ilike(m.slug, ^pattern) or ilike(m.address, ^pattern)
      )
    end)
    |> repo().all()
    |> Enum.map(&%{handle: &1.slug, label: "#{&1.name} (shared mailbox)"})
  end

  # The sender is excluded — a To field offering you yourself is noise, and
  # messaging yourself is still possible by typing the handle. A host rule
  # can't be expressed in SQL, so with one the limit applies after it.
  defp user_suggestions(user_uuid, term, limit) do
    query =
      from(u in User,
        where: u.uuid != ^user_uuid,
        order_by: [asc: u.username]
      )

    query = if Members.host_filter?(), do: query, else: limit(query, ^limit)

    query
    |> filter_by_term(term, fn q, pattern ->
      where(
        q,
        [u],
        ilike(u.username, ^pattern) or ilike(u.email, ^pattern) or
          ilike(u.first_name, ^pattern) or ilike(u.last_name, ^pattern)
      )
    end)
    |> Members.scope_query()
    |> repo().all()
    |> Members.keep()
    |> Enum.take(limit)
    |> Enum.map(&%{handle: user_handle(&1), label: suggestion_label(&1)})
    |> Enum.reject(&is_nil(&1.handle))
  end

  defp suggestion_label(%{username: username} = user)
       when is_binary(username) and username != "",
       do: user_display_name(user)

  defp suggestion_label(user) do
    name = user_display_name(user)

    case user.email do
      nil -> name
      email -> if name == email, do: email, else: "#{name} — #{email}"
    end
  end

  # A blank term lists everything (up to the cap) rather than nothing, so the
  # suggestion list is useful before the first keystroke.
  defp filter_by_term(query, term, apply_filter) do
    case String.trim(to_string(term)) do
      "" -> query
      trimmed -> apply_filter.(query, "%#{trimmed}%")
    end
  end

  def search_mailboxes(_, _, _), do: []

  # ── personal mailboxes ──────────────────────────────────────────────────────

  @doc """
  Returns the user's personal mailbox, creating it on first call.

  Lazy creation rather than a hook on user signup: it keeps Inbox from needing
  to reach into core's registration flow, and it means the module works
  correctly for users who already existed before it was installed.

  The `unique_index ... where kind = 'user'` in V01 makes the race safe — two
  concurrent mounts can both miss the read, and the loser of the insert falls
  back to reading the winner's row.
  """
  @spec ensure_user_mailbox(User.t() | map()) ::
          {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t() | :invalid_user}
  def ensure_user_mailbox(%{uuid: uuid} = user) when is_binary(uuid) do
    case repo().get_by(Mailbox, owner_uuid: uuid, kind: "user") do
      nil -> create_user_mailbox(user)
      mailbox -> {:ok, mailbox}
    end
  end

  def ensure_user_mailbox(_), do: {:error, :invalid_user}

  defp create_user_mailbox(%{uuid: uuid} = user) do
    attrs = %{
      name: user_display_name(user),
      slug: personal_slug(uuid),
      address: Map.get(user, :email),
      kind: "user",
      owner_uuid: uuid
    }

    %Mailbox{}
    |> Mailbox.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, mailbox} ->
        {:ok, mailbox}

      # Lost the insert race — the other process created it, so read it back.
      {:error, changeset} ->
        case repo().get_by(Mailbox, owner_uuid: uuid, kind: "user") do
          nil -> {:error, changeset}
          mailbox -> {:ok, mailbox}
        end
    end
  end

  # Personal slugs are derived from the uuid, not the email: emails change, and
  # a slug collision between two users named "alice" would be a hard failure at
  # signup rather than a cosmetic one.
  defp personal_slug(uuid), do: "u-" <> String.replace(uuid, "-", "")

  @doc """
  Best-effort display name for a user — full name, else username, else the
  local part of their email, else a short uuid.
  """
  @spec user_display_name(map()) :: String.t()
  def user_display_name(user) do
    full_name =
      [Map.get(user, :first_name), Map.get(user, :last_name)]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" ")

    cond do
      full_name != "" -> full_name
      is_binary(Map.get(user, :username)) and user.username != "" -> user.username
      is_binary(Map.get(user, :email)) -> user.email |> String.split("@") |> hd()
      true -> "User " <> String.slice(to_string(Map.get(user, :uuid)), 0, 8)
    end
  end

  # ── shared mailboxes ────────────────────────────────────────────────────────

  @doc """
  Whether `scope` may create shared mailboxes and set their addresses — the
  `inbox.manage_shared` sub-permission, while the module is enabled.
  """
  @spec can_manage_shared?(Scope.t() | nil) :: boolean()
  def can_manage_shared?(scope), do: Scope.can?(scope, @manage_shared)

  @doc """
  Creates a shared mailbox owned by the scope's user.

  Requires `inbox.manage_shared` (`{:error, :forbidden}` otherwise) — checked
  here rather than only in the UI, so a forged form submit or a host call
  can't create one either. There is deliberately no variant taking a bare
  owner uuid.

  `attrs` needs at least `:name`; `:slug` is derived from the name when absent.
  An `:address` must be unique among shared mailboxes (regardless of case) and
  may not be a user's login email.
  """
  @spec create_shared_mailbox(Scope.t(), map()) ::
          {:ok, Mailbox.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def create_shared_mailbox(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, owner_uuid} <- scope_user_uuid(scope),
         :ok <- authorize_manage_shared(scope) do
      attrs =
        attrs
        |> normalize_attrs()
        |> Map.put("kind", "shared")
        |> Map.put("owner_uuid", owner_uuid)
        |> put_default_slug()

      %Mailbox{}
      |> Mailbox.changeset(attrs)
      |> validate_address_not_a_user_email()
      |> repo().insert()
    end
  end

  @doc """
  Updates a mailbox's `name`, `address` or `settings` — nothing else
  (ownership, kind and status have their own paths).

  The scope needs the `"inbox"` permission (`{:error, :forbidden}`) and
  `"admin"` on the mailbox (`{:error, :mailbox_access_denied}`); changing the
  `address` also needs `inbox.manage_shared` (`{:error, :forbidden}`).
  """
  @spec update_mailbox(Scope.t(), Mailbox.t(), map()) ::
          {:ok, Mailbox.t()}
          | {:error, :forbidden | :mailbox_access_denied | Ecto.Changeset.t()}
  def update_mailbox(%Scope{} = scope, %Mailbox{} = mailbox, attrs) when is_map(attrs) do
    changeset =
      Mailbox.changeset(
        mailbox,
        attrs |> normalize_attrs() |> Map.take(~w(name address settings))
      )

    with {:ok, _fresh} <- authorize_scope(scope, mailbox, "admin"),
         :ok <- authorize_address_change(scope, changeset) do
      changeset
      |> validate_address_not_a_user_email()
      |> repo().update()
    end
  end

  defp authorize_manage_shared(scope) do
    if can_manage_shared?(scope), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_address_change(scope, changeset) do
    if Ecto.Changeset.changed?(changeset, :address),
      do: authorize_manage_shared(scope),
      else: :ok
  end

  # A shared address equal to someone's login email would make that string
  # mean two different recipients. Personal mailboxes are exempt — their
  # address *is* their owner's email.
  defp validate_address_not_a_user_email(changeset) do
    address = Ecto.Changeset.get_change(changeset, :address)

    if Ecto.Changeset.get_field(changeset, :kind) == "shared" and is_binary(address) and
         user_email_taken?(address) do
      Ecto.Changeset.add_error(changeset, :address, "is a user's login email")
    else
      changeset
    end
  end

  defp user_email_taken?(address) do
    from(u in User, where: fragment("lower(?)", u.email) == ^String.downcase(address))
    |> repo().exists?()
  end

  @doc """
  Archives a mailbox — the soft-delete form used across this workspace (a
  sentinel on the existing `status` column, never a `deleted_at` timestamp).

  Personal mailboxes cannot be archived: a user always has somewhere for mail
  to land. Needs the `"inbox"` permission and `"admin"` on the mailbox.
  """
  @spec archive_mailbox(Scope.t(), Mailbox.t()) ::
          {:ok, Mailbox.t()}
          | {:error,
             Ecto.Changeset.t()
             | :cannot_archive_personal_mailbox
             | :forbidden
             | :mailbox_access_denied}
  def archive_mailbox(%Scope{} = scope, %Mailbox{} = mailbox) do
    with {:ok, fresh} <- authorize_scope(scope, mailbox, "admin") do
      case fresh do
        %Mailbox{kind: "user"} ->
          {:error, :cannot_archive_personal_mailbox}

        _ ->
          fresh
          |> Mailbox.changeset(%{"status" => "archived"})
          |> repo().update()
      end
    end
  end

  @doc "Reverses `archive_mailbox/2`. Same permissions."
  @spec restore_mailbox(Scope.t(), Mailbox.t()) ::
          {:ok, Mailbox.t()} | {:error, Ecto.Changeset.t() | :forbidden | :mailbox_access_denied}
  def restore_mailbox(%Scope{} = scope, %Mailbox{} = mailbox) do
    with {:ok, fresh} <- authorize_scope(scope, mailbox, "admin") do
      fresh
      |> Mailbox.changeset(%{"status" => "active"})
      |> repo().update()
    end
  end

  @doc "Changeset for mailbox forms."
  @spec change_mailbox(Mailbox.t(), map()) :: Ecto.Changeset.t()
  def change_mailbox(%Mailbox{} = mailbox, attrs \\ %{}) do
    Mailbox.changeset(mailbox, normalize_attrs(attrs))
  end

  # ── account deletion ────────────────────────────────────────────────────────

  @doc """
  Readies `user_uuid`'s mailboxes for the deletion of their account — called
  by `PhoenixKitInbox.before_user_delete/1` while the user row still exists.

    * their personal mailbox is archived (personal mailboxes otherwise can't
      be); its mail stays, readable by nobody until an admin restores it
    * each shared mailbox they own passes to its oldest `"admin"` grantee
      whose account is active, and that grant row goes (ownership already
      means admin); with no such grantee it is archived

  The deletion then clears `owner_uuid` on whatever is still theirs (V02:
  `ON DELETE SET NULL`). Those foreign keys are what keep the mail; this is
  the best-effort part that leaves no live mailbox without an owner.
  """
  @spec handle_user_deletion(binary()) :: :ok
  def handle_user_deletion(user_uuid) when is_binary(user_uuid) do
    repo().transaction(fn ->
      from(m in Mailbox, where: m.owner_uuid == ^user_uuid and m.kind == "user")
      |> repo().all()
      |> Enum.each(&force_archive/1)

      from(m in Mailbox, where: m.owner_uuid == ^user_uuid and m.kind == "shared")
      |> repo().all()
      |> Enum.each(&hand_over(&1, user_uuid))
    end)

    :ok
  end

  defp hand_over(mailbox, leaving_uuid) do
    successor =
      from(g in MailboxGrant,
        join: u in User,
        on: u.uuid == g.user_uuid,
        where: g.mailbox_uuid == ^mailbox.uuid and g.access == "admin",
        where: g.user_uuid != ^leaving_uuid and u.is_active == true,
        order_by: [asc: g.inserted_at, asc: g.uuid],
        limit: 1
      )
      |> repo().one()

    case successor do
      nil ->
        force_archive(mailbox)

      grant ->
        mailbox |> Ecto.Changeset.change(owner_uuid: grant.user_uuid) |> repo().update!()
        repo().delete!(grant)
    end
  end

  # Straight to the column: `archive_mailbox/1` refuses personal mailboxes,
  # and an ownerless mailbox wouldn't pass `Mailbox.changeset/2`.
  defp force_archive(mailbox) do
    mailbox |> Ecto.Changeset.change(status: "archived") |> repo().update!()
  end

  # ── grants ──────────────────────────────────────────────────────────────────

  @doc "All grants on a mailbox, for the mailbox admin page."
  @spec list_grants(binary()) :: [MailboxGrant.t()]
  def list_grants(mailbox_uuid) when is_binary(mailbox_uuid) do
    from(g in MailboxGrant,
      where: g.mailbox_uuid == ^mailbox_uuid,
      order_by: [asc: g.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Grants (or re-grants) `user_uuid` access to a shared mailbox, recorded as
  granted by the scope's user.

  Needs the `"inbox"` permission and `"admin"` on the mailbox. Personal
  mailboxes take no grants (`{:error, :cannot_grant_personal_mailbox}`).

  Upsert semantics: re-granting an existing user simply changes their level,
  which is what "set access to write" means in the UI.
  """
  @spec grant_access(Scope.t(), Mailbox.t(), binary(), access()) ::
          {:ok, MailboxGrant.t()}
          | {:error,
             Ecto.Changeset.t()
             | :cannot_grant_personal_mailbox
             | :forbidden
             | :mailbox_access_denied}
  def grant_access(%Scope{} = scope, %Mailbox{} = mailbox, user_uuid, access) do
    with {:ok, fresh} <- authorize_scope(scope, mailbox, "admin"),
         :ok <- ensure_shared(fresh) do
      {:ok, granted_by} = scope_user_uuid(scope)
      put_grant(fresh.uuid, user_uuid, access, granted_by)
    end
  end

  defp ensure_shared(%Mailbox{kind: "shared"}), do: :ok
  defp ensure_shared(_), do: {:error, :cannot_grant_personal_mailbox}

  defp put_grant(mailbox_uuid, user_uuid, access, granted_by) do
    attrs = %{
      mailbox_uuid: mailbox_uuid,
      user_uuid: user_uuid,
      access: access,
      granted_by_uuid: granted_by
    }

    # A malformed uuid falls through to the changeset, which rejects it.
    existing =
      case Ecto.UUID.cast(user_uuid) do
        {:ok, uuid} -> repo().get_by(MailboxGrant, mailbox_uuid: mailbox_uuid, user_uuid: uuid)
        :error -> nil
      end

    (existing || %MailboxGrant{})
    |> MailboxGrant.changeset(attrs)
    |> then(&if existing, do: repo().update(&1), else: repo().insert(&1))
  end

  @doc """
  Removes a user's grant on a mailbox. Idempotent. Needs the `"inbox"`
  permission and `"admin"` on the mailbox.
  """
  @spec revoke_access(Scope.t(), Mailbox.t(), binary()) ::
          :ok | {:error, :forbidden | :mailbox_access_denied}
  def revoke_access(%Scope{} = scope, %Mailbox{} = mailbox, user_uuid) do
    with {:ok, fresh} <- authorize_scope(scope, mailbox, "admin") do
      case Ecto.UUID.cast(user_uuid) do
        {:ok, uuid} ->
          from(g in MailboxGrant, where: g.mailbox_uuid == ^fresh.uuid and g.user_uuid == ^uuid)
          |> repo().delete_all()

        # Not a uuid, so nobody holds a grant under it.
        :error ->
          :ok
      end

      :ok
    end
  end

  @doc """
  The access level `user_uuid` holds on `mailbox`, or `nil` for none.

  Ownership short-circuits to `"admin"` — the owner is never listed in their
  own grants table.
  """
  @spec access_level(Mailbox.t(), binary()) :: access() | nil
  def access_level(%Mailbox{owner_uuid: owner}, user_uuid)
      when is_binary(user_uuid) and owner == user_uuid,
      do: "admin"

  def access_level(%Mailbox{uuid: mailbox_uuid}, user_uuid) when is_binary(user_uuid) do
    from(g in MailboxGrant,
      where: g.mailbox_uuid == ^mailbox_uuid and g.user_uuid == ^user_uuid,
      select: g.access
    )
    |> repo().one()
  end

  def access_level(_, _), do: nil

  @doc """
  Whether `user_uuid` holds at least `required` access on `mailbox`.

      authorize(mailbox, user_uuid, "write")
  """
  @spec authorize(Mailbox.t(), binary(), access()) :: :ok | {:error, :mailbox_access_denied}
  def authorize(%Mailbox{} = mailbox, user_uuid, required) do
    if MailboxGrant.covers?(access_level(mailbox, user_uuid), required) do
      :ok
    else
      {:error, :mailbox_access_denied}
    end
  end

  @doc """
  The check every caller-acting function runs: the scope's user holds the
  `"inbox"` permission (`{:error, :forbidden}`) and at least `required` on the
  mailbox (`{:error, :mailbox_access_denied}`).

  The mailbox is re-read, so a stale or hand-built struct can't grant more
  than the stored row does; the fresh row is returned for the caller to act
  on (`{:error, :mailbox_not_found}` if it is gone).
  """
  @spec authorize_scope(Scope.t(), Mailbox.t(), access()) ::
          {:ok, Mailbox.t()}
          | {:error, :forbidden | :mailbox_access_denied | :mailbox_not_found}
  def authorize_scope(%Scope{} = scope, %Mailbox{uuid: uuid}, required) do
    with {:ok, user_uuid} <- scope_user_uuid(scope),
         :ok <- authorize_inbox(scope),
         {:ok, fresh} <- fetch_mailbox(uuid),
         :ok <- authorize(fresh, user_uuid, required) do
      {:ok, fresh}
    end
  end

  def authorize_scope(_scope, _mailbox, _required), do: {:error, :forbidden}

  defp authorize_inbox(scope) do
    if Scope.can?(scope, "inbox"), do: :ok, else: {:error, :forbidden}
  end

  @doc "The scope's user uuid, or `{:error, :forbidden}` for an anonymous scope."
  @spec scope_user_uuid(Scope.t() | term()) :: {:ok, binary()} | {:error, :forbidden}
  def scope_user_uuid(%Scope{user: %{uuid: uuid}}) when is_binary(uuid), do: {:ok, uuid}
  def scope_user_uuid(_), do: {:error, :forbidden}

  # ── counts ──────────────────────────────────────────────────────────────────

  @doc """
  Unseen message count per folder for a mailbox, as `%{folder => count}`.

  Folders with nothing unseen are absent from the map — callers use
  `Map.get(counts, folder, 0)`.
  """
  @spec unseen_counts(binary()) :: %{String.t() => non_neg_integer()}
  def unseen_counts(mailbox_uuid) when is_binary(mailbox_uuid) do
    from(d in Delivery,
      where: d.mailbox_uuid == ^mailbox_uuid,
      where: d.status == "active",
      where: is_nil(d.seen_at),
      group_by: d.folder,
      select: {d.folder, count(d.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  def unseen_counts(_), do: %{}

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Forms hand us string keys, tests and internal callers hand us atoms.
  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp put_default_slug(%{"slug" => slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp put_default_slug(%{"name" => name} = attrs) when is_binary(name) do
    Map.put(attrs, "slug", name)
  end

  defp put_default_slug(attrs), do: attrs
end
