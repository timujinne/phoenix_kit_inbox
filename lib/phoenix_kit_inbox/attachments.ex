defmodule PhoenixKitInbox.Attachments do
  @moduledoc """
  Files attached to messages.

  ## Where the files live

  Every attachment is a file in the module's own **system library** in Storage
  (slug `"phoenix-kit-inbox"`, made on first use by `ensure_library/0`). The
  library is private: its files have no permanent URL and are read through
  `PhoenixKit.Modules.Storage.Libraries.can?/3` — their uploader, an
  Owner/Admin — and the module serves them to the people on a message itself,
  through `PhoenixKitInbox.Web.AttachmentController`.

  ### Shown in Media, read-only

  Where the core has managed libraries, the library is **listed in Media**
  (named `"Mail attachments"`, or `config :phoenix_kit_inbox, library_name:`)
  and **managed**: nobody changes, deletes, moves or renames its files from
  Media, Owner included — the core refuses it, the buttons are not the guard.
  The module's own writes pass `managed: :owner` (`owner_opts/0`).

      config :phoenix_kit_inbox, media_listing: :uploaders   # the default

  `media_listing` is who finds the library in Media's switcher:
  `:none` — no one (it stays hidden); `:admins` — Owner/Admin, every file;
  `:uploaders` — Owner/Admin every file, a holder of the `media` permission
  the files they uploaded themselves; `:own_only` — everyone only their own.
  A user's "own" files are the snapshots they created (`files.user_uuid`),
  the same rule under which the module does not ask the host's
  `attachment_policy` of a snapshot's creator.

  **The listing does not ask `attachment_policy`.** Owner/Admin see *every*
  attachment of every message under `:admins` and `:uploaders`, past the
  policy — a host whose policy keeps files from its administrators should use
  `:own_only` or `:none`. Recipients are not uploaders and do not see the
  files they were sent in Media; they read them through the module.

  The library is brought up to date on the first use of a node (a hidden-only
  library an earlier version made, a changed config, the old default name —
  only that name is ever renamed); a write the core refuses is not repeated,
  one that failed for a passing reason is tried again after
  `:library_retry_ms` (300 000 by default). A core without managed libraries
  keeps the library hidden, as before, under the earlier name
  "PhoenixKit Inbox" (the new name once the core can show it).

  ### Folders

  In Media the files lie in folders, `PhoenixKitInbox.Attachments.Folders`:
  `<mailbox> / <YYYY-MM> / <date time — subject>` for a sent message,
  `<mailbox> / Drafts` for a draft's new snapshots, a `FolderLink` in the
  folder of every later message that names a file filed elsewhere. The host's
  `config :phoenix_kit_inbox, attachment_folder: {Mod, :fun}` (`(message,
  sending_mailbox)`, a list of folder names or `nil`) replaces the
  `<mailbox>/<YYYY-MM>` levels. Filing runs after the commit, best effort;
  what it misses stays in the root or in `Drafts` until
  `mix phoenix_kit_inbox.relink_attachments`
  (`PhoenixKitInbox.Attachments.Maintenance`) files it.

  A message stores references (`PhoenixKitInbox.Schemas.Attachment` rows), not
  bytes, so an internal message has no size limit beyond the per-file
  `inbox_max_upload_bytes` setting (default 200 MB) and 50 files.

  ## How a file gets into a message

  Everything is a **snapshot** in the Inbox library, so what was sent does not
  change when the file it came from is later edited, replaced or deleted.
  Six ways in:

    1. an upload in compose stays in the LiveView's temporary upload until the
       draft is saved or the message sent, and is then handed over as the
       sender's bytes — way 5, `attachments_data:` — so nothing reaches
       Storage before that;
    2. a file of the Inbox library the sender stored (a saved draft's
       snapshot, their upload) named in the form's `"attachments"` is
       attached again as it is, without a copy;
    3. any other Storage file named there is copied, if the sender may read
       it (`Libraries.can?(scope, file, :read)`) and it is not another
       module's hidden file;
    4. a file the host checked itself is copied when its uuid comes in the
       server-side `attachments_authorized:` option — never from the form;
    5. bytes the host made (`attachments_data:`) are stored as they are;
    6. a file already attached to a sent message the sender sent, or still
       holds a copy of (a non-deleted delivery in a mailbox they can read),
       is forwarded as the same snapshot, flags and all.

  Folder names carry the message's subject and the mailbox's name; under
  `:admins` and `:uploaders` an Owner/Admin sees them in Media, past Inbox's
  own access rules. The search for a donor by checksum (ways 1 and 5) reads
  Media without an index on `file_checksum`, so its cost grows with Media.

  A snapshot is a record of its own in the Inbox library — its uuid, folder,
  name and owner are its own — but the stored objects behind it may be shared
  with the file it came from, so it is not always a second copy of the bytes.
  Where the core has `Storage.link_copy/3`:

    * ways 3 and 4 first ask for a linked copy of the file, which names the
      file's stored objects (checked against the checksum and size the sender
      saw);
    * ways 1 and 5 look for a Storage file with exactly these bytes (same
      checksum and size; active, not in the trash, not system-managed, not
      being edited, with a path) — Media first (the sender's own files before
      anyone else's, one attempt unless the donor changed meanwhile), then a
      snapshot that already names keys outside the module's own prefix, then
      any snapshot (up to three attempts a group; `:incompatible` ends a
      group) — and link to it. The sender holds these bytes already, so a
      link opens no bytes they do not hold (it can show them, through their
      own snapshot in Media, that the same bytes are held elsewhere);
    * ways 2 and 6 are unchanged.

  Any refusal (`:incompatible`, `:donor_unavailable`, `:donor_changed`), an
  answer that is not a new file of the Inbox library, a raise, throw or exit
  of the core, no donor, or a core without the function means the full copy
  described above.
  Deleting the donor or the snapshot takes only the objects no other record
  names, so a snapshot still reads after its original is edited, trashed or
  deleted. `read_file/1`, `list_for_message/1` and `safe_content_type/1` need
  no scope and see no difference.

  A file in the trash or a system-managed one is refused in ways 3 and 4
  (`{:error, {:attachment_unavailable, uuid}}`); anything else that does not
  qualify is `{:error, {:attachment_forbidden, uuid}}`.

  ## Core requirement

  Needs a PhoenixKit core with hidden system libraries
  (`Libraries.create_system_library/2` `hidden: true`,
  `get_hidden_library_by_slug/1`) and `Storage.store_file_in_buckets/7`
  `dedup: false` — 2.64.0, which `mix.exs` requires. On an older core every
  attachment is refused with `{:error, :storage_unsupported}` (and a log
  line); messages without attachments are unaffected. Optional, each looked
  up at run time (a literal call would not compile without warnings on a core
  that lacks it), and each doing without:

    * `Storage.link_copy/3` — snapshots share the donor's stored objects;
      without it they are full copies;
    * managed libraries (`Libraries.update_system_library_listing/2`,
      `media_listing/1`, `managed?/1`, the `managed: :owner` option) — the
      library is listed in Media, read-only, and filed in folders; without
      them it stays hidden and unfiled;
    * `Storage.relink_file/3` and `Storage.delete_unreferenced_keys/1` — only
      the maintenance task (`PhoenixKitInbox.Attachments.Maintenance`) needs
      them, and says so when they are missing.

  Snapshots are stored *before* the message transaction (Storage takes a
  directory lock for each, which must not be held across the send) and are
  deleted again if the transaction rolls back, raises or exits. A process
  killed between storing the snapshots and the commit leaves them in the
  library with no row naming them, and Storage's orphan cleanup skips hidden
  libraries — a sweep of unnamed Inbox-library files would reclaim them (not
  part of this module yet). Rolling back to before V03 drops the attachment
  rows and leaves every snapshot in the library. Rolling the module back to a
  version before the library was managed leaves its old `release/1`, which
  deletes without `managed: :owner` and so cannot remove the snapshots of a
  discarded draft: they stay in the library. A core that answers `link_copy/3`
  with a file outside the Inbox library leaves that record behind (the module
  stores the bytes itself and does not delete another library's file).
  Snapshots of a sent message are never deleted — sent messages are
  permanent; a discarded draft takes its snapshots with it unless another row
  still names them.

  ## Flags and the host's policy

  `flags` on a row is a map only server code sets (`attachment_flags:`,
  `attachments_data:`); a forward copies it. A host that must keep some
  files from some recipients sets

      config :phoenix_kit_inbox, attachment_policy: {MyApp.Inbox, :check_attachments}

  The function is called on every send and forward that carries attachments
  with the sender's scope, every user who will be able to read the files —
  the owners of the personal mailboxes addressed in To/Cc/Bcc, the owner and
  grantees of each shared mailbox addressed, and of the sending mailbox when
  it is a shared one — and the attachment rows with their flags. The
  sender is among the users whenever a file is a snapshot someone else
  created (a forward, a colleague's draft), and left out only when every
  file is their own upload or copy. A draft save asks the same way about
  its mailbox's readers. At download it is asked again for the viewer
  alone, unless the viewer created the snapshot, so a reader granted a
  mailbox later is covered and a forward or a draft cannot launder a file;
  a refusal there is a 404. One policy call per download. The reading pane
  and compose's chips ask it the same way, per row (`list_for_viewer/2`),
  and show a refused row without its name or size.
  It is called before any snapshot is stored, so a row about to be copied
  has no `file_uuid` yet. `:ok` lets the send go ahead; `{:error, reason}`
  refuses it with `{:error, {:attachment_refused, reason}}`; a raise or any
  other answer refuses it too.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Mailbox
  alias PhoenixKitInbox.Schemas.MailboxGrant
  alias PhoenixKitInbox.Schemas.Message

  @library_slug "phoenix-kit-inbox"
  # System libraries share one namespace of names, so a site's own library can
  # hold the name this one wants. The module's earlier default name is the only
  # one a rename may replace; the prefixed one is what a taken name falls back to.
  @default_library_name "Mail attachments"
  @legacy_library_name "PhoenixKit Inbox"
  @prefixed_library_name "PhoenixKit Inbox: "
  @listings [:none, :admins, :uploaders, :own_only]
  @default_listing :uploaders
  @max_files 50
  @max_upload_setting "inbox_max_upload_bytes"
  @default_max_upload_bytes 200_000_000
  @max_filename 255

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── the library ─────────────────────────────────────────────────────────────

  @doc "The slug of the module's hidden Storage library."
  @spec library_slug() :: String.t()
  def library_slug, do: @library_slug

  @doc """
  The module's hidden library, made on first call. Idempotent and safe to
  race: a caller that loses the insert finds the winner's library.

  Where the core has managed hidden libraries the library is shown in Media
  (`config :phoenix_kit_inbox, media_listing:`, `:uploaders` by default) and
  managed — nobody changes or deletes its files from Media — and a library an
  earlier version made is brought up to date. It is named
  `config :phoenix_kit_inbox, library_name:` (`"Mail attachments"`); only the
  old default name is ever renamed, and a name a site library holds is
  replaced by a prefixed one (or kept) with a warning. Without managed
  libraries it stays hidden, as before.
  """
  @spec ensure_library() :: {:ok, Library.t()} | {:error, term()}
  def ensure_library do
    cond do
      not hidden_libraries?() ->
        Logger.error(
          "[Inbox] attachments need a PhoenixKit core with hidden system libraries " <>
            "(the first release after 2.63.0); refusing the attachment"
        )

        {:error, :storage_unsupported}

      library = library() ->
        {:ok, bring_up_to_date(library)}

      true ->
        create_library()
    end
  end

  defp library do
    if hidden_libraries?(), do: hidden_library()
  end

  @doc false
  # The library if it exists; unlike `ensure_library/0` it makes and changes
  # nothing. For read-only callers.
  @spec existing_library() :: Library.t() | nil
  def existing_library, do: library()

  # Optional core APIs must also remain optional at compile time.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp hidden_library, do: apply(libraries(), :get_hidden_library_by_slug, [@library_slug])

  # The hidden-library API arrived with `dedup: false` in the same core
  # release; an older core has neither.
  defp hidden_libraries? do
    libraries = libraries()

    Code.ensure_loaded?(libraries) and
      function_exported?(libraries, :get_hidden_library_by_slug, 1)
  end

  # Whether the core can show a hidden library in Media and manage it
  # (`create_system_library/2` `media_listing:`/`managed:`,
  # `update_system_library_listing/2`, `managed?/1`, and the
  # `managed: :owner` option of the file and folder functions).
  @doc false
  @spec managed_libraries?() :: boolean()
  def managed_libraries? do
    libraries = libraries()

    Code.ensure_loaded?(libraries) and
      function_exported?(libraries, :update_system_library_listing, 2) and
      function_exported?(libraries, :media_listing, 1) and
      function_exported?(libraries, :managed?, 1)
  end

  # The option the module's own changes to its managed library take.
  @doc false
  @spec owner_opts() :: keyword()
  def owner_opts, do: if(managed_libraries?(), do: [managed: :owner], else: [])

  # Test seams, unset in production: `:storage_libraries` stands in for
  # core's hidden-library API (`Storage.Libraries`; a module without it is an
  # older core), `:storage_module` for `Storage.store_file_in_buckets/7` and
  # `Storage.link_copy/3`.
  defp libraries, do: Application.get_env(:phoenix_kit_inbox, :storage_libraries, Libraries)
  defp storage, do: Application.get_env(:phoenix_kit_inbox, :storage_module, Storage)

  defp create_library do
    name = library_name()

    case insert_library(name) do
      {:ok, library} ->
        log_unmanaged_once()
        {:ok, library}

      error ->
        found_or(error, fn -> create_failed(error, name) end)
    end
  end

  defp create_failed(error, name) do
    if name_taken?(error),
      do: create_under_prefixed_name(name),
      else: library_error(error)
  end

  # A caller that lost the insert finds the winner's library.
  defp found_or(error, otherwise) do
    case library() do
      %Library{} = library -> {:ok, library}
      nil -> if match?({:error, _}, error), do: otherwise.(), else: library_error(error)
    end
  end

  defp create_under_prefixed_name(name) do
    prefixed = @prefixed_library_name <> name

    Logger.warning(
      "[Inbox] the library name #{inspect(name)} is taken by another library; " <>
        "making the attachments library as #{inspect(prefixed)}"
    )

    case insert_library(prefixed) do
      {:ok, library} -> {:ok, library}
      error -> found_or(error, fn -> library_error(error) end)
    end
  end

  defp library_error({:error, reason}), do: {:error, {:library_unavailable, reason}}
  defp library_error(other), do: {:error, {:library_unavailable, other}}

  defp insert_library(name) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(libraries(), :create_system_library, [
      %{"name" => name, "slug" => @library_slug},
      [hidden: true] ++ listing_opts()
    ])
  end

  defp listing_opts do
    if managed_libraries?(),
      do: [media_listing: media_listing(), managed: true],
      else: []
  end

  defp name_taken?({:error, %Ecto.Changeset{errors: errors}}), do: Keyword.has_key?(errors, :name)
  defp name_taken?(_), do: false

  # An earlier version made the library hidden only, under the old name. Only
  # what differs is written; a library that is right is not touched.
  #
  # Once a run of the node for this library and this config: ensure_library/0
  # is asked on every send, and a refused write or a taken name must not be
  # tried (and warned about) again each time.
  defp bring_up_to_date(library) do
    cond do
      not managed_libraries?() ->
        log_unmanaged_once()
        library

      # Like the filing: a write here would be rolled back with the caller's
      # transaction while the node remembered it as done.
      repo().in_transaction?() ->
        library

      synced?(library) ->
        library

      true ->
        {library, outcome} = library |> update_listing() |> update_name()
        :persistent_term.put(sync_key(library), remembered(outcome))
        library
    end
  end

  # Done, or refused for good (a taken name): never again on this node. Any
  # other failure (a timeout, a lost connection) is tried again after a while.
  defp remembered(:transient), do: {:retry_after, now() + retry_after()}
  defp remembered(_), do: :done

  defp synced?(library) do
    case :persistent_term.get(sync_key(library), nil) do
      nil -> false
      :done -> true
      {:retry_after, at} -> now() < at
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp retry_after, do: Application.get_env(:phoenix_kit_inbox, :library_retry_ms, 300_000)

  defp worse(:transient, _), do: :transient
  defp worse(_, :transient), do: :transient
  defp worse(:refused, _), do: :refused
  defp worse(_, other), do: other

  defp sync_key(library) do
    {__MODULE__, :synced, library.uuid, Application.get_env(:phoenix_kit_inbox, :media_listing),
     Application.get_env(:phoenix_kit_inbox, :library_name)}
  end

  defp update_listing(library) do
    listing = media_listing()

    if current_listing(library) == {listing, true} do
      {library, :ok}
    else
      write_listing(library, listing)
    end
  end

  defp current_listing(library), do: {listing_of(library), managed?(library)}

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp listing_of(library), do: apply(libraries(), :media_listing, [library])

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp managed?(library), do: apply(libraries(), :managed?, [library])

  defp write_listing(library, listing) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(libraries(), :update_system_library_listing, [
           library,
           [media_listing: listing, managed: true]
         ]) do
      {:ok, updated} ->
        {updated, :ok}

      {:error, reason} ->
        Logger.warning("[Inbox] could not update the attachments library: #{inspect(reason)}")
        {library, if(reason in [:not_hidden, :invalid_value], do: :refused, else: :transient)}
    end
  end

  # The rename is for a library still under the module's old default name.
  defp update_name({%Library{name: @legacy_library_name} = library, outcome}) do
    case library_name() do
      @legacy_library_name ->
        {library, outcome}

      name ->
        {library, renamed} = rename(library, name)
        {library, worse(outcome, renamed)}
    end
  end

  defp update_name(done), do: done

  defp rename(library, name) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(libraries(), :rename_library, [library, name]) do
      {:ok, renamed} ->
        {renamed, :ok}

      error ->
        taken? = name_taken?(error)
        reason = if taken?, do: "is taken by another library", else: inspect(error, limit: 20)

        Logger.warning(
          "[Inbox] could not rename the attachments library to #{inspect(name)} (#{reason}); " <>
            "it keeps #{inspect(library.name)}"
        )

        {library, if(taken?, do: :refused, else: :transient)}
    end
  end

  defp library_name do
    case Application.get_env(:phoenix_kit_inbox, :library_name) do
      name when is_binary(name) and name != "" -> name
      _ -> default_library_name()
    end
  end

  # A core that cannot show the library keeps it hidden, and a hidden library
  # takes a name from the site's namespace too: it gets the earlier name, and
  # the new one once the core can show it (`update_name/1`).
  defp default_library_name do
    if managed_libraries?(), do: @default_library_name, else: @legacy_library_name
  end

  defp media_listing do
    case Application.get_env(:phoenix_kit_inbox, :media_listing, @default_listing) do
      listing when listing in @listings ->
        listing

      other ->
        Logger.warning(
          "[Inbox] media_listing #{inspect(other)} is not one of #{inspect(@listings)}; " <>
            "using #{inspect(@default_listing)}"
        )

        @default_listing
    end
  end

  # Once a run of the node is enough to say the library stays hidden.
  defp log_unmanaged_once do
    unless managed_libraries?() or :persistent_term.get({__MODULE__, :unmanaged_logged}, false) do
      :persistent_term.put({__MODULE__, :unmanaged_logged}, true)

      Logger.info(
        "[Inbox] this PhoenixKit core cannot show the attachments library in Media; " <>
          "it stays hidden"
      )
    end

    :ok
  end

  defp library_uuid do
    case library() do
      nil -> nil
      library -> to_string(library.uuid)
    end
  end

  defp in_library?(%{library_uuid: uuid}, library_uuid) when is_binary(library_uuid),
    do: to_string(uuid) == library_uuid

  defp in_library?(_file, _library_uuid), do: false

  # ── limits ──────────────────────────────────────────────────────────────────

  @doc "Most files one message may carry."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc """
  Largest file accepted, in bytes — the `inbox_max_upload_bytes` setting,
  #{@default_max_upload_bytes} by default.
  """
  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes do
    case PhoenixKit.Settings.get_integer_setting(@max_upload_setting, @default_max_upload_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> @default_max_upload_bytes
    end
  rescue
    _ -> @default_max_upload_bytes
  catch
    :exit, _ -> @default_max_upload_bytes
  end

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc "A message's attachments, in order."
  @spec list_for_message(binary()) :: [Attachment.t()]
  def list_for_message(message_uuid) when is_binary(message_uuid) do
    from(a in Attachment,
      where: a.message_uuid == ^message_uuid,
      order_by: [asc: a.position, asc: a.inserted_at]
    )
    |> repo().all()
  end

  def list_for_message(_), do: []

  @doc """
  A message's attachments as the scope's user may see them, in order:
  `{:ok, row}` for one they may download, `{:withheld, row}` for one the
  host's `attachment_policy` refuses them — the same decision as at download
  (`fetch_for_download/2`), so the row comes without its filename, type,
  size and flags. For the reading pane and compose's chips; the caller has
  already checked that the user may read the message.

  Without a policy configured this is `list_for_message/1`'s one query.
  """
  @spec list_for_viewer(Scope.t() | nil, binary()) ::
          [{:ok, Attachment.t()} | {:withheld, Attachment.t()}]
  def list_for_viewer(scope, message_uuid) do
    case {list_for_message(message_uuid), policy()} do
      {rows, nil} -> Enum.map(rows, &{:ok, &1})
      {[], _policy} -> []
      {rows, _policy} -> judge_rows(scope, rows)
    end
  end

  @doc """
  `list_for_viewer/2` for many messages at once, for a reading pane that
  shows a whole conversation: `%{message_uuid => [{status, row}]}`, every
  asked uuid present (a message without files maps to `[]`). The same rules
  and statuses as `list_for_viewer/2` — `{:ok, row}` or `{:withheld, row}`
  by the host's `attachment_policy`, the snapshot's creator never asked —
  with one attachments query for the whole batch, then the viewer and the
  files they created read once, not per message.

  The caller has already checked that the user may read the messages.
  """
  @spec list_for_viewer_many(Scope.t() | nil, [binary()]) ::
          %{binary() => [{:ok, Attachment.t()} | {:withheld, Attachment.t()}]}
  def list_for_viewer_many(_scope, []), do: %{}

  def list_for_viewer_many(scope, message_uuids) when is_list(message_uuids) do
    rows =
      from(a in Attachment,
        where: a.message_uuid in ^message_uuids,
        order_by: [asc: a.position, asc: a.inserted_at]
      )
      |> repo().all()

    judged =
      case {rows, policy()} do
        {[], _policy} -> []
        {rows, nil} -> Enum.map(rows, &{:ok, &1})
        {rows, _policy} -> judge_rows(scope, rows)
      end

    by_message = Enum.group_by(judged, fn {_status, row} -> to_string(row.message_uuid) end)
    Map.new(message_uuids, &{&1, Map.get(by_message, to_string(&1), [])})
  end

  def list_for_viewer_many(_scope, _other), do: %{}

  defp judge_rows(scope, rows) do
    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         %User{} = viewer <- repo().get(User, user_uuid) do
      created = created_by(Enum.map(rows, &to_string(&1.file_uuid)), user_uuid)
      Enum.map(rows, &judge_row(scope, viewer, created, &1))
    else
      _ -> Enum.map(rows, &{:withheld, withhold(&1)})
    end
  end

  # As download_policy/3 decides: the snapshot's creator is not asked.
  defp judge_row(scope, viewer, created, row) do
    if MapSet.member?(created, to_string(row.file_uuid)) or
         ask_policy(scope, [viewer], [row]) == :ok,
       do: {:ok, row},
       else: {:withheld, withhold(row)}
  end

  # What a withheld row may still show: that it is there, and where.
  defp withhold(%Attachment{} = row) do
    %Attachment{
      uuid: row.uuid,
      message_uuid: row.message_uuid,
      file_uuid: row.file_uuid,
      position: row.position,
      size_bytes: nil,
      flags: nil
    }
  end

  # The files among `file_uuids` the user created (their upload or copy).
  defp created_by(file_uuids, user_uuid) do
    from(f in Storage.File,
      where: f.uuid in ^file_uuids and f.user_uuid == ^user_uuid,
      select: f.uuid
    )
    |> repo().all()
    |> MapSet.new(&to_string/1)
  end

  @doc """
  The attachment `attachment_uuid` if `scope` may download it, else
  `{:error, :not_found}` — the same answer whether the row is missing or
  someone else's.

  Allowed when the module is on, the scope holds `"inbox"`, its user sent
  the message or holds a non-deleted copy of it (a delivery) in a mailbox
  they can read, and — for anyone but the sender — the host's
  `attachment_policy` accepts this row for this viewer — asked of anyone
  but the snapshot's creator, on every download.
  """
  @spec fetch_for_download(Scope.t() | nil, term()) ::
          {:ok, Attachment.t()} | {:error, :not_found}
  def fetch_for_download(scope, attachment_uuid) do
    with true <- PhoenixKitInbox.enabled?(),
         true <- Scope.can?(scope, "inbox"),
         {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         {:ok, uuid} <- Ecto.UUID.cast(attachment_uuid),
         %Attachment{} = attachment <- repo().get(Attachment, uuid),
         true <- participant?(attachment.message_uuid, user_uuid),
         :ok <- download_policy(scope, user_uuid, attachment) do
      {:ok, attachment}
    else
      _ -> {:error, :not_found}
    end
  end

  # The policy again, at download, for the viewer alone: a reader granted a
  # mailbox after the send was never among the users asked then. Only the
  # snapshot's creator — whose upload or copy it is — is not asked; being
  # the sender of the message is not enough, or a forward or a draft would
  # launder someone else's file.
  defp download_policy(scope, user_uuid, attachment) do
    case {created_by?(attachment.file_uuid, user_uuid), repo().get(User, user_uuid)} do
      {true, _} -> :ok
      {false, %User{} = viewer} -> ask_policy(scope, [viewer], [attachment])
      {false, nil} -> {:error, :not_found}
    end
  end

  defp created_by?(file_uuid, user_uuid) do
    case Storage.get_file(to_string(file_uuid)) do
      %Storage.File{user_uuid: creator} -> to_string(creator) == user_uuid
      nil -> false
    end
  end

  defp participant?(message_uuid, user_uuid) do
    from(m in Message, as: :message, where: m.uuid == ^message_uuid)
    |> where_participant(user_uuid)
    |> repo().exists?()
  end

  # The message (bound as `:message`) was sent by the user, or the user holds
  # an active copy of it in a mailbox they can open.
  defp where_participant(query, user_uuid) do
    readable = user_uuid |> Mailboxes.list_accessible_mailboxes() |> Enum.map(& &1.uuid)

    copies =
      from(d in Delivery,
        where: d.status == "active" and d.mailbox_uuid in ^readable,
        select: d.message_uuid
      )

    where(
      query,
      [message: m],
      m.sender_user_uuid == ^user_uuid or m.uuid in subquery(copies)
    )
  end

  @doc """
  Copies the bytes of `attachment` out of Storage into a temporary file and
  returns its path — the caller deletes it. `{:error, :not_found}` when the
  snapshot is gone or is not a file of the Inbox library.
  """
  @spec read_file(Attachment.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def read_file(%Attachment{file_uuid: file_uuid}) do
    with %Storage.File{system_managed: false} = file <- Storage.get_file(to_string(file_uuid)),
         true <- in_library?(file, library_uuid()),
         {:ok, path, _file} <- Storage.retrieve_file(file.uuid) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── compose ─────────────────────────────────────────────────────────────────

  @doc """
  Whether `scope` may attach the Storage file `file_uuid`, checked exactly
  as a send would check it, and what a compose chip shows for it:
  `{:ok, %{file_uuid: uuid_to_submit, filename: name, size_bytes: size}}`.
  For the media picker's choices: the uuids come back from the browser, so
  each is checked again here. Needs the `"inbox"` permission.
  """
  @spec describe(Scope.t(), term()) :: {:ok, map()} | {:error, term()}
  def describe(%Scope{} = scope, file_uuid) do
    with {:ok, user_uuid} <- Mailboxes.scope_user_uuid(scope),
         :ok <- authorize_inbox(scope),
         {:ok, [item]} <-
           plan(scope, user_uuid, nil, %{"attachments" => [%{"file_uuid" => file_uuid}]}, []) do
      {:ok, %{file_uuid: item.key, filename: item.filename, size_bytes: item.size_bytes}}
    end
  end

  def describe(_scope, _file_uuid), do: {:error, :forbidden}

  defp authorize_inbox(scope) do
    if Scope.can?(scope, "inbox"), do: :ok, else: {:error, :forbidden}
  end

  # ── admission (called by Messages) ──────────────────────────────────────────

  @doc false
  # Works out the attachments a send or draft save ends up with, checking
  # every path, without storing anything: a list of planned rows (`plan/5`).
  # `message` is the draft being saved or promoted, or nil.
  @spec plan(Scope.t(), binary(), Message.t() | nil, map(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def plan(scope, user_uuid, message, attrs, opts) do
    existing = if message, do: list_for_message(message.uuid), else: []
    flags = opts |> Keyword.get(:attachment_flags, %{}) |> normalize_flags_map()
    context = %{scope: scope, user_uuid: user_uuid, flags: flags, library: library_uuid()}

    with {:ok, form} <- form_items(attrs, existing, context),
         {:ok, authorized} <-
           authorized_items(Keyword.get(opts, :attachments_authorized, []), context),
         {:ok, data} <- data_items(Keyword.get(opts, :attachments_data, [])) do
      items = dedupe(form ++ authorized) ++ data

      with :ok <- check_count(items),
           :ok <- check_sizes(items) do
        {:ok, items}
      end
    end
  end

  # Without an "attachments" key a draft keeps what it has; with one, the
  # list is the new set.
  defp form_items(attrs, existing, context) do
    case Map.fetch(attrs, "attachments") do
      :error ->
        {:ok, Enum.map(existing, &keep_item/1)}

      {:ok, entries} ->
        with {:ok, uuids} <- form_uuids(entries) do
          collect(uuids, &form_item(&1, existing, context))
        end
    end
  end

  defp form_uuids(nil), do: {:ok, []}

  defp form_uuids(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case entry_uuid(entry) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, :invalid_attachments}}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, Enum.reverse(uuids)}
      error -> error
    end
  end

  defp form_uuids(entries) when is_map(entries), do: entries |> Map.values() |> form_uuids()
  defp form_uuids(_), do: {:error, :invalid_attachments}

  defp entry_uuid(%{"file_uuid" => uuid}) when is_binary(uuid), do: {:ok, uuid}
  defp entry_uuid(%{file_uuid: uuid}) when is_binary(uuid), do: {:ok, uuid}
  defp entry_uuid(_), do: :error

  defp form_item(raw, existing, context) do
    with {:ok, uuid} <- cast_file_uuid(raw) do
      case Enum.find(existing, &(to_string(&1.file_uuid) == uuid)) do
        %Attachment{} = row -> {:ok, keep_item(row)}
        nil -> storage_item(uuid, context)
      end
    end
  end

  defp storage_item(uuid, context) do
    with {:ok, file} <- fetch_file(uuid) do
      if in_library?(file, context.library),
        do: inbox_item(file, context),
        else: readable_item(file, context)
    end
  end

  # A file already in the Inbox library: one the sender may forward (way 6),
  # or their own snapshot (way 2). Nothing else, whoever's it is.
  defp inbox_item(file, context) do
    uuid = to_string(file.uuid)

    cond do
      row = forwardable_row(uuid, context.user_uuid) || own_row(uuid, context.user_uuid) ->
        {:ok, reuse_item(row)}

      to_string(file.user_uuid) == context.user_uuid ->
        {:ok, upload_item(file, Map.get(context.flags, uuid, %{}))}

      true ->
        {:error, {:attachment_forbidden, uuid}}
    end
  end

  # Way 3: someone's Storage file, if the sender may read it.
  defp readable_item(file, context) do
    uuid = to_string(file.uuid)

    cond do
      # Another module's private files are not Inbox's to pass on, whoever
      # may read them; a host that means it uses attachments_authorized.
      other_hidden_library?(file) -> {:error, {:attachment_forbidden, uuid}}
      not Libraries.can?(context.scope, file, :read) -> {:error, {:attachment_forbidden, uuid}}
      unavailable?(file) -> {:error, {:attachment_unavailable, uuid}}
      true -> {:ok, file_item(file, Map.get(context.flags, uuid, %{}))}
    end
  end

  defp other_hidden_library?(file) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    hidden_libraries?() and apply(libraries(), :hidden?, [to_string(file.library_uuid)])
  end

  # Way 4: the host vouched for these; only the state of the file is checked.
  defp authorized_items(uuids, context) when is_list(uuids),
    do: collect(uuids, &authorized_item(&1, context))

  defp authorized_items(_, _context), do: {:error, :invalid_attachments}

  defp authorized_item(raw, context) do
    with {:ok, uuid} <- cast_file_uuid(raw),
         {:ok, file} <- fetch_file(uuid) do
      if unavailable?(file),
        do: {:error, {:attachment_unavailable, uuid}},
        else: {:ok, file_item(file, Map.get(context.flags, uuid, %{}))}
    end
  end

  defp fetch_file(uuid) do
    case Storage.get_file(uuid) do
      nil -> {:error, {:attachment_forbidden, uuid}}
      file -> {:ok, file}
    end
  end

  # Way 5: bytes from the host — compose's uploads (way 1) among them.
  defp data_items(entries) when is_list(entries) do
    collect(entries, fn entry ->
      entry = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
      filename = clean_filename(entry["filename"])

      source =
        case entry do
          %{"binary" => binary} when is_binary(binary) -> {:binary, binary}
          %{"path" => path} when is_binary(path) -> {:path, path}
          _ -> nil
        end

      with {:ok, size} <- data_size(source) do
        {:ok,
         %{
           mode: :snapshot,
           source: source,
           file_uuid: nil,
           source_file_uuid: nil,
           filename: filename,
           content_type: entry["content_type"] || MIME.from_path(filename),
           size_bytes: size,
           flags: normalize_flags(entry["flags"]),
           key: nil
         }}
      end
    end)
  end

  defp data_items(_), do: {:error, :invalid_attachments}

  defp data_size({:binary, binary}), do: {:ok, byte_size(binary)}

  defp data_size({:path, path}) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, _} -> {:error, :invalid_attachments}
    end
  end

  defp data_size(nil), do: {:error, :invalid_attachments}

  defp keep_item(%Attachment{} = row) do
    %{
      mode: :keep,
      row: row,
      file_uuid: to_string(row.file_uuid),
      source_file_uuid: row.source_file_uuid,
      filename: row.filename,
      content_type: row.content_type,
      size_bytes: row.size_bytes,
      flags: row.flags || %{},
      key: to_string(row.file_uuid)
    }
  end

  defp reuse_item(%Attachment{} = row) do
    %{keep_item(row) | mode: :reuse} |> Map.delete(:row)
  end

  defp upload_item(file, flags) do
    %{
      mode: :reuse,
      file_uuid: to_string(file.uuid),
      source_file_uuid: nil,
      filename: file_filename(file),
      content_type: file.mime_type,
      size_bytes: file.size || 0,
      flags: flags,
      key: to_string(file.uuid)
    }
  end

  defp file_item(file, flags) do
    %{
      mode: :snapshot,
      source: {:file, file},
      file_uuid: nil,
      source_file_uuid: to_string(file.uuid),
      filename: file_filename(file),
      content_type: file.mime_type,
      size_bytes: file.size || 0,
      flags: normalize_flags(flags),
      key: to_string(file.uuid)
    }
  end

  defp file_filename(file),
    do: clean_filename(file.original_file_name || file.file_name)

  # An attachment row the user may forward: on a sent message they sent or
  # still hold a copy of.
  defp forwardable_row(file_uuid, user_uuid) do
    from(a in Attachment,
      join: m in Message,
      as: :message,
      on: m.uuid == a.message_uuid,
      where: a.file_uuid == ^file_uuid and m.status == "sent",
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> where_participant(user_uuid)
    |> repo().one()
  end

  # A row of the user's own message (a draft too) naming the file: attaching
  # one's own snapshot again keeps its flags, as a forward does.
  defp own_row(file_uuid, user_uuid) do
    from(a in Attachment,
      join: m in Message,
      on: m.uuid == a.message_uuid,
      where: a.file_uuid == ^file_uuid and m.sender_user_uuid == ^user_uuid,
      order_by: [asc: a.inserted_at],
      limit: 1
    )
    |> repo().one()
  end

  defp unavailable?(file),
    do: file.status == "trashed" or not is_nil(file.trashed_at) or file.system_managed == true

  defp cast_file_uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:attachment_forbidden, raw}}
    end
  end

  # The first entry for a file wins: the same file named twice is one row.
  defp dedupe(items) do
    {kept, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, seen} ->
        if MapSet.member?(seen, item.key),
          do: {acc, seen},
          else: {[item | acc], MapSet.put(seen, item.key)}
      end)

    Enum.reverse(kept)
  end

  defp check_count(items) when length(items) > @max_files,
    do: {:error, {:too_many_attachments, @max_files}}

  defp check_count(_items), do: :ok

  # Only what gets stored now is measured: kept and forwarded rows were
  # measured when they were stored.
  defp check_sizes(items) do
    max = max_upload_bytes()

    case Enum.find(items, &(&1.mode == :snapshot and &1.size_bytes > max)) do
      nil -> :ok
      item -> {:error, {:attachment_too_large, item.filename}}
    end
  end

  defp collect(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case fun.(entry) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp normalize_flags_map(flags) when is_map(flags) do
    Map.new(flags, fn {uuid, value} -> {to_string(uuid), value} end)
  end

  defp normalize_flags_map(_), do: %{}

  defp normalize_flags(flags) when is_map(flags),
    do: Map.new(flags, fn {k, v} -> {to_string(k), v} end)

  defp normalize_flags(_), do: %{}

  # ── policy ──────────────────────────────────────────────────────────────────

  @doc false
  # Asks the host's attachment_policy about `items` reaching everyone who can
  # read `mailboxes` — the sending mailbox and the recipients'. The scope's
  # own user is left out only when every file is a snapshot they created
  # (their upload or copy); a forwarded file, a colleague's draft file or any
  # other snapshot someone else made counts them in. Nothing to ask without
  # attachments, without anyone, or without a policy.
  @spec check_policy(Scope.t(), [Mailbox.t()], [map()]) :: :ok | {:error, term()}
  def check_policy(_scope, _mailboxes, []), do: :ok

  def check_policy(scope, mailboxes, items) do
    me =
      case Mailboxes.scope_user_uuid(scope) do
        {:ok, uuid} -> uuid
        _ -> nil
      end

    others = Enum.reject(readers(mailboxes), &(to_string(&1.uuid) == me))
    users = if foreign_snapshot?(items, me), do: with_user(others, me), else: others

    case users do
      [] -> :ok
      users -> ask_policy(scope, users, Enum.map(items, &to_row/1))
    end
  end

  # Whether an item re-uses or keeps a snapshot `me` did not create. New
  # snapshots (`:snapshot` items) are stored as `me`'s.
  defp foreign_snapshot?(_items, nil), do: false

  defp foreign_snapshot?(items, me) do
    uuids = for %{mode: mode, file_uuid: uuid} <- items, mode in [:keep, :reuse], do: uuid

    uuids != [] and
      from(f in Storage.File,
        where: f.uuid in ^uuids,
        where: is_nil(f.user_uuid) or f.user_uuid != ^me,
        select: count(f.uuid)
      )
      |> repo().one()
      |> Kernel.>(0)
  end

  defp with_user(users, nil), do: users

  defp with_user(users, me) do
    case repo().get(User, me) do
      nil -> users
      user -> users ++ [user]
    end
  end

  defp policy, do: Application.get_env(:phoenix_kit_inbox, :attachment_policy)

  defp ask_policy(scope, users, rows) do
    case policy() do
      nil -> :ok
      {mod, fun} when is_atom(mod) and is_atom(fun) -> ask(mod, fun, scope, users, rows)
      other -> {:error, {:attachment_refused, {:invalid_policy, other}}}
    end
  end

  defp ask(mod, fun, scope, users, rows) do
    case apply(mod, fun, [scope, users, rows]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:attachment_refused, reason}}
      other -> {:error, {:attachment_refused, {:unexpected, other}}}
    end
  rescue
    e ->
      Logger.warning("[Inbox] attachment_policy raised, refusing: #{Exception.message(e)}")
      {:error, {:attachment_refused, :policy_failed}}
  catch
    kind, reason ->
      Logger.warning("[Inbox] attachment_policy failed (#{kind}), refusing: #{inspect(reason)}")
      {:error, {:attachment_refused, :policy_failed}}
  end

  # Everyone who can read the mailboxes: the owner of each personal one, and
  # the owner and every grantee of each shared one.
  defp readers(mailboxes) do
    owners =
      mailboxes
      |> Enum.map(& &1.owner_uuid)
      |> Enum.reject(&is_nil/1)

    shared = for %Mailbox{kind: "shared", uuid: uuid} <- mailboxes, do: uuid

    grantees =
      from(g in MailboxGrant, where: g.mailbox_uuid in ^shared, select: g.user_uuid)
      |> repo().all()

    uuids = Enum.uniq(owners ++ grantees)

    from(u in User, where: u.uuid in ^uuids, order_by: u.uuid)
    |> repo().all()
  end

  defp to_row(item) do
    %Attachment{
      file_uuid: item.file_uuid,
      source_file_uuid: item.source_file_uuid,
      filename: item.filename,
      content_type: item.content_type,
      size_bytes: item.size_bytes,
      flags: item.flags
    }
  end

  # ── snapshots ───────────────────────────────────────────────────────────────

  @doc false
  # Stores every planned snapshot in the Inbox library, outside any
  # transaction. Returns the items with their `file_uuid` and the uuids it
  # created (to delete if the send then fails); on failure — an error, a
  # raise or an exit — deletes what it made, then returns the error or
  # raises again.
  @spec store_snapshots([map()], binary()) :: {:ok, [map()], [binary()]} | {:error, term()}
  def store_snapshots(items, user_uuid) do
    if Enum.any?(items, &(&1.mode == :snapshot)) do
      with {:ok, library} <- ensure_library() do
        lib = %{uuid: to_string(library.uuid), prefix: key_prefix(library)}
        do_store_snapshots(items, user_uuid, lib)
      end
    else
      {:ok, items, []}
    end
  end

  @doc false
  # The prefix every key of the library's own objects starts with (with its
  # trailing slash), or nil when the core gives the library none.
  @spec key_prefix(term()) :: String.t() | nil
  def key_prefix(%{key_prefix: prefix}) when is_binary(prefix) and prefix != "",
    do: prefix <> "/"

  def key_prefix(_library), do: nil

  defp do_store_snapshots(items, user_uuid, lib) do
    items
    |> Enum.reduce_while({:ok, [], []}, fn
      %{mode: :snapshot} = item, {:ok, acc, created} ->
        case snapshot_or_discard(item, user_uuid, lib, created) do
          {:ok, file} ->
            uuid = to_string(file.uuid)
            {:cont, {:ok, [%{item | file_uuid: uuid} | acc], [uuid | created]}}

          {:error, reason} ->
            {:halt, {:error, reason, created}}
        end

      item, {:ok, acc, created} ->
        {:cont, {:ok, [item | acc], created}}
    end)
    |> case do
      {:ok, items, created} ->
        {:ok, Enum.reverse(items), created}

      {:error, reason, created} ->
        discard_snapshots(created)
        {:error, reason}
    end
  end

  # The snapshots made so far are named by nothing yet: a raise or an exit
  # here must not leave them behind.
  defp snapshot_or_discard(item, user_uuid, lib, created) do
    snapshot(item, user_uuid, lib)
  rescue
    e ->
      discard_snapshots(created)
      reraise e, __STACKTRACE__
  catch
    kind, reason ->
      discard_snapshots(created)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp snapshot(%{source: {:file, file}} = item, user_uuid, lib) do
    case link_file(file, item, user_uuid, lib) do
      {:ok, linked} -> {:ok, linked}
      :error -> copy_file(file, item, user_uuid, lib)
    end
  end

  defp snapshot(%{source: {:path, path}} = item, user_uuid, lib),
    do: snapshot_bytes(path, item, user_uuid, lib)

  defp snapshot(%{source: {:binary, binary}} = item, user_uuid, lib) do
    temp = Path.join(System.tmp_dir!(), "phoenix_kit_inbox_#{UUIDv7.generate()}")

    try do
      File.write!(temp, binary)
      snapshot_bytes(temp, item, user_uuid, lib)
    after
      File.rm(temp)
    end
  end

  # The full copy of a Storage file: its bytes are read out and stored again.
  defp copy_file(file, item, user_uuid, lib) do
    case Storage.retrieve_file(file.uuid) do
      {:ok, temp, _file} ->
        try do
          store_snapshot(temp, item, user_uuid, lib)
        after
          File.rm(temp)
        end

      {:error, reason} ->
        Logger.warning("[Inbox] could not read #{file.uuid} to attach it: #{inspect(reason)}")
        {:error, {:attachment_unavailable, to_string(file.uuid)}}
    end
  end

  # Bytes the sender holds (an upload, the host's data): linked to a Storage
  # file that already has exactly these bytes, else stored.
  defp snapshot_bytes(path, item, user_uuid, lib) do
    checksum = Auth.calculate_file_hash(path)

    case link_bytes(path, checksum, item, user_uuid, lib) do
      {:ok, linked} -> {:ok, linked}
      :error -> store_snapshot(path, item, user_uuid, lib, checksum)
    end
  rescue
    e -> {:error, {:attachment_store_failed, Exception.message(e)}}
  end

  # ── linked snapshots ────────────────────────────────────────────────────────
  #
  # `Storage.link_copy/3` makes a record in the Inbox library that names the
  # donor's stored objects, so the bytes are not written twice. The snapshot
  # is still a row of its own in the Inbox library: it is trashed, edited or
  # deleted on its own, and deleting the donor takes only the keys no other
  # record names. Any refusal, an error, a wrong answer or a core without the
  # function is `:error`, and the caller makes the full copy.
  #
  # The core returns a refusal as a value, never as a rollback, so a send
  # inside the caller's transaction stays usable (the test "a send inside the
  # caller's transaction" asks the real core for refusals).

  @link_donor_limit 3

  # Way 3 and 4: the donor is the file itself; its checksum and size are what
  # the sender was shown, so a donor that changed since is refused.
  defp link_file(file, item, user_uuid, lib) do
    opts =
      [library_uuid: lib.uuid, original_filename: item.filename] ++
        for {key, value} <- [checksum: file.file_checksum, size: file.size], value != nil do
          {key, value}
        end

    case link_copy(file, user_uuid, opts, lib) do
      {:ok, linked} -> {:ok, linked}
      {:error, _reason} -> :error
    end
  end

  # Way 1 and 5: a donor with the same checksum and size. Media first (the
  # sender's own files before anyone else's), then a snapshot that already
  # names keys outside the module's prefix, then any other snapshot. The
  # groups are queried one after the other, only while nothing was linked.
  defp link_bytes(path, checksum, item, user_uuid, lib) do
    with true <- link_copy?(),
         {:ok, %{size: size}} <- File.stat(path) do
      opts = [
        library_uuid: lib.uuid,
        original_filename: item.filename,
        checksum: checksum,
        size: size
      ]

      Enum.find_value(donor_groups(checksum, size, user_uuid, lib), :error, fn {kind, query} ->
        link_group(kind, query, user_uuid, opts, lib)
      end)
    else
      _ -> :error
    end
  end

  # The first donor of a group that links. `:incompatible` is a property of
  # the pair of libraries, so it ends the group; Media's second candidate is
  # tried only after a donor that changed under the caller.
  defp link_group(kind, query, user_uuid, opts, lib) do
    Enum.reduce_while(donors(query), nil, fn donor, nil ->
      case link_copy(donor, user_uuid, opts, lib) do
        {:ok, linked} -> {:halt, {:ok, linked}}
        {:error, :incompatible} -> {:halt, nil}
        {:error, :donor_changed} -> {:cont, nil}
        {:error, _reason} when kind == :media -> {:halt, nil}
        {:error, _reason} -> {:cont, nil}
      end
    end)
  end

  defp donors(query) do
    repo().all(query)
  rescue
    e ->
      Logger.warning("[Inbox] could not look for a file to link to: #{Exception.message(e)}")
      []
  end

  defp donor_groups(checksum, size, user_uuid, lib) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    media = apply(libraries(), :media_uuid, [])
    base = donor_query(checksum, size)

    own_first = dynamic([f], f.user_uuid == ^user_uuid)

    [
      {:media,
       base
       |> where([f], f.library_uuid == ^media)
       |> exclude(:order_by)
       |> order_by(^[desc_nulls_last: own_first, asc: :inserted_at])}
    ] ++ snapshot_groups(base, lib)
  rescue
    # A core that has `link_copy/3` but not `media_uuid/0` (a test seam).
    e ->
      Logger.warning("[Inbox] could not look for a file to link to: #{Exception.message(e)}")
      []
  end

  # The module's own keys are under its library's prefix; a snapshot that was
  # linked to a file elsewhere has that file's. Without a prefix to tell them
  # apart, the second group is left out and the third is all of them.
  defp snapshot_groups(base, lib) do
    inbox = where(base, [f], f.library_uuid == ^lib.uuid)

    case lib.prefix do
      nil ->
        [{:snapshot, inbox}]

      prefix ->
        length = String.length(prefix)

        [
          {:foreign, where(inbox, [f], fragment("left(?, ?)", f.file_path, ^length) != ^prefix)},
          {:snapshot, where(inbox, [f], fragment("left(?, ?)", f.file_path, ^length) == ^prefix)}
        ]
    end
  end

  defp donor_query(checksum, size) do
    from(f in Storage.File,
      where:
        f.file_checksum == ^checksum and f.size == ^size and f.status == "active" and
          f.system_managed == false and is_nil(f.edit_state) and is_nil(f.trashed_at) and
          not is_nil(f.file_path),
      order_by: [asc: f.inserted_at],
      limit: @link_donor_limit
    )
  end

  # The function is looked up at run time: an older core has none, and a
  # literal call would not compile there without warnings. The same seam
  # (`:storage_module`) as `store_file_in_buckets/7`.
  defp link_copy? do
    mod = storage()
    Code.ensure_loaded?(mod) and function_exported?(mod, :link_copy, 3)
  end

  # `{:ok, linked}` only for a new record of the Inbox library; every other
  # outcome — a refusal, a wrong answer, a raise, a throw, an exit — is an
  # `{:error, reason}` and the caller stores the bytes itself.
  defp link_copy(donor, user_uuid, opts, lib) do
    if link_copy?() do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(storage(), :link_copy, [donor, user_uuid, opts]) |> judge_link(donor, lib)
    else
      {:error, :unsupported}
    end
  rescue
    e ->
      Logger.warning("[Inbox] linking #{donor.uuid} failed: #{Exception.message(e)}")
      {:error, :raised}
  catch
    kind, reason ->
      Logger.warning("[Inbox] linking #{donor.uuid} failed (#{kind}): #{inspect(reason)}")
      {:error, kind}
  end

  defp judge_link({:ok, %Storage.File{uuid: uuid} = linked}, donor, lib) do
    if uuid != donor.uuid and to_string(linked.library_uuid) == lib.uuid do
      {:ok, linked}
    else
      Logger.error(
        "[Inbox] link_copy of #{donor.uuid} did not make a new file in the Inbox library; " <>
          "storing the bytes instead"
      )

      {:error, :unexpected_file}
    end
  end

  defp judge_link({:error, reason}, donor, _lib) do
    Logger.info("[Inbox] no linked copy of #{donor.uuid}: #{inspect(reason)}")
    {:error, if(is_atom(reason), do: reason, else: :failed)}
  end

  defp judge_link(other, donor, _lib) do
    Logger.warning("[Inbox] link_copy of #{donor.uuid} answered #{inspect(other)}")
    {:error, :unexpected_answer}
  end

  # Storing the bytes again. Plain `store_file_in_buckets` would hand back the
  # uploader's existing file of the same bytes, in whatever library it is —
  # no snapshot at all — so `dedup: false`.
  defp store_snapshot(path, item, user_uuid, lib, checksum \\ nil) do
    filename = item.filename
    ext = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    mime = item.content_type || MIME.from_path(filename)

    storage().store_file_in_buckets(
      path,
      Storage.determine_file_type(mime, filename),
      user_uuid,
      checksum || Auth.calculate_file_hash(path),
      ext,
      filename,
      library_uuid: lib.uuid,
      dedup: false,
      mime_type: mime
    )
    |> case do
      {:ok, %{library_uuid: stored} = file} ->
        if to_string(stored) == lib.uuid, do: {:ok, file}, else: unsupported_store()

      {:error, reason} ->
        {:error, {:attachment_store_failed, reason}}

      # `{:ok, existing, :duplicate}`: a core that ignores `dedup: false`.
      _other ->
        unsupported_store()
    end
  rescue
    e -> {:error, {:attachment_store_failed, Exception.message(e)}}
  end

  # Storage handed back something other than a new file in the Inbox library:
  # a core without `dedup: false`. The file it returned is not ours to delete.
  defp unsupported_store do
    Logger.error(
      "[Inbox] Storage did not store a separate snapshot (dedup: false unsupported); " <>
        "attachments need the first PhoenixKit release after 2.63.0"
    )

    {:error, :storage_unsupported}
  end

  @doc false
  # Deletes snapshots a failed send made. Nothing names them yet.
  @spec discard_snapshots([binary()]) :: :ok
  def discard_snapshots(file_uuids), do: release(file_uuids)

  # ── rows ────────────────────────────────────────────────────────────────────

  @doc false
  # Inside the message transaction: makes the message's rows exactly
  # `items`, in order — kept rows stay (repositioned), dropped ones go, new
  # ones are inserted. Returns the file uuids of the rows dropped.
  @spec write_rows(Ecto.Repo.t(), binary(), [map()]) :: {:ok, [binary()]} | {:error, term()}
  def write_rows(repo, message_uuid, items) do
    kept = for %{mode: :keep, row: row} <- items, do: row.uuid

    dropped =
      from(a in Attachment, where: a.message_uuid == ^message_uuid and a.uuid not in ^kept)
      |> repo.all()

    _ = repo.delete_all(from(a in Attachment, where: a.uuid in ^Enum.map(dropped, & &1.uuid)))

    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, position}, :ok ->
      case write_row(repo, message_uuid, item, position) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, Enum.map(dropped, &to_string(&1.file_uuid))}
      error -> error
    end
  end

  defp write_row(repo, _message_uuid, %{mode: :keep, row: row}, position) do
    row |> Ecto.Changeset.change(position: position) |> repo.update()
  end

  defp write_row(repo, message_uuid, item, position) do
    %Attachment{}
    |> Attachment.changeset(%{
      message_uuid: message_uuid,
      file_uuid: item.file_uuid,
      source_file_uuid: item.source_file_uuid,
      filename: item.filename,
      content_type: safe_content_type(item.content_type),
      size_bytes: item.size_bytes,
      position: position
    })
    # Server-set only, never cast from anything a form could reach.
    |> Ecto.Changeset.put_change(:flags, item.flags || %{})
    |> repo.insert()
  end

  @doc false
  # Deletes each of `file_uuids` that is an Inbox-library file no attachment
  # row names any more. Best-effort, after the transaction: a failure is
  # logged, never raised — what was committed must not fail with it.
  @spec release([binary()]) :: :ok
  def release([]), do: :ok

  def release(file_uuids) do
    library = library_uuid()
    file_uuids = Enum.uniq(file_uuids)

    named =
      from(a in Attachment, where: a.file_uuid in ^file_uuids, select: a.file_uuid)
      |> repo().all()
      |> MapSet.new(&to_string/1)

    for uuid <- file_uuids, not MapSet.member?(named, uuid), do: delete_snapshot(uuid, library)

    :ok
  rescue
    e ->
      Logger.warning("[Inbox] could not release snapshots: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[Inbox] could not release snapshots (#{kind}): #{inspect(reason)}")
      :ok
  end

  # Only ever a file of the Inbox library.
  defp delete_snapshot(uuid, library) do
    with %Storage.File{} = file <- Storage.get_file(uuid),
         true <- in_library?(file, library),
         {:error, reason} <- delete_file_completely(file) do
      Logger.warning("[Inbox] could not delete snapshot #{uuid}: #{inspect(reason)}")
    end
  end

  # The module owns its library, which the core may keep from users.
  defp delete_file_completely(file) do
    case owner_opts() do
      [] -> Storage.delete_file_completely(file)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      opts -> apply(Storage, :delete_file_completely, [file, opts])
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  @doc """
  `content_type` if it is a plain `type/subtype` token, else
  `"application/octet-stream"` — what is stored and served. A browser's or
  host's value is never trusted as it is.
  """
  @spec safe_content_type(term()) :: String.t()
  def safe_content_type(content_type) when is_binary(content_type) do
    if Regex.match?(~r{\A[\w.+-]+/[\w.+-]+\z}, content_type),
      do: content_type,
      else: "application/octet-stream"
  end

  def safe_content_type(_), do: "application/octet-stream"

  # The browser's (or host's) name, reduced to a base name without control
  # characters, fit for the 255-character column with its extension kept.
  defp clean_filename(name) do
    name =
      name
      |> to_string()
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.trim()

    if name in ["", ".", ".."], do: "attachment", else: bound_filename(name)
  end

  defp bound_filename(name) do
    if String.length(name) <= @max_filename do
      name
    else
      ext = Path.extname(name)
      keep = max(@max_filename - String.length(ext), 1)
      String.slice(Path.rootname(name), 0, keep) <> String.slice(ext, 0, @max_filename - keep)
    end
  end
end
