defmodule PhoenixKitInbox.Signatures do
  @moduledoc """
  A mailbox's signatures (`PhoenixKitInbox.Schemas.Signature`) — Markdown,
  inserted at the end of a message being written, after a `"-- "` line,
  where the writer can still see and edit it.

  ## Who writes them

  Every write takes the caller's `%Scope{}` and checks it here, against the
  stored mailbox (`Mailboxes.authorize_scope/3`):

    * a personal mailbox's — its owner (`"admin"` on a personal mailbox is
      ownership; they take no grants)
    * a shared mailbox's — `"admin"` on the mailbox **and**
      `inbox.manage_shared`

  Reading (`list/1`, `default/1`) takes a mailbox uuid the caller has
  already authorized, like `Mailboxes.list_grants/1`.

  ## In the compose form

  `block/1` is the text a signature adds; `swap_block/3` changes the
  signature of a body being written — it replaces the block it inserted
  while the writer left it as it was, and touches nothing once they edited it.
  """

  import Ecto.Query

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.Signature

  @manage_shared "inbox.manage_shared"
  @delimiter "\n\n-- \n"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc "A mailbox's signatures, the default first, then by label."
  @spec list(binary()) :: [Signature.t()]
  def list(mailbox_uuid) when is_binary(mailbox_uuid) do
    case Ecto.UUID.cast(mailbox_uuid) do
      {:ok, uuid} ->
        from(s in Signature,
          where: s.mailbox_uuid == ^uuid,
          order_by: [desc: s.is_default, asc: s.label, asc: s.uuid]
        )
        |> repo().all()

      :error ->
        []
    end
  end

  def list(_), do: []

  @doc "A mailbox's default signature, or `nil`."
  @spec default(binary()) :: Signature.t() | nil
  def default(mailbox_uuid) do
    mailbox_uuid |> list() |> Enum.find(& &1.is_default)
  end

  @doc """
  Whether the scope may write `mailbox`'s signatures — what the forms use to
  show or hide the editor. The write functions check it themselves.
  """
  @spec can_manage?(Scope.t(), Mailbox.t()) :: boolean()
  def can_manage?(scope, mailbox), do: match?({:ok, _}, authorize(scope, mailbox))

  # ── writes ──────────────────────────────────────────────────────────────────

  @doc """
  Adds a signature to `mailbox`. `attrs`: `"label"`, `"body"` (Markdown),
  `"is_default"` — the new default clears the mailbox's previous one.
  """
  @spec create_signature(Scope.t(), Mailbox.t(), map()) ::
          {:ok, Signature.t()}
          | {:error,
             :forbidden | :mailbox_access_denied | :mailbox_not_found | Ecto.Changeset.t()}
  def create_signature(%Scope{} = scope, %Mailbox{} = mailbox, attrs) when is_map(attrs) do
    with {:ok, fresh} <- authorize(scope, mailbox) do
      %Signature{mailbox_uuid: fresh.uuid}
      |> Signature.changeset(normalize_attrs(attrs))
      |> save(:insert)
    end
  end

  @doc "Changes a signature's label, body or default flag. Same permissions."
  @spec update_signature(Scope.t(), Signature.t(), map()) ::
          {:ok, Signature.t()}
          | {:error,
             :forbidden
             | :mailbox_access_denied
             | :mailbox_not_found
             | :not_found
             | Ecto.Changeset.t()}
  def update_signature(%Scope{} = scope, %Signature{uuid: uuid}, attrs) when is_map(attrs) do
    with {:ok, stored} <- fetch(uuid),
         {:ok, _mailbox} <- authorize(scope, %Mailbox{uuid: stored.mailbox_uuid}) do
      stored
      |> Signature.changeset(normalize_attrs(attrs))
      |> save(:update)
    end
  end

  @doc "Deletes a signature. Same permissions."
  @spec delete_signature(Scope.t(), Signature.t()) ::
          :ok | {:error, :forbidden | :mailbox_access_denied | :mailbox_not_found | :not_found}
  def delete_signature(%Scope{} = scope, %Signature{uuid: uuid}) do
    with {:ok, stored} <- fetch(uuid),
         {:ok, _mailbox} <- authorize(scope, %Mailbox{uuid: stored.mailbox_uuid}),
         {:ok, _} <- repo().delete(stored) do
      :ok
    end
  end

  # The stored row decides the mailbox, never the struct handed in.
  defp fetch(uuid) do
    case repo().get(Signature, uuid) do
      nil -> {:error, :not_found}
      signature -> {:ok, signature}
    end
  end

  defp authorize(scope, mailbox) do
    with {:ok, fresh} <- Mailboxes.authorize_scope(scope, mailbox, "admin"),
         :ok <- authorize_kind(scope, fresh) do
      {:ok, fresh}
    end
  end

  defp authorize_kind(scope, %Mailbox{kind: "shared"}) do
    if Scope.can?(scope, @manage_shared), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_kind(_scope, _mailbox), do: :ok

  # A new default clears the mailbox's others in the same transaction; the
  # partial unique index backs it.
  defp save(changeset, action) do
    repo().transaction(fn ->
      if Ecto.Changeset.get_change(changeset, :is_default) == true do
        mailbox_uuid = Ecto.Changeset.get_field(changeset, :mailbox_uuid)

        from(s in Signature, where: s.mailbox_uuid == ^mailbox_uuid and s.is_default)
        |> repo().update_all(set: [is_default: false])
      end

      case apply(repo(), action, [changeset]) do
        {:ok, signature} -> signature
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  # ── the compose form ────────────────────────────────────────────────────────

  @doc """
  The text `signature` adds at the end of a message: a `"-- "` line and its
  body. `""` for no signature or an empty one.
  """
  @spec block(Signature.t() | nil) :: String.t()
  def block(%Signature{body: body}) when is_binary(body) and body != "", do: @delimiter <> body
  def block(_), do: ""

  @doc """
  Puts `signature` at the end of `body` in place of `inserted`, the block a
  previous call put there (`""` when none).

  `{:ok, new_body}` when `body` still ends with `inserted` as it was put
  there; `:edited` when the writer changed it — their text is never
  rewritten.
  """
  @spec swap_block(String.t(), String.t(), Signature.t() | nil) :: {:ok, String.t()} | :edited
  def swap_block(body, "", signature), do: {:ok, (body || "") <> block(signature)}

  def swap_block(body, inserted, signature) when is_binary(body) do
    if String.ends_with?(body, inserted) do
      kept = binary_part(body, 0, byte_size(body) - byte_size(inserted))
      {:ok, kept <> block(signature)}
    else
      :edited
    end
  end

  def swap_block(_body, _inserted, _signature), do: :edited

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
