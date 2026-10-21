defmodule PhoenixKitInbox.Identities do
  @moduledoc """
  Sending identities and Reply-To choices — who a message goes out *as* when
  it leaves the application (see `PhoenixKitInbox.Schemas.Identity`).

  This module stores, checks and resolves identities; it sends nothing.

  ## The From address

  It is never typed: it is the **login of the integration** (an SMTP
  username that is an email address). A mail server refuses a From it does
  not own, and a typed one would let anyone write as anyone. A mail
  integration with no such login (an API-key provider) can't back an
  identity: `{:integration_unusable, :no_from_address}`.

  ## Who may do what

  Every function takes the caller's `%Scope{}` and checks it here, never only
  in a form:

    * a **shared** identity uses a system integration (`owner: :system`);
      creating, changing and deleting one needs `inbox.manage_shared`
    * bound to a shared mailbox it is used by everyone with `"write"` on that
      mailbox, from that mailbox; bound to none it is the common sender for
      personal mailboxes, used from one's own personal mailbox with
      `inbox.send_external`
    * a **personal** identity uses the owner's own integration
      (`owner: {:user, uuid}`); only the owner creates, changes, deletes and
      uses it, from their personal mailbox

  ## Broken identities

  `check/1` asks core whether the integration still exists, is a mail
  provider with credentials, belongs to the right owner and has a login
  address. Only `resolve/2,3` (every send) and `recheck/2` (the settings
  pages' "Check") run it *and* store the outcome in `status`: a failing
  identity becomes `"broken"` (refused with `{:error, :broken}`), a passing
  one `"active"` again. `list_usable/1` runs it without storing anything;
  the settings listings (`list_personal/1`, `list_shared/1`) show the stored
  status and run no check at all.

  ## Reply-To

  `reply_to_options/2` — the user's own email and the `address` of every
  active shared mailbox they can write to. A message's Reply-To must be one
  of them.
  """

  import Ecto.Query

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Identity
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant

  @manage_shared "inbox.manage_shared"
  @send_external "inbox.send_external"
  @reply_to_setting "reply_to"
  @email ~r/\A[^\s@<>",]+@[^\s@<>",]+\.[^\s@<>",]+\z/

  @typedoc "Why an identity can't send: what `check/1` found."
  @type problem ::
          :integration_missing
          | :not_mail_provider
          | :not_connected
          | :owner_mismatch
          | :no_from_address

  @typedoc "An identity as a sender uses it — what `resolve/2,3` and `list_usable/1` return."
  @type resolved :: %{
          identity_uuid: binary(),
          label: String.t(),
          kind: String.t(),
          mailbox_uuid: binary() | nil,
          integration_uuid: binary(),
          from_address: String.t(),
          from_name: String.t()
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc """
  The identities the scope's user can send from right now, each as
  `t:resolved/0`: the personal ones they own, the shared ones bound to an
  active mailbox they can write to, and — with `inbox.send_external` — the
  shared ones bound to no mailbox. Ones whose integration fails `check/1`
  are left out; nothing is written (a send records it, `resolve/3`).
  Empty without the `"inbox"` permission.
  """
  @spec list_usable(Scope.t()) :: [resolved()]
  def list_usable(%Scope{} = scope) do
    with {:ok, user} <- scope_user(scope), true <- Scope.can?(scope, "inbox") do
      writable = writable_mailbox_uuids(user.uuid)

      usable =
        dynamic(
          [i],
          (i.kind == "personal" and i.owner_uuid == ^user.uuid) or
            (i.kind == "shared" and i.mailbox_uuid in ^writable)
        )

      usable =
        if Scope.can?(scope, @send_external),
          do: dynamic([i], ^usable or (i.kind == "shared" and is_nil(i.mailbox_uuid))),
          else: usable

      from(i in Identity, where: ^usable, order_by: [asc: i.label, asc: i.uuid])
      |> repo().all()
      |> Enum.flat_map(&usable_entry(&1, user))
    else
      _ -> []
    end
  end

  def list_usable(_), do: []

  defp usable_entry(identity, user) do
    case check_integration(identity.integration_uuid, expected_owner(identity)) do
      {:ok, from_address} -> [describe(identity, from_address, user)]
      {:error, _problem} -> []
    end
  end

  # Active mailboxes the user owns or holds a write/admin grant on.
  defp writable_mailbox_uuids(user_uuid) do
    granted =
      from(g in MailboxGrant,
        where: g.user_uuid == ^user_uuid and g.access in ["write", "admin"],
        select: g.mailbox_uuid
      )

    from(m in Mailbox,
      where: m.status == "active",
      where: m.owner_uuid == ^user_uuid or m.uuid in subquery(granted),
      select: m.uuid
    )
    |> repo().all()
  end

  @typedoc """
  An identity as the settings pages list it: its stored `status`, and the
  login of its integration as the From address (`nil` when the connection
  is gone or has none).
  """
  @type listed :: %{identity: Identity.t(), from_address: String.t() | nil}

  @doc """
  The scope user's personal identities, broken ones included (`t:listed/0`).
  For the settings page: a read — no check is run and nothing is written;
  the From addresses come from one query over the user's connections.
  """
  @spec list_personal(Scope.t()) :: [listed()]
  def list_personal(%Scope{} = scope) do
    with {:ok, user} <- scope_user(scope), true <- Scope.can?(scope, "inbox") do
      from(i in Identity,
        where: i.kind == "personal" and i.owner_uuid == ^user.uuid,
        order_by: [asc: i.label, asc: i.uuid]
      )
      |> repo().all()
      |> with_from_addresses({:user, user.uuid})
    else
      _ -> []
    end
  end

  @doc """
  Every shared identity, broken ones included (`t:listed/0`), read like
  `list_personal/1`. Empty without `inbox.manage_shared`. For the admin
  settings page.
  """
  @spec list_shared(Scope.t()) :: [listed()]
  def list_shared(%Scope{} = scope) do
    if Scope.can?(scope, @manage_shared) do
      from(i in Identity, where: i.kind == "shared", order_by: [asc: i.label, asc: i.uuid])
      |> repo().all()
      |> with_from_addresses(:system)
    else
      []
    end
  end

  def list_shared(_), do: []

  # One query for the owner's mail connections, then the login of each
  # identity's own — a display value, not a check.
  defp with_from_addresses(identities, owner) do
    logins =
      Providers.with_capability(:email_send)
      |> Enum.map(& &1.key)
      |> Integrations.load_all_connections(owner: owner)
      |> Enum.flat_map(fn {_provider, connections} -> connections end)
      |> Map.new(fn %{uuid: uuid, data: data} -> {uuid, login_address(data)} end)

    Enum.map(identities, &%{identity: &1, from_address: Map.get(logins, &1.integration_uuid)})
  end

  defp login_address(data) do
    case from_address(data) do
      {:ok, address} -> address
      {:error, _} -> nil
    end
  end

  @doc """
  Runs `check/1` on an identity and stores the outcome in its `status` — the
  settings pages' "Check". Same permissions as changing the identity.
  """
  @spec recheck(Scope.t(), Identity.t()) ::
          {:ok, :ok | {:error, problem()}} | {:error, :forbidden | :not_found}
  def recheck(%Scope{} = scope, %Identity{uuid: uuid}) do
    with {:ok, identity} <- fetch(uuid),
         :ok <- authorize_manage(scope, identity) do
      case checked(identity) do
        {:ok, _identity, _from} -> {:ok, :ok}
        {:error, _identity, problem} -> {:ok, {:error, problem}}
      end
    end
  end

  @doc """
  The mail integrations an identity of `kind` may use, for the forms:
  `:shared` — system ones, needing `inbox.manage_shared`; `:personal` — the
  scope user's own, needing `"inbox"`. Each as `%{uuid, name, from_address}`,
  only those that would pass `check/1`.
  """
  @spec mail_integrations(Scope.t(), :shared | :personal) :: [map()]
  def mail_integrations(%Scope{} = scope, kind) do
    case integration_owner_for(scope, kind) do
      {:ok, owner} ->
        Providers.with_capability(:email_send)
        |> Enum.map(& &1.key)
        |> Integrations.load_all_connections(owner: owner)
        |> Enum.flat_map(fn {_provider, connections} -> connections end)
        |> Enum.flat_map(&integration_choice(&1, owner))
        |> Enum.sort_by(&String.downcase(&1.name))

      {:error, _} ->
        []
    end
  end

  defp integration_choice(%{uuid: uuid, name: name}, owner) do
    case check_integration(uuid, owner) do
      {:ok, from_address} -> [%{uuid: uuid, name: name, from_address: from_address}]
      {:error, _} -> []
    end
  end

  defp integration_owner_for(scope, :shared) do
    if Scope.can?(scope, @manage_shared), do: {:ok, :system}, else: {:error, :forbidden}
  end

  defp integration_owner_for(scope, :personal) do
    with {:ok, user} <- scope_user(scope),
         true <- Scope.can?(scope, "inbox") do
      {:ok, {:user, user.uuid}}
    else
      _ -> {:error, :forbidden}
    end
  end

  # ── resolving ───────────────────────────────────────────────────────────────

  @doc """
  The identity `identity_uuid` as the scope's user would send from it, after
  checking they may (`{:error, :forbidden}`) and that its integration still
  works (`{:error, :broken}`, and the identity is marked so).
  `{:error, :not_found}` for an unknown or malformed uuid.

  `resolve/3` also requires it to belong to `mailbox`, the one the message
  is sent from (`{:error, :identity_not_for_mailbox}`): a bound identity to
  its own mailbox, the others to the user's personal one. **A send must use
  `resolve/3`** (`Messages.send_message/4` does): `resolve/2` answers only
  "may this user send as it at all", and would let a bound identity go out
  from another mailbox.

  Both store the check's outcome in `status`.
  """
  @spec resolve(Scope.t(), term()) ::
          {:ok, resolved()} | {:error, :forbidden | :broken | :not_found}
  def resolve(scope, identity_uuid), do: do_resolve(scope, identity_uuid, nil)

  @spec resolve(Scope.t(), term(), Mailbox.t()) ::
          {:ok, resolved()}
          | {:error, :forbidden | :broken | :not_found | :identity_not_for_mailbox}
  def resolve(scope, identity_uuid, %Mailbox{} = mailbox),
    do: do_resolve(scope, identity_uuid, mailbox)

  defp do_resolve(%Scope{} = scope, identity_uuid, mailbox) do
    with {:ok, identity} <- fetch(identity_uuid),
         {:ok, user} <- scope_user(scope),
         :ok <- authorize_use(scope, user, identity),
         :ok <- fits_mailbox(identity, mailbox, user) do
      case checked(identity) do
        {:ok, identity, from_address} -> {:ok, describe(identity, from_address, user)}
        {:error, _identity, _problem} -> {:error, :broken}
      end
    end
  end

  defp do_resolve(_scope, _uuid, _mailbox), do: {:error, :forbidden}

  defp fetch(uuid) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Identity{} = identity <- repo().get(Identity, uuid) do
      {:ok, identity}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch(_), do: {:error, :not_found}

  defp authorize_use(scope, user, identity) do
    allowed? =
      Scope.can?(scope, "inbox") and
        case identity do
          %Identity{kind: "personal", owner_uuid: owner} ->
            owner == user.uuid

          %Identity{kind: "shared", mailbox_uuid: nil} ->
            Scope.can?(scope, @send_external)

          %Identity{kind: "shared", mailbox_uuid: mailbox_uuid} ->
            mailbox_uuid in writable_mailbox_uuids(user.uuid)
        end

    if allowed?, do: :ok, else: {:error, :forbidden}
  end

  defp fits_mailbox(_identity, nil, _user), do: :ok

  defp fits_mailbox(%Identity{kind: "shared", mailbox_uuid: bound}, mailbox, _user)
       when is_binary(bound) do
    if mailbox.uuid == bound, do: :ok, else: {:error, :identity_not_for_mailbox}
  end

  defp fits_mailbox(_identity, mailbox, user) do
    case Mailboxes.fetch_mailbox(mailbox.uuid) do
      {:ok, %Mailbox{kind: "user", owner_uuid: owner}} when owner == user.uuid -> :ok
      _ -> {:error, :identity_not_for_mailbox}
    end
  end

  # From name: a bound identity its own (else the mailbox's name); the common
  # sender "<user> | <from_name>"; a personal one its own (else the user's).
  defp describe(identity, from_address, user) do
    %{
      identity_uuid: identity.uuid,
      label: identity.label,
      kind: identity.kind,
      mailbox_uuid: identity.mailbox_uuid,
      integration_uuid: identity.integration_uuid,
      from_address: from_address,
      from_name: from_name(identity, user)
    }
  end

  defp from_name(%Identity{kind: "shared", mailbox_uuid: nil, from_name: name}, user) do
    [Mailboxes.user_display_name(user), name]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp from_name(%Identity{kind: "shared", mailbox_uuid: mailbox_uuid, from_name: name}, _user) do
    if blank?(name) do
      case Mailboxes.fetch_mailbox(mailbox_uuid) do
        {:ok, mailbox} -> mailbox.name
        _ -> ""
      end
    else
      name
    end
  end

  defp from_name(%Identity{kind: "personal", owner_uuid: owner_uuid, from_name: name}, _user) do
    if blank?(name) do
      case repo().get(User, owner_uuid) do
        nil -> ""
        owner -> Mailboxes.user_display_name(owner)
      end
    else
      name
    end
  end

  # ── checking ────────────────────────────────────────────────────────────────

  @doc """
  Whether `identity`'s integration can send for it: it exists, is a mail
  provider (`:email_send` capability), has credentials, is owned by the
  system (shared) or by the identity's owner (personal), and has a login
  address. Reads only; `resolve/2,3` and the listings store the outcome.
  """
  @spec check(Identity.t()) :: :ok | {:error, problem()}
  def check(%Identity{} = identity) do
    case check_integration(identity.integration_uuid, expected_owner(identity)) do
      {:ok, _from_address} -> :ok
      {:error, problem} -> {:error, problem}
    end
  end

  # Checks and stores the outcome in `status` when it changed — only for
  # resolve/2,3 and recheck/2.
  defp checked(identity) do
    case check_integration(identity.integration_uuid, expected_owner(identity)) do
      {:ok, from_address} -> {:ok, put_status(identity, "active"), from_address}
      {:error, problem} -> {:error, put_status(identity, "broken"), problem}
    end
  end

  defp put_status(%Identity{status: status} = identity, status), do: identity

  defp put_status(identity, status) do
    {_count, _} =
      from(i in Identity, where: i.uuid == ^identity.uuid)
      |> repo().update_all(set: [status: status])

    %{identity | status: status}
  end

  defp expected_owner(%Identity{kind: "personal", owner_uuid: owner}), do: {:user, owner}
  defp expected_owner(%Identity{}), do: :system

  defp check_integration(uuid, owner) do
    with {:ok, uuid} <- cast_integration(uuid),
         {:ok, %{provider: provider, data: data}} <- integration(uuid),
         :ok <- mail_provider(provider),
         :ok <- owned_by(data, owner),
         {:ok, credentials} <- credentials(uuid, owner) do
      from_address(credentials)
    end
  end

  defp cast_integration(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :integration_missing}
    end
  end

  defp integration(uuid) do
    case Integrations.get_integration_by_uuid(uuid, :any) do
      {:ok, integration} -> {:ok, integration}
      {:error, _} -> {:error, :integration_missing}
    end
  end

  defp mail_provider(provider) do
    mail? =
      Providers.with_capability(:email_send) |> Enum.any?(&(&1.key == provider))

    if mail?, do: :ok, else: {:error, :not_mail_provider}
  end

  # Core's owner shape: no owner_uuid is a system connection; owner_type
  # defaults to "user" for rows written before it was typed.
  defp owned_by(data, :system) do
    if blank?(data["owner_uuid"]), do: :ok, else: {:error, :owner_mismatch}
  end

  defp owned_by(data, {:user, user_uuid}) do
    if data["owner_uuid"] == user_uuid and (data["owner_type"] || "user") == "user",
      do: :ok,
      else: {:error, :owner_mismatch}
  end

  defp credentials(uuid, owner) do
    case Integrations.get_credentials(uuid, owner: owner) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, _} -> {:error, :not_connected}
    end
  end

  defp from_address(%{"username" => username}) when is_binary(username) do
    address = String.trim(username)
    if Regex.match?(@email, address), do: {:ok, address}, else: {:error, :no_from_address}
  end

  defp from_address(_credentials), do: {:error, :no_from_address}

  # ── writes ──────────────────────────────────────────────────────────────────

  @doc """
  Creates a shared identity on a system mail integration. Needs
  `inbox.manage_shared` (`{:error, :forbidden}`).

  `attrs`: `"label"`, `"from_name"`, `"integration_uuid"` and optionally
  `"mailbox_uuid"` — an existing shared mailbox (`{:error,
  :mailbox_not_found}` otherwise). The integration must pass `check/1`
  (`{:error, {:integration_unusable, problem}}`). Anything else in `attrs`
  (kind, owner, status) is ignored.
  """
  @spec create_shared(Scope.t(), map()) ::
          {:ok, Identity.t()}
          | {:error,
             :forbidden
             | :mailbox_not_found
             | {:integration_unusable, problem()}
             | Ecto.Changeset.t()}
  def create_shared(%Scope{} = scope, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- authorize_manage_shared(scope),
         {:ok, mailbox_uuid} <- shared_mailbox_uuid(Map.get(attrs, "mailbox_uuid")),
         {:ok, integration_uuid} <- usable_integration(attrs["integration_uuid"], :system) do
      %Identity{
        kind: "shared",
        mailbox_uuid: mailbox_uuid,
        integration_uuid: integration_uuid
      }
      |> Identity.changeset(attrs)
      |> repo().insert()
    end
  end

  @doc """
  Creates a personal identity on the scope user's own mail integration.
  Needs `"inbox"` (`{:error, :forbidden}`); another user's or a system
  integration is `{:error, {:integration_unusable, :owner_mismatch}}`.

  `attrs`: `"label"`, `"from_name"`, `"integration_uuid"`.
  """
  @spec create_personal(Scope.t(), map()) ::
          {:ok, Identity.t()}
          | {:error, :forbidden | {:integration_unusable, problem()} | Ecto.Changeset.t()}
  def create_personal(%Scope{} = scope, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, user} <- scope_user(scope),
         :ok <- authorize_inbox(scope),
         {:ok, integration_uuid} <-
           usable_integration(attrs["integration_uuid"], {:user, user.uuid}) do
      %Identity{kind: "personal", owner_uuid: user.uuid, integration_uuid: integration_uuid}
      |> Identity.changeset(attrs)
      |> repo().insert()
    end
  end

  @doc """
  Changes an identity's `"label"`, `"from_name"`, `"integration_uuid"` (checked
  again) and, for a shared one, `"mailbox_uuid"`. Same permissions as
  creating it, judged on the stored row.
  """
  @spec update_identity(Scope.t(), Identity.t(), map()) ::
          {:ok, Identity.t()}
          | {:error,
             :forbidden
             | :not_found
             | :mailbox_not_found
             | {:integration_unusable, problem()}
             | Ecto.Changeset.t()}
  def update_identity(%Scope{} = scope, %Identity{uuid: uuid}, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, identity} <- fetch(uuid),
         :ok <- authorize_manage(scope, identity),
         {:ok, changes} <- structural_changes(identity, attrs) do
      identity
      |> Ecto.Changeset.change(changes)
      |> Identity.changeset(attrs)
      |> repo().update()
    end
  end

  defp structural_changes(identity, attrs) do
    with {:ok, changes} <- integration_change(identity, attrs) do
      mailbox_change(identity, attrs, changes)
    end
  end

  defp integration_change(identity, %{"integration_uuid" => uuid}) when uuid not in [nil, ""] do
    case usable_integration(uuid, expected_owner(identity)) do
      {:ok, uuid} -> {:ok, [integration_uuid: uuid, status: "active"]}
      error -> error
    end
  end

  defp integration_change(_identity, _attrs), do: {:ok, []}

  defp mailbox_change(%Identity{kind: "shared"}, %{"mailbox_uuid" => value}, changes) do
    with {:ok, mailbox_uuid} <- shared_mailbox_uuid(value) do
      {:ok, Keyword.put(changes, :mailbox_uuid, mailbox_uuid)}
    end
  end

  defp mailbox_change(_identity, _attrs, changes), do: {:ok, changes}

  @doc "Deletes an identity. Same permissions as changing it."
  @spec delete_identity(Scope.t(), Identity.t()) :: :ok | {:error, :forbidden | :not_found}
  def delete_identity(%Scope{} = scope, %Identity{uuid: uuid}) do
    with {:ok, identity} <- fetch(uuid),
         :ok <- authorize_manage(scope, identity),
         {:ok, _} <- repo().delete(identity) do
      :ok
    end
  end

  defp authorize_manage(scope, %Identity{kind: "shared"}), do: authorize_manage_shared(scope)

  defp authorize_manage(scope, %Identity{kind: "personal", owner_uuid: owner}) do
    with {:ok, user} <- scope_user(scope),
         :ok <- authorize_inbox(scope) do
      if owner == user.uuid, do: :ok, else: {:error, :forbidden}
    end
  end

  defp usable_integration(uuid, owner) do
    case check_integration(uuid, owner) do
      {:ok, _from} -> {:ok, uuid |> Ecto.UUID.cast() |> elem(1)}
      {:error, problem} -> {:error, {:integration_unusable, problem}}
    end
  end

  defp shared_mailbox_uuid(blank) when blank in [nil, ""], do: {:ok, nil}

  defp shared_mailbox_uuid(uuid) do
    case Mailboxes.fetch_mailbox(uuid) do
      {:ok, %Mailbox{kind: "shared"} = mailbox} -> {:ok, mailbox.uuid}
      _ -> {:error, :mailbox_not_found}
    end
  end

  # ── Reply-To ────────────────────────────────────────────────────────────────

  @doc """
  The Reply-To addresses the scope's user may put on a message sent from
  `mailbox`, as `[%{address, label, default}]`: their own email, then the
  `address` of each active shared mailbox they own or hold `"write"` or
  `"admin"` on. At most one is the default: from a shared mailbox its own
  address (none when it has no address — a reply then goes to the mailbox);
  from the personal mailbox the user's saved choice
  (`set_default_reply_to/2`) while it is still allowed, else their email.

  Empty without `"inbox"` or without `"write"` on `mailbox`.
  """
  @spec reply_to_options(Scope.t(), Mailbox.t()) :: [
          %{address: String.t(), label: String.t(), default: boolean()}
        ]
  def reply_to_options(%Scope{} = scope, %Mailbox{} = mailbox) do
    with {:ok, user} <- scope_user(scope),
         {:ok, fresh} <- Mailboxes.authorize_scope(scope, mailbox, "write") do
      options = allowed_reply_tos(user)
      default = default_for(fresh, user, options)
      Enum.map(options, &Map.put(&1, :default, &1.address == default))
    else
      _ -> []
    end
  end

  def reply_to_options(_, _), do: []

  @doc "The default among `reply_to_options/2`, or `nil` when there are none."
  @spec default_reply_to([map()]) :: String.t() | nil
  def default_reply_to(options) do
    case Enum.find(options, & &1.default) do
      %{address: address} -> address
      nil -> nil
    end
  end

  @doc """
  Whether `address` is one the scope's user may use as Reply-To from
  `mailbox` — the check a send runs. Case-insensitive; returns the stored
  spelling.
  """
  @spec allowed_reply_to(Scope.t(), Mailbox.t(), term()) ::
          {:ok, String.t()} | {:error, :reply_to_not_allowed}
  def allowed_reply_to(scope, mailbox, address) when is_binary(address) do
    wanted = address |> String.trim() |> String.downcase()

    case Enum.find(reply_to_options(scope, mailbox), &(String.downcase(&1.address) == wanted)) do
      %{address: allowed} -> {:ok, allowed}
      nil -> {:error, :reply_to_not_allowed}
    end
  end

  def allowed_reply_to(_scope, _mailbox, _address), do: {:error, :reply_to_not_allowed}

  @doc """
  Saves the Reply-To the scope's user's personal mailbox defaults to. It must
  be one of their `reply_to_options/2` (`{:error, :reply_to_not_allowed}`).
  Stored in the personal mailbox's `settings`.
  """
  @spec set_default_reply_to(Scope.t(), String.t()) ::
          {:ok, Mailbox.t()} | {:error, term()}
  def set_default_reply_to(%Scope{} = scope, address) do
    with {:ok, user} <- scope_user(scope),
         {:ok, mailbox} <- Mailboxes.ensure_user_mailbox(user),
         {:ok, allowed} <- allowed_reply_to(scope, mailbox, address) do
      settings = Map.put(mailbox.settings || %{}, @reply_to_setting, allowed)
      Mailboxes.update_mailbox(scope, mailbox, %{"settings" => settings})
    end
  end

  defp allowed_reply_tos(user) do
    writable = writable_mailbox_uuids(user.uuid)

    shared =
      from(m in Mailbox,
        where: m.kind == "shared" and m.uuid in ^writable and not is_nil(m.address),
        order_by: [asc: m.name]
      )
      |> repo().all()
      |> Enum.map(&%{address: &1.address, label: &1.name})

    own = if blank?(user.email), do: [], else: [%{address: user.email, label: user.email}]

    Enum.uniq_by(own ++ shared, &String.downcase(&1.address))
  end

  # A shared mailbox's default is its own address; without one there is none,
  # so a reply still goes to the mailbox rather than to whoever wrote.
  defp default_for(%Mailbox{kind: "shared", address: address}, _user, options) do
    if is_binary(address) and Enum.any?(options, &(&1.address == address)), do: address
  end

  defp default_for(%Mailbox{kind: "user"} = mailbox, user, options) do
    saved = (mailbox.settings || %{})[@reply_to_setting]

    cond do
      is_binary(saved) and Enum.any?(options, &(&1.address == saved)) -> saved
      Enum.any?(options, &(&1.address == user.email)) -> user.email
      true -> nil
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The stored user row, not the scope's copy: names and email are read from it.
  defp scope_user(scope) do
    with {:ok, uuid} <- Mailboxes.scope_user_uuid(scope),
         %User{} = user <- repo().get(User, uuid) do
      {:ok, user}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_inbox(scope) do
    if Scope.can?(scope, "inbox"), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_manage_shared(scope) do
    if Scope.can?(scope, @manage_shared), do: :ok, else: {:error, :forbidden}
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
