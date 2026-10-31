# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit module providing an **internal mailbox** — an in-app email client for messages between the users of the host application. Implements the `PhoenixKit.Module` behaviour for auto-discovery.

Four admin pages:

- **Inbox** (`Web.InboxLive`) — three-pane webmail: folder sidebar, message list, reading pane
- **Compose** (`Web.ComposeLive`) — new / reply / forward / drafts (hidden tab, reached from the New message button)
- **Mailboxes** (`Web.MailboxesLive`) — shared mailboxes and who can use them; the Access panel picks colleagues from `Mailboxes.search_users/3` (members, not the viewer) and lists grants by name (`list_grant_holders/1`); the Signatures panel writes a mailbox's signatures (`Web.SignatureEditor`, offered on a mailbox the viewer administers when they hold `inbox.manage_shared`)
- **Settings** (`Web.SettingsLive`, "Mail" in core's Settings section, `/admin/settings/inbox`, from `settings_tabs/0`) — shared senders (add, edit, roles; the form never binds a mailbox and passes on only its own fields)

And one user page, outside the admin area: **Mail settings** (`Web.MySettingsLive`, `/dashboard/inbox-settings`) — the user's signatures, default Reply-To and personal senders. It is a `user_dashboard_tabs/0` entry with a `live_view`, so core generates its route in the authenticated session; the page checks access itself and draws its own layout (`LayoutWrapper.app_layout`). A second entry, **Mail**, is an absolute path (`/admin/inbox`) with no `live_view` — core leaves absolute paths as they are and generates no route for it. Both are in the avatar menu (`user_menu: &PhoenixKitInbox.user_menu?/1` — the `"inbox"` permission).

## Scope boundary — read this before adding features

Inbox is **internal** first. Messages address mailboxes inside the app; nothing is fetched over IMAP. Mail leaves the app only to the external recipients of a message, its retry and the email nudge — all through one seam, closed by default (below). Before adding any other transport, check whether the request actually belongs in a neighbour:

| Concern | Module |
|---|---|
| Users messaging each other | this one |
| Outbound campaigns, mailing lists | `phoenix_kit_newsletters` |
| Delivery tracking, bounces, SES/SQS | `phoenix_kit_emails` |
| Customer tickets, statuses, SLAs | `phoenix_kit_customer_support` |

### Outbound mail — one seam

**Every** email the module sends goes through `PhoenixKitInbox.Outbound.deliver/2`. Never call `PhoenixKit.Mailer` anywhere else.

- **Closed by default**: the `inbox_external_enabled` setting (off) **and** `config :phoenix_kit_inbox, outbound_filter: {Mod, :fun}` (or explicit `:none`). Missing either → `{:error, :external_disabled}`.
- The host filter gets `(%Swoosh.Email{}, context)`; only To/Cc/Bcc/Reply-To of its answer are taken. A raise, throw, exit or a non-`{:ok, %Swoosh.Email{}}`/`{:error, _}` answer refuses (`:filter_failed`) — an error must stop mail.
- The call is `deliver_via_integration/3` with `skip_queue: true` **and** `queue: false` on every call: `phoenix_kit_emails`' queue re-sends through core's *default* integration, so a queued message would leave from the wrong connection. Tests assert both.
- `deliver_via_integration/3` reads any connection by uuid: the caller resolves the identity first (`Identities.resolve/3` for a user's send, `resolve_system/1` for the nudge).
- `config :phoenix_kit_inbox, :outbound` replaces only the transport (`Outbound.Mailer` by default), for tests — the checks and the filter still run.

External recipients (`PhoenixKitInbox.External`): rows written `pending` in the send's transaction; the email goes after the commit in a task under `PhoenixKitInbox.TaskSupervisor` (`children/0`); the rows become `sent`/`failed` and `{:inbox_external_updated, uuid}` is broadcast on the sending mailbox's topic. A failure there must never touch the internal part. Retry only takes `failed` rows, in one `UPDATE … RETURNING`, so it can't send twice; it needs `phoenix_kit_emails` (its log decides whether anything went out — found by `message_tags.inbox_message_uuid`, `inbox_kind = "message"`) and is never offered for `record_sent` messages.

The **email nudge** in `PhoenixKitInbox.Notify` goes the same way, from the shared identity named by `inbox_nudge_identity_uuid` — never core's default integration; no sender, no nudge. `phoenix_kit_emails` stays a **soft** dependency, **not** in `mix.exs`: `EmailLog` asks it `enabled?/0` through `apply/3` behind `Code.ensure_loaded?/1` + `function_exported?/3` (a literal call is a `--warnings-as-errors` failure). Nudges fire **after** the commit, in a task, and every failure is rescued and logged.

## Database & Migrations

**This module owns its DDL.** That is the point of the module, architecturally. Older PhoenixKit modules put their tables in core's versioned chain (V90+), which meant a module schema change needed a core release. Inbox follows the newer self-contained pattern used by `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`, and `phoenix_kit_stats`.

- `PhoenixKitInbox.Migrations` — coordinator, returned from `migration_module/0`
- `PhoenixKitInbox.Migrations.V01` — the tables; `V02` — deletion-safe foreign keys and unique shared addresses; `V03` — message attachments; `V04` — sending identities and mailbox signatures; `V05` — external recipients with their status; `V06` — the roles of a common sender (seeded once, on 5 → 6, from the roles holding `inbox.send_external` or `"*"`, Owner aside); `V07` — links from messages to objects of the host, idempotent send keys, and the sender-name flag of a shared identity. **Immutable once shipped**
- Version tracked via `COMMENT ON TABLE phoenix_kit_inbox_mailboxes` (not a bare "does the table exist?" check — that can't tell "not installed" from "installed at V1")
- `mix phoenix_kit.update` discovers the coordinator and generates the host migration

### Adding a version

1. New `lib/phoenix_kit_inbox/migrations/v02.ex` with `up/1` and `down/1`
2. Bump `@current_version` in `Migrations` and add the `apply_step(:up, 2, prefix)` / `apply_step(:down, 2, prefix)` clauses
3. **Never edit a shipped version module** — hosts past it will not re-run it, so an edit only affects fresh installs and silently splits the world in two

New SQL must stay prefix-safe (core AGENTS.md, "Prefix-safe migrations"): bare index names on `CREATE`, schema-anchored existence checks, `Helpers.uuid_v7_call/1` for the UUID default, `Helpers.validate_prefix!/1` at the entry point.

### Schema conventions

- UUIDv7 primary keys named `uuid`, never `id`
- `use PhoenixKit.SchemaPrefix` right after `use Ecto.Schema` — guarded by `test/schema_prefix_conformance_test.exs`
- Table names prefixed `phoenix_kit_inbox_`
- `timestamps(type: :utc_datetime)`
- Soft-delete is a sentinel on an existing `status` column (`"archived"`, `"deleted"`), never a `deleted_at` timestamp

## Data model

The load-bearing decision is **message vs. delivery**:

```
phoenix_kit_inbox_mailboxes          kind: "user" (one per user) | "shared"
 └─ phoenix_kit_inbox_mailbox_grants  read / write / admin for non-owners

phoenix_kit_inbox_messages           body stored ONCE; thread_uuid, parent_uuid, sender
 ├─ phoenix_kit_inbox_deliveries      one per recipient mailbox: folder, seen_at, starred
 └─ phoenix_kit_inbox_attachments     file_uuid → a snapshot in the module's Storage library (listed in Media, read-only)

phoenix_kit_inbox_identities          kind: "shared" (system integration, mailbox or none) | "personal" (owner)
 └─ phoenix_kit_inbox_identity_roles  roles a common sender is open to (both FKs cascade)
phoenix_kit_inbox_signatures          per mailbox, Markdown, at most one is_default
```

Consequences worth remembering before changing anything:

- **Per-recipient state lives on the delivery, never on the message.** Marking a group thread read must not mark it read for the other four recipients. Any new per-person flag goes on `Delivery`.
- **`Messages.fetch_for_mailbox/2` is scoped through the delivery.** Asking for a message uuid a mailbox was never sent returns `{:error, :message_not_found}` — that is the read-authorization boundary, not an incidental join.
- **`purge/3` marks the delivery `"deleted"`, not the message.** Deleting your copy of a thread must not delete anyone else's.
- **`thread_uuid` is NOT NULL and a root message's equals its own uuid.** It can't be set before insert, so `backfill_thread_uuid/2` writes it inside the same `Multi`.
- **Folders are a column, not a table.** Six fixed values. User-defined labels would be a new table + join, i.e. a V02 — not a v1 guess.

## Sending

`Messages.send_message/4` (scope form) and `/3` (mailbox + sender uuid) are one `Ecto.Multi`. A message is never half-delivered.

- **The send authorizes itself**: `write` on the sending mailbox, plus the `"inbox"` permission in the scope form. The compose form only hides what would fail. Saving a draft needs `write` too.
- Recipients resolve through `Mailboxes.fetch_mailbox_by_recipient/1`: `@name` and emails look for a user first, bare names for a shared mailbox first; users only inside the recipient circle (`PhoenixKitInbox.Members`, host-overridable via `:recipient_filter`). Two candidates for one term → `{:ambiguous_recipients, [...]}`.
- The message's `metadata` gets a server-written `"sender"`/`"recipients"` snapshot; the recipients include `bcc` rows, so show them to the sender only (`list_recipients/2` does that filtering for deliveries).

- An unresolvable recipient fails the **whole** send (`{:error, {:unknown_recipients, [...]}}`). Silently dropping a recipient is worse than refusing — the sender finds out immediately.
- A mailbox listed in both To and Cc gets one copy at the stronger role (`dedupe_recipients/1`), because the unique index on `(message, mailbox, role)` would otherwise let the same person appear twice.
- `upsert_delivery/5` is idempotent, which is what makes the fan-out safe to retry and what lets sending a draft *move* the author's existing `drafts` row to `sent` rather than creating a second one.
- Sending a draft promotes the **same row** — same uuid, `status` flips to `"sent"`. Don't "copy and delete"; links to the draft uuid would break.
- `"identity_uuid"` and `"reply_to"` (scope form only; the `/3` form refuses them with `:sender_options_need_scope`) are checked by `Identities.resolve/3` against the sending mailbox and by `Identities.allowed_reply_to/3`, and recorded as `metadata["identity"]` / `metadata["reply_to"]` — server-written, a caller's copy is dropped. The identity is also what external recipients are sent as (see "Outbound mail"). An email address that resolves to nobody is an external recipient when the scope may write externally (`inbox.send_external`, or a personal identity), else an unknown recipient; the `/3` form refuses an address outside (`:external_needs_scope`). A draft keeps them as typed (`draft_sender/1`), unchecked until the send.
- Bodies are `text`, `html` or `markdown`; compose writes `markdown`. The reading pane renders only `markdown` (`PhoenixKitInbox.Body`: core's `PhoenixKit.Email.Markdown` with no variables, so `{{x}}` stays as typed; typed line breaks kept; remote images turned into links, never loaded; links `target=_blank rel=noopener noreferrer nofollow`) and shows everything else escaped. Never render a body as raw HTML any other way.

### Server-side options of `send_message/4` (scope form)

Given by the host's code, never read from a form's `attrs` (a caller's copy in `attrs`, including `attrs["metadata"]`, is dropped):

- `links: [%{kind:, ref:}]` — objects of the host the message is linked to; stored in the send's transaction with the links inherited from the conversation. Host subject resolvers (`link_resolver.ex`) run last, after the email has gone.
- `reply_to_trusted: address` — a Reply-To the host vouches for, validated as an address but not matched against `reply_to_options`.
- `html_body: html` — the host's HTML for the email to external recipients (≤ 256 KiB), kept in `metadata["html_body"]` for a retry and only when the message has external recipients. It never reaches a reader: every read function goes through `Messages.project_for_viewer/2`.
- `idempotency_key: key` — a repeat answers with the first message and does nothing else; recorded in `phoenix_kit_inbox_send_keys` in the send's transaction.
- A shared identity's `personalize_from_name` puts the sender's name in front of its own in the From name.

Before sending, a host may ask what would happen: `Messages.resolve_recipient_routes/2` (read-only: the send's own lookup, `:internal` or `:email` per address, one address per entry) and `Outbound.preview/2` (the host's `outbound_filter`, told `preview: true`; nothing is sent).

## Identities and signatures

`PhoenixKitInbox.Identities` and `PhoenixKitInbox.Signatures`; every write takes the caller's `%Scope{}` and checks the **stored** row.

- **The From address is never typed or stored**: it is the integration's login (SMTP `username`, an email). A mail integration without one is unusable (`:no_from_address`).
- **Shared** identity = a `:system` integration, written by `inbox.manage_shared` holders. Bound to a shared mailbox → usable by `write` holders, from that mailbox only. Unbound → the common sender for personal mailboxes: `inbox.send_external` **and** one of its roles (`phoenix_kit_inbox_identity_roles`) in effect for the scope — names from `Scope.user_roles/1`, never a re-read user (that loses "acting as"); Owner by `Scope.owner?/1` always — from one's own personal mailbox, From name `"<user> | <from_name>"`. The roles only narrow; `External.allowed?/2` is unchanged. Bound identities keep no roles; the nudge (`resolve_system/1`) ignores them. **Personal** identity = the owner's `{:user, uuid}` integration, owner only, personal mailbox only. A CHECK constraint keeps the shapes apart; both FKs cascade (an identity outliving its mailbox would become an unbound one).
- `check/1` (exists, `:email_send` provider, credentials, owner, login) is stored in `status` (`broken` ↔ `active`) only by `resolve/2,3` (every send) and `recheck/2` (the settings pages' "Check"). `list_usable/1` checks without writing; the settings listings show the stored status and check nothing (one connections query for the From addresses); the "Add sender" choices are loaded when the button is pressed. **A send uses `resolve/3`** — `resolve/2` has no mailbox fit. Integrations are core's `phoenix_kit_settings` rows, so `integration_uuid` has no FK.
- **Reply-To** options: the user's email + `address` of active shared mailboxes they own or hold `write`/`admin` on. Default: the sending shared mailbox's address (none without one — so an internal reply still goes to the mailbox), else the personal mailbox's `settings["reply_to"]` while allowed, else the email. A reply in compose goes to the message's `reply_to` when set.
- **Signatures**: personal mailbox → owner; shared → `admin` on it **and** `inbox.manage_shared`. `Signatures.list/1` takes a mailbox uuid the caller has authorized (like `list_grants/1`). Compose inserts `Signatures.block/1` (`"\n\n-- \n" <> body`) and swaps it with `swap_block/3` only while the body still ends with what it inserted; a reopened draft is left as saved; only the sending mailbox's signatures can be chosen.

## Attachments

`PhoenixKitInbox.Attachments` owns them; `Messages` calls it on every send and draft save.

- **Every attachment is a snapshot** — a record of its own (uuid, name, owner, folder) in the module's Storage library (slug `"phoenix-kit-inbox"`, `Attachments.ensure_library/0`, made on first use). Its **stored objects** in the bucket may be shared with the file it came from (`Storage.link_copy/3`: ways 3/4, and ways 1/5 when a donor holds the same bytes), except a donor's burned variants, which are never shared. Sharing is by key and counted: deleting either record deletes only the objects no other record names, so an edit or deletion of the original cannot change what was sent. Never attach a Storage file **by reference** — a message names a record of the Inbox library, never the file's own uuid in Media: a later edit or deletion there would change what was sent.
- **Six ways in** (numbered the same in the `Attachments` moduledoc), each checked in the context: an upload (kept in the LiveView's temp upload until the draft is saved or the message sent, then handed over as `attachments_data:` — nothing reaches Storage before, so there are no orphan uploads; taking one off cancels the entry), the sender's own Inbox-library file (a saved draft's snapshot, attached again without a copy), a Storage file the sender may read (`Libraries.can?/3`), `attachments_authorized:` (the host vouched; trash/system-managed still refused), `attachments_data:` (host bytes), and a forward (a file on a sent message the sender sent or still holds a delivery of — same `file_uuid`, flags copied). Server-side options are never read from attrs; `flags` are never cast from a form.
- **Core requirement**: hidden system libraries (core #949: `create_system_library/2` `hidden: true`, `get_hidden_library_by_slug/1`) and `store_file_in_buckets/7` `dedup: false` — core 2.64.0, which `mix.exs` requires (`~> 2.64`). Against an older core (a path dep) attachments are refused with `{:error, :storage_unsupported}` and a log line. Three further core features are **optional**, looked up at run time with `function_exported?/3` + `apply/3` (a literal call is a `--warnings-as-errors` failure on a core without them), and each degrades: `Storage.link_copy/3` (without it, full copies; the donor search by checksum for ways 1/5 reads Media with no index on `file_checksum`, so its cost grows with Media), managed libraries (`update_system_library_listing/2`, `media_listing/1`, `managed?/1`, `managed: :owner`; without them the library stays hidden and unfiled), `Storage.relink_file/3` + `delete_unreferenced_keys/1` (only the maintenance task; it says so and does nothing).
- **Shown in Media, read-only** (`Attachments.ensure_library/0`): where the core has managed libraries the library is listed in Media (`config :phoenix_kit_inbox, media_listing: :uploaders | :admins | :own_only | :none`, default `:uploaders`; `library_name:`, default "Mail attachments") and `managed: true`, so no user — Owner included — changes, deletes, moves or renames its files there; the **core** refuses it. The module's own writes (delete, folder, move, link) pass `managed: :owner` (`Attachments.owner_opts/0`) — a new write to the library's files or folders must too. A library an earlier version made is brought up to date once per node (`bring_up_to_date/1`, state in `:persistent_term`): a refused write or a taken name is not repeated, a passing failure is tried again after `:library_retry_ms` (default 300 000).
- **Folders** (`Attachments.Folders`; after the commit of a send and of a draft save, one transaction, best effort — a failure is logged and leaves the files in the root or in `Drafts`): a sent message's files go to `<mailbox "name (slug)"> / <YYYY-MM> / <YYYY-MM-DD HH:MM — subject>` (site time zone, subject cut to 80 characters, the message's own folder always new, ` (2)`… on a clash), a draft's new snapshots to `<mailbox> / Drafts`. A snapshot belongs to the **first sent message that names it** (by `sent_at`, drafts do not count); every later message (a forward, way 2, a draft's file also in a second draft) leaves it and gets a `FolderLink` in its own folder, and a file moved out of another message's folder leaves a link there. The files of one filing are locked in uuid order, so two filings cannot deadlock. The folder's uuid is a server-written metadata key, `"attachments_folder_uuid"` (next to `sender`, `recipients`, `identity`, `reply_to`; `caller_metadata` drops a caller's copy; written with `jsonb_set`). Inside a caller's transaction nothing is filed (a failure would abort theirs). Folder names carry the message's subject and the mailbox's name, which Owner/Admin see in Media past Inbox's rules under `:admins`/`:uploaders` (say so to a host that cares). Folders have no owner; a viewer who sees only their own files sees the folders leading to them.
- **The host's `attachment_folder` hook** (`config :phoenix_kit_inbox, attachment_folder: {Mod, :fun}`, `(message, sending_mailbox)`) is called in the **sending process** after the commit, so it can read the host's `Process.get` context (as `notification_link` does); it returns a list of folder names that replaces `<mailbox>/<YYYY-MM>`, or `nil`. A name that is not a non-blank string of at most 255 characters without `/` or control characters, any other answer, a raise, exit or throw: the default path and a warning. Compose's task and the maintenance task have no such context, so the hook may answer `nil` there — which is the default path.
- **Maintenance** (`mix phoenix_kit_inbox.relink_attachments`, `Attachments.Maintenance`): dry-run by default; `--apply --manifest PATH` moves full-copy snapshots (keys under the library's `key_prefix`) onto the objects of a donor outside it (a Media file, or a snapshot already on such keys; same checksum and size) with `Storage.relink_file/3` `delete_old: false`, group by checksum, **never inside a transaction**; then files every sent message not yet filed (this also repairs failed filings); keeps a JSON manifest (uuid, checksum, old keys — only **canonical keys under the prefix**: no `.`/`..`/empty segment, no backslash or control character —, `verified`), checked writable before anything moves, written atomically (unique tmp + rename) **before** each `relink_file` (an unverified intent with the keys the record names now) and after it, guarded by a `<manifest>.lock` file (delete it by hand after a killed run), `"gone"` for a record deleted since (its keys go in phase 2 like a verified one's, once nothing names them), and reads every relinked file back comparing sha256 (a later `--apply` re-checks entries that never verified). A record that fails the check stays relinked and its old keys are not deleted. `--purge-old --manifest PATH` drops non-canonical keys, never deletes a key an unverified entry names, refuses a manifest of another library, and `Storage.delete_unreferenced_keys/1` deletes only what nothing names. Dry runs only read (`Attachments.existing_library/0`, no library is made). Candidates are snapshots that are active, not system-managed and not being edited; others, and messages whose sending mailbox is gone, are reported as skipped (exit 0). Take a database dump before phase 1 and copy `<bucket>/<key prefix>/` before phase 2. A second run changes nothing. Output is English, without gettext, like core's mix tasks.
- **The media picker** is core's `UserMediaSelectorModal` (the user's own files); only a system role gets the full `MediaSelectorModal` — without `user_uuid` it lists every user's files, names and thumbnails. A file uploaded inside the picker lands in Media first (core's picker behaviour) and is snapshotted at send like any picked file. A refused pick is named only when `Libraries.can?/3` lets the user read it.
- **Snapshots are stored before the transaction** with `dedup: false` (without it Storage returns the uploader's existing file in its own library — no snapshot) and are deleted if the transaction rolls back — or raises or exits: the write runs in `Messages.with_snapshots/2`, each snapshot in `snapshot_or_discard/4`, both deleting what was stored and raising again. `release/1` (after the commit) logs a failure and never raises, so it can't stop the external part. `store_file_in_buckets` takes a directory lock; don't move it inside the `Multi`.
- **Deleting a snapshot goes through `Attachments.release/1`**: only an Inbox-library file no attachment row names. Sent messages are permanent, so their snapshots are never deleted; a discarded draft or a dropped draft attachment releases its own.
- **The host's `attachment_policy`** (`{Mod, :fun}`, `(scope, users, rows)`) must see everyone who can read the files: at send/forward (before anything is stored) the readers of the recipient mailboxes **and of the sending mailbox**; at a draft save, its mailbox's readers; at download, the viewer alone — that covers grants given later. The reading pane and compose's chips (a forward, a draft) list through `Attachments.list_for_viewer/2`, which asks the same per row for the viewer and returns a refused row as `{:withheld, row}` without its name, type, size or flags; without a policy it is `list_for_message/1`'s one query. The only exemption is the **snapshot's creator** (`files.user_uuid`, whoever's upload or copy it is): the scope user is left out of a send/draft check only when every file is a snapshot they created, and a download skips the policy only for the creator. Never exempt by "sender of the message" — a forward or a draft would launder someone else's file. Anything but `:ok` refuses. A new way to reach an attachment must ask it too — **with one exception, the Media listing**: Media's browser (`media_listing`) does not ask the policy. `:own_only` (and a non-admin under `:uploaders`) is the same rule as the creator's exemption; but Owner/Admin under `:admins` and `:uploaders` see every attachment of every message past `attachment_policy`. For a host whose policy hides files from its administrators that is a hole: set `media_listing: :own_only` or `:none`.
- **Compose sends and saves in a task** (`start_async/3`): the LiveView isn't blocked while snapshots are copied. The work runs under `PhoenixKitInbox.TaskSupervisor`, not linked to the page, so leaving the page doesn't kill a send between its commit and the external part; without the supervisor it runs in the page's task, and then leaving the page does cut the send short. An upload's temp file belongs to its upload channel and goes with the page, so the work gets a hard link of its own to each (`own_uploads/1`, deleted when the work ends; the upload's own path where no link can be made, e.g. another file system). While `@saving`, the events that would start another or change what it works on (send, save, discard, mailbox, picker and a pick from it, removing a chip, cancelling an upload) are ignored and their buttons disabled — the upload input too while a send runs (`@sending`); a draft save leaves new uploads alone; uploads are handed over with `:postpone`, so a failure — an error tuple or a crash — leaves the form, the uploads and the chips for the next try. A draft save consumes only the entries it stored. A scope refresh (`phoenix_kit_scope_changed/1`) or an access event arriving meanwhile only sets `@refresh_pending`; `handle_async/3` runs it once the task is done (after a saved draft's uuid is assigned, before its chips are read with the refreshed scope), so nothing changes the mailbox, draft, sender or form under a running task. The task keeps the scope of the click; the context re-reads the grants it needs.
- **Known leaks, not swept yet**: snapshots stored before a transaction whose process is killed before the commit, and every snapshot after a rollback to before V03 (the rows go, the files stay — hidden libraries are outside Storage's orphan cleanup). Rolling the module back to a version before the library was managed: its old `release/1` deletes without `managed: :owner`, so it cannot remove the snapshots of a discarded draft — they stay in the library. A core that answers `link_copy/3` with a record outside the Inbox library (`judge_link/3` stores the bytes itself and logs) leaves that record, which the module does not delete. A failed filing leaves the files in the root or in `Drafts` until the maintenance task files them; a `Drafts` folder an older name or language made is found by its files, not its name. Filing inside a caller's transaction is skipped. Also the upload hard links of a send or save whose work never reached its `after` — the tiny window between `own_uploads/1` and the task's start, the fallback without the supervisor, a brutal kill; they stay in the system tmp dir until it is cleaned, and are not swept.
- **Downloads only through `Web.AttachmentController`** (`route_module/0` → `Web.Routes`), streamed with `Content-Disposition: attachment`; never hand out a Storage URL. The one other way to a snapshot's bytes is Media's read-only listing of the library, for the people core lets read it (see above). Access is `Attachments.fetch_for_download/2`: module on, `"inbox"`, sender or holder of a non-deleted delivery in a readable mailbox.

## Access control

Two gates, and they are different questions:

1. **Module permission** — `Scope.has_module_access?(scope, "inbox")`. Can this user open Inbox at all? Checked in every LiveView's `mount/3` and re-checked in `handle_params/3`. Sub-permissions (`inbox.manage_shared`, `inbox.send_external`) are checked with `Scope.can?/2` **in the context function** that needs them, so those functions take the caller's `%Scope{}` (`create_shared_mailbox/2`, `update_mailbox/3`, everything in `Identities` and `Signatures`).
2. **Mailbox grants** — `Mailboxes.authorize(mailbox, user_uuid, "write")`. Which mailboxes can they see once inside? Ownership short-circuits to `"admin"`, so an owner never has a grant row for their own mailbox.

**Every function that changes data takes the caller's `%Scope{}` and checks both gates itself** through `Mailboxes.authorize_scope/3` (which re-reads the mailbox, so a stale or hand-built struct grants nothing): seen/star need `read`; drafts, move, purge and sending need `write`; grants, archive/restore and `update_mailbox/3` need `admin`. LiveViews pass `socket.assigns.scope` and only render the outcome. The one exception is `Messages.send_message/3` (mailbox + sender uuid), kept for hosts and checked against the grants. Sending refuses an archived mailbox. A `parent_uuid` (send or draft) is kept only if the sender can read that message — a mailbox they own or are granted holds a copy, or sent it; otherwise it is dropped and the message starts its own thread. A caller-supplied `thread_uuid` is never used.

Levels are ordered `read < write < admin` via `MailboxGrant.covers?/2`.

**Re-check on every param change, not just at mount** — a user can hand-edit `?mailbox=` in the URL. `InboxLive.apply_params/2` and the `mutate/3` helper both do.

**And when access changes under an open page.** Each page copies core's scope into its own `:scope`, so it must hear about changes:

- **Core's scope refresh** (roles/permissions changed, a role switch) calls `phoenix_kit_scope_changed/1`, which every page exports: `Web.ScopeRefresh.assign_scope/1` copies `:phoenix_kit_current_scope`/`:phoenix_kit_current_user` again, then the page recomputes **every** gate and what it derived from them with the same functions its `mount/3` uses (`assign_module_access`/`assign_gates`) — a new gate goes there, or a refresh forgets it. Core evicts an admin page that lost its permission itself; the page only makes its state correct. `MySettingsLive` is outside the admin area, so it navigates to `Paths.dashboard/0` itself — except when core evicts anyway (the user lost the admin area altogether: `scope_refresh_decision/4` → `:evict_admin_area` fires on any page), where a second `push_navigate` would crash the socket. The test hook (`test/support/hooks.ex`) runs core's decision after the page, so a double navigation fails the suite.
- **Inbox's own rows** (grants, mailbox status/address, senders) are invisible to core: `PhoenixKitInbox.AccessEvents` broadcasts `{:inbox_access_changed, :mailboxes | :senders}` after the write — per user (grant holder; owner + holders on create/archive/restore/`update_mailbox/3`; a personal sender's owner) and on a global senders topic (shared sender create/update/delete). Pages subscribe on connected mount (`ScopeRefresh.subscribe/2`) and run the same refresh. A new write that changes who reaches a mailbox or a sender must broadcast too.
- What a refresh does: Inbox reloads the mailbox list (and its `External` subscriptions — listed mailboxes plus the open one) and patches a no-longer-readable open mailbox to the personal one, else reads the open message again — its externals, and its attachments through `list_for_viewer/2` with the new scope (the host's policy may answer differently); Compose re-reads mailboxes/identities/Reply-To options, keeps the typed form and attachments, and falls back (personal mailbox, inside-only, default Reply-To) with a flash; Mailboxes closes an Access/Signatures panel the viewer may no longer use. Actions still check the context — the refresh is for what the page shows.

## Code Organization

```
lib/phoenix_kit_inbox.ex                  # PhoenixKit.Module callbacks
lib/mix/tasks/phoenix_kit_inbox.relink_attachments.ex
lib/phoenix_kit_inbox/
├── paths.ex                              # ALL URL building — never hardcode a path
├── errors.ex                             # error atom -> gettext string
├── gettext.ex                            # the module's Gettext backend (priv/gettext)
├── mailboxes.ex                          # mailbox lifecycle + access control
├── members.ex                            # recipient circle (who is addressable)
├── messages.ex                           # compose, send, list, file
├── attachments.ex                        # snapshots, policy, downloads, the library
├── attachments/folders.ex                # filing snapshots in folders of the library
├── attachments/maintenance.ex            # relink + file existing snapshots (the mix task)
├── identities.ex                         # sending identities + Reply-To choices
├── signatures.ex                         # mailbox signatures
├── body.ex                               # Markdown body -> safe HTML, previews
├── notify.ex                             # activity log + optional email nudge
├── outbound.ex, outbound/mailer.ex       # THE way mail leaves: checks, filter, core call
├── external.ex                           # external recipients: rows, task, status, retry
├── links.ex, link_resolver.ex            # message ↔ host-object links (+ the resolver behaviour)
├── recipient_source.ex, recipient_sources/members.ex   # where a compose form finds people to suggest (+ the module's own)
├── object_mail.ex                        # an object's mail as one viewer may read it (visible mailboxes only)
├── access_events.ex                      # PubSub: grant/mailbox/sender changes for open pages
├── email_log.ex                          # reads phoenix_kit_emails' log (soft dependency)
├── migrations.ex                         # version coordinator
├── migrations/v01.ex … v07.ex            # immutable
├── schemas/{mailbox,mailbox_grant,message,delivery,attachment,identity,identity_role,signature,external_recipient,link,send_key}.ex
└── web/{inbox_live,compose_live,mailboxes_live,settings_live,my_settings_live}.ex
    web/{signature_editor,identity_editor}.ex   # editors the pages share
    web/scope_refresh.ex                  # scope copy + access-event subscriptions the pages share
    web/components/{mail_explorer,mail_tree,mail_explorer_hooks}.ex   # the embeddable per-object mail component (+ its live updates)
    web/components/{compose_draft,compose_pipeline}.ex   # the host's draft + the server-side recheck of a compose form's send
    web/components/compose_form.ex   # the embeddable compose form (a thin view over the pipeline)
```

- **Contexts own every query.** LiveViews call context functions; no `Repo` or `Ecto.Query` in `web/`.
- **`render/1` is a flat dispatch** over private function components, each declaring `attr` for what it reads (the section-decomposition pattern from `phoenix_kit_hello_world`'s `ComponentsLive`). Don't pass whole `assigns` into a section.
- **`patch_to/2` in `InboxLive`** takes only what changes and reads the rest off the socket, then builds the URL via `Paths.inbox/1`. Add a new query param in `Paths.inbox/1` first, then thread it through `patch_to/2` and `apply_params/2`.

## Critical Conventions

- **Module key** `"inbox"` — consistent across `module_key/0`, `permission_metadata/0`, tab `:permission`, notification type key, and settings prefix
- **Tab IDs** prefixed `:admin_inbox`; the sidebar reads "Mail" › "Inbox" (`:admin_inbox_messages`), "Mailboxes"; the settings tab is `:admin_settings_inbox` (parent `:admin_settings`, permission `inbox.manage_shared`). msgid "Inbox" is shared with the folder and the page title, so its translation stays as it is
- **URL paths** use hyphens, never underscores
- **Navigation** always via `PhoenixKitInbox.Paths`, never a relative or hardcoded path. Core follows stored notification links verbatim: build the default with `Paths.message_path/3` and the reader's locale so the host's URL prefix and admin segment are applied. A host's `notification_link` answer is stored as given, without another prefix.
- **`enabled?/0`** rescues and returns `false`; it runs before the DB is guaranteed up
- **Wrap user-facing strings in gettext** with the module's own backend (`use Gettext, backend: PhoenixKitInbox.Gettext`; catalogues `en`, `et`, `ru` under `priv/gettext/`) — including `page_title`, flashes, button labels, empty-state copy. A new string needs its `et` and `ru` translation: `mix gettext.extract --merge`, then fill the empty `msgstr`s (`test/phoenix_kit_inbox/gettext_catalogue_test.exs` fails on an untranslated one). Core sets the locale; the backend reads the process-wide one
- **No page-level width cap** — the page root gets spacing only (`flex flex-col px-4 py-6 gap-4`); the admin layout owns page width
- **One header, from `page_title`** — set it in `mount/3`; don't also render an in-body `<h1>`
- **Prefer core components** — `<.input>`, `<.select>`, `<.textarea>`, `<.empty_state>`, `<.icon>` over raw markup
- **daisyUI 5** — no `btn-group` (use `join`), no `label-text`, no `*-bordered` classes

## Common Commands

```bash
mix deps.get
mix test                    # integration tests auto-exclude without PostgreSQL
mix test.setup              # createdb (run once)
mix format
mix credo --strict
mix dialyzer
mix precommit               # compile --warnings-as-errors + deps.unlock --check-unused + hex.audit + quality.ci
```

### Local cross-repo development

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

`pk_dep/3` in `mix.exs` swaps the Hex pin for a `path:` + `override: true` dep when `<APP>_PATH` is set. **Never hand-edit a `phoenix_kit*` dep into a `path:` tuple** — a committed path dep ships a broken package.

## Testing

- `test/support/data_case.ex` — sandbox + `user_fixture/1`. Inbox's tables have FKs to `phoenix_kit_users`, so a fabricated uuid fails on insert; every mailbox needs a real owner row. `storage_setup/1` gives a test real Storage (a temp-dir local bucket, the only enabled one, and a manual Oban) — use it in `async: false` cases; `stored_file_fixture/3` stores a file as a user.
- `test/support/live_case.ex` — `fake_scope/1` + `put_test_scope/2` for permission-gated LiveView tests
- `test/support/test_migration.ex` — wraps `PhoenixKitInbox.Migrations` so `Ecto.Migrator` can run it. The suite applies **the real coordinator**, so it can't pass against a schema that differs from what installs get.
- `test/test_helper.exs` — runs `PhoenixKit.Migration.ensure_current/2` (core's tables, incl. `phoenix_kit_users`) **then** this module's migration. Order matters: our FKs reference core's tables.

**Three test seams stand in for core's Storage**, unset in production: `config :phoenix_kit_inbox, :storage_libraries, Mod` replaces `Storage.Libraries` for the hidden-library API (a module without `get_hidden_library_by_slug/1` is an older core — the `:storage_unsupported` path), `:storage_module` replaces the module whose `store_file_in_buckets/7` and `link_copy/3` store a snapshot (a core ignoring `library_uuid:` or `dedup: false`, or one without `link_copy/3`), and `:folder_storage` replaces the module `Attachments.Folders` calls for files and folders (`get_file/1`, `create_folder/3`, `move_file_to_folder/4`, `folder_link/2`, `create_folder_link/4` — to make a move or a link fail). `:library_retry_ms` is a knob, not a seam: the wait before a failed library update is tried again — `0` for "now", a long one for "not yet", never `Process.sleep/1`.

The maintenance task's tests (`attachments_maintenance_test.exs`, `relink_attachments_task_test.exs`) need a core with `Storage.relink_file/3` and are skipped on the Hex one; the "core cannot do it" test runs only there. Their snapshots are full copies, made through a `:storage_module` without `link_copy/3`, and set `status: "active"` by hand, as the processing job does in production.

**Attachments need a core with hidden system libraries** (2.64.0 and later, what `mix.exs` requires). The Hex-resolved core runs the suite green with the tests that need `link_copy/3`, managed libraries or `relink_file/3` skipped: run the whole suite **both** ways (with `PHOENIX_KIT_PATH` set, and without). The old-core `{:error, :storage_unsupported}` path is covered through the `:storage_libraries` test seam.

Test URLs are `/en/admin/inbox…` — `Routes.path/1` defaults to no prefix in tests and admin paths always carry the default locale.

## Known gaps / deliberate omissions in 0.1.0

Not oversights — decided against for the first release:

- **No tab inside `/profile/settings`.** Core's profile settings tabs are a fixed list; the user's mail settings live on their own page, reached from the avatar menu.
- **No threaded reading pane.** The data supports it (`thread_uuid`, `list_thread/1`); the UI shows one message at a time.
- **No user-defined labels/folders.** Folders are a fixed six-value column.
- **Downloads copy the whole file first.** `Web.AttachmentController` reads the snapshot through core's `Storage.retrieve_file/1` into a temporary file and sends that — core has no streaming read. A 200 MB attachment is a 200 MB temporary file per download.
- **A lost reply to COMMIT.** If the connection drops after the database committed a send but before the reply arrived, the send counts as failed and its snapshots are released; `release/1` keeps every file a row names, so only a commit not yet visible to its query could lose its files — very unlikely, not handled.
- **No full-text index.** Search is `ILIKE`. `pg_trgm` is already a core-required extension, so a trigram index is a cheap V02 when volume justifies it.

## Versioning & Releases

Version must be updated in **three** places:

1. `mix.exs` — `@version`
2. `lib/phoenix_kit_inbox.ex` — `def version`
3. `test/phoenix_kit_inbox_test.exs` — the version compliance test

### Release checklist

1. Update the three version locations
2. Add a `CHANGELOG.md` entry
3. `mix precommit` — zero warnings/errors
4. Commit: `"Bump version to x.y.z"`
5. Push and **verify the push succeeded** before tagging
6. `git tag x.y.z && git push origin x.y.z` (bare version, no `v` prefix)
7. `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**Never tag before everything is committed and pushed** — tags are immutable pointers.

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

## Pull Requests

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`, named `{AGENT}_REVIEW.md`.

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `IMPROVEMENT - HIGH`, `IMPROVEMENT - MEDIUM`, `NITPICK`.
