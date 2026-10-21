# PhoenixKitInbox

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Internal mailbox for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — a webmail-shaped inbox for messages between the users of your application. Personal and shared mailboxes, folders, compose/reply/forward, drafts, per-recipient read state, and an admin UI that looks like the mail client your users already know.

## What it is, and isn't

Inbox is **internal**. Messages are addressed to mailboxes inside your application, stored in your database, and read in your admin UI. Nothing is fetched over IMAP and nothing is relayed to the outside world.

What it *can* do, when the host also runs [`phoenix_kit_emails`](https://github.com/BeamLabEU/phoenix_kit_emails), is send a short "you have a new message" nudge to a recipient's real email address so they know to come look. That's a **soft** integration — `phoenix_kit_emails` is not in this package's `mix.exs`, the call is guarded with `Code.ensure_loaded?/1`, and the whole thing is off by default behind a setting.

Neighbouring modules, so you pick the right one:

| You want | Use |
|---|---|
| Users messaging each other in-app | **this module** |
| Outbound campaigns / mailing lists | `phoenix_kit_newsletters` |
| Delivery tracking, bounces, SES/SQS | `phoenix_kit_emails` |
| Customer tickets with statuses and SLAs | `phoenix_kit_customer_support` |

## Features

- **Personal mailboxes** — one per user, created lazily on first visit; no signup hook, works for users who predate the install
- **Shared mailboxes** — `support@`, `sales@`, … with per-user `read` / `write` / `admin` grants
- **Six folders** — Inbox, Sent, Drafts, Spam, Trash, Archive
- **Per-recipient state** — seen/unseen, starred, and folder are per mailbox, so marking a group thread read doesn't mark it read for everyone else
- **Compose, reply, forward** — with quoted bodies, `Re:`/`Fwd:` subjects, and inherited threading
- **Drafts** — saved as real messages and *promoted* on send, so the uuid stays stable
- **Search** — case-insensitive over subject and body
- **Threading** — replies carry their root's `thread_uuid`; `list_thread/1` returns a conversation in one indexed query
- **Notifications** — new messages raise an activity event, which core turns into an in-app notification with a deep link
- **Module-owned migrations** — tables ship and version here, not in core
- **Auto-discovery** — implements `PhoenixKit.Module`; PhoenixKit finds it at startup with zero config

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_inbox, "~> 0.2"}
  ]
end
```

```bash
mix deps.get
mix phoenix_kit.update   # generates + runs the host migration for this module
```

Then enable **Inbox** on the admin Modules page (or call `PhoenixKitInbox.enable_system/0`). The tab appears in the sidebar; routes are generated at compile time from `admin_tabs/0`.

## Data model

Four tables. The split that matters is **message vs. delivery**: a message body is stored once, and each recipient mailbox gets its own delivery row carrying that mailbox's folder/seen/starred state. It's how every webmail works, and it's why "mark as read" doesn't leak across recipients.

```
phoenix_kit_inbox_mailboxes          one per user (kind: "user") + shared ones (kind: "shared")
 └─ phoenix_kit_inbox_mailbox_grants who may read/write/administer a mailbox they don't own

phoenix_kit_inbox_messages           subject, body, thread_uuid, parent_uuid, sender  (stored ONCE)
 └─ phoenix_kit_inbox_deliveries     one row per recipient mailbox: folder, seen_at, starred
```

All primary keys are UUIDv7 and every schema carries `use PhoenixKit.SchemaPrefix`, so named-schema (`--prefix`) installs work.

## Migrations live here, not in core

Older PhoenixKit modules shipped their DDL inside core's versioned chain (the V90+ scheme). Inbox follows the newer pattern already used by `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`, and `phoenix_kit_stats`:

- `PhoenixKitInbox.Migrations` is the coordinator, returned from `migration_module/0`
- `PhoenixKitInbox.Migrations.V01` creates the tables; `V02` makes a user's deletion keep their mailboxes and every message (owner `ON DELETE SET NULL`, mailbox references `RESTRICT`) and makes shared addresses unique regardless of case. Shipped versions are immutable
- Version is tracked in a `COMMENT ON TABLE` on `phoenix_kit_inbox_mailboxes`, so the coordinator can tell "not installed" from "installed at V1"
- `mix phoenix_kit.update` discovers the coordinator, compares versions, and generates the host migration

Nothing has to be released in `phoenix_kit` for this module's schema to change.

### Adding a version

1. Write `lib/phoenix_kit_inbox/migrations/vNN.ex` with `up/1` and `down/1`
2. Bump `@current_version` in `PhoenixKitInbox.Migrations` and add the `apply_step/3` clauses for it
3. **Never edit a shipped version module** — hosts already past it will not re-run it

New SQL must stay prefix-safe: bare index names on `CREATE`, schema-anchored existence checks, `Helpers.uuid_v7_call/1` for the UUID default. See core's AGENTS.md, "Prefix-safe migrations".

## Usage

### Mailboxes

```elixir
alias PhoenixKitInbox.Mailboxes

# Personal mailbox — created on first call, returned thereafter
{:ok, mailbox} = Mailboxes.ensure_user_mailbox(current_user)

# Shared mailbox + grants — needs inbox.manage_shared on the caller's scope
{:ok, support} = Mailboxes.create_shared_mailbox(scope, %{
  name: "Customer Support",
  address: "support@example.com"
})

{:ok, _} = Mailboxes.grant_access(scope, support, teammate.uuid, "write")   # admin on support

Mailboxes.access_level(support, owner.uuid)           #=> "admin"  (ownership implies admin)
Mailboxes.authorize(support, teammate.uuid, "write")  #=> :ok
Mailboxes.list_accessible_mailboxes(user.uuid)        #=> personal first, then shared
```

### Sending

```elixir
alias PhoenixKitInbox.Messages

{:ok, message} = Messages.send_message(scope, from_mailbox, %{
  "to" => "@bob, support",              # @username, email, or shared mailbox; comma separated
  "cc" => "carol@example.com",
  "subject" => "Quarterly numbers",
  "body" => "Attached below."
})
```

The sender needs `write` on `from_mailbox` and, in the scope form, the `"inbox"` permission. The older `send_message(from_mailbox, sender_user_uuid, attrs)` form still works and checks the same grant.

The whole send is one `Ecto.Multi`: recipients resolve, the message is written, and deliveries fan out — or none of it happens. A recipient that doesn't resolve fails the send with `{:error, {:unknown_recipients, ["typo@example.com"]}}` rather than being silently dropped; a term naming two people fails with `{:error, {:ambiguous_recipients, [...]}}`.

Only **members** can be addressed or suggested: by default a user any of whose roles carries `"inbox"` or `"*"`, or the Owner. A host replaces the rule with:

```elixir
config :phoenix_kit_inbox, recipient_filter: {MyApp.Inbox, :addressable?}  # (user) -> boolean
```

Each send records a snapshot of the sender and recipients in the message's `metadata` and one permanent `inbox.message_sent` activity (counts only).

### Reading and filing

```elixir
Messages.list_folder(mailbox.uuid, "inbox", limit: 50, search: "invoice", unseen_only: true)
Messages.count_folder(mailbox.uuid, "inbox")
Messages.fetch_for_mailbox(mailbox.uuid, message_uuid)   # scoped — never reads someone else's mail
Messages.list_thread(message.thread_uuid)

Messages.mark_seen(scope, mailbox, message_uuid)        # read on the mailbox
Messages.toggle_star(scope, mailbox, message_uuid)      # read
Messages.move_to_folder(scope, mailbox, message_uuid, "archive")   # write
Messages.purge(scope, mailbox, message_uuid)   # write; removes only THIS mailbox's copy
```

### Drafts

```elixir
{:ok, draft} = Messages.save_draft(scope, mailbox, %{"to" => "@bob", "subject" => "WIP"})
Messages.draft_recipients(draft)   #=> %{"to" => "@bob", "cc" => "", "bcc" => ""}
{:ok, draft} = Messages.save_draft(scope, mailbox, %{"uuid" => draft.uuid, "body" => "more"})

# Sending promotes the same row — same uuid, status flips to "sent"
{:ok, sent} = Messages.send_message(scope, mailbox, %{
  "uuid" => draft.uuid, "to" => "bob@example.com", "subject" => "WIP"
})
```

## Settings

| Key | Default | What it does |
|---|---|---|
| `inbox_enabled` | `false` | Module on/off (the admin Modules page toggle) |
| `inbox_email_nudges_enabled` | `false` | Send a "new message" email to recipients — needs `phoenix_kit_emails` |

```elixir
PhoenixKitInbox.set_email_nudges(true)
PhoenixKitInbox.Notify.email_nudges_available?()  #=> is phoenix_kit_emails actually installed?
```

## Permissions

The module key is `"inbox"`. Two levels:

1. **Module permission** — `Scope.has_module_access?(scope, "inbox")` decides who can open Inbox at all. Managed in the admin roles/permissions matrix like every other module. Two sub-permissions add capabilities, checked by the context functions with `Scope.can?/2`: `inbox.manage_shared` (create shared mailboxes, set addresses) and `inbox.send_external` (reserved for sending to outside addresses).
2. **Mailbox grants** — decide which mailboxes a user sees once inside, and what they may do there (every function that changes something takes the caller's scope and checks both gates itself). Owning a mailbox implies `"admin"` on it; everything else needs a row in `phoenix_kit_inbox_mailbox_grants`.

Levels are ordered `read < write < admin`:

| Level | Can |
|---|---|
| `read` | open the mailbox, read, mark seen/starred |
| `write` | the above, plus compose/send as the mailbox, move, trash |
| `admin` | the above, plus manage the mailbox's grants and archive it |

## URLs

All navigation goes through `PhoenixKitInbox.Paths`, never a hardcoded string — the host's URL prefix and locale are applied there.

| Path | LiveView |
|---|---|
| `/admin/inbox` | `Web.InboxLive` — folders, list, reading pane |
| `/admin/inbox?folder=sent&message=<uuid>` | same LiveView, patched |
| `/admin/inbox/compose` | `Web.ComposeLive` (also `?reply_to=`, `?forward=`, `?draft=`) |
| `/admin/inbox/mailboxes` | `Web.MailboxesLive` — shared mailboxes and grants |

Folder, message, search, and page are query params, not path segments, so the whole mailbox stays one LiveView: switching folders is a `push_patch`, not a remount.

## Local cross-repo development

`phoenix_kit` resolves from Hex by default. To build or test against a local checkout, export `<APP>_PATH`:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*` dep into a `path:` tuple, a committed path dep ships a broken package.

## Testing

```bash
mix test.setup   # createdb; the test helper runs core's migrations + ours on every boot
mix test
```

Integration tests auto-exclude via the `:integration` tag when PostgreSQL isn't reachable; unit tests still run. The suite applies this module's migrations through `PhoenixKitInbox.Test.Migration` — the same coordinator a real host runs — so it can't pass against a schema that differs from what installs get.

## Pre-commit

```bash
mix precommit   # compile --warnings-as-errors + deps.unlock --check-unused + hex.audit + format + credo --strict + dialyzer
```

## License

MIT — see [LICENSE](LICENSE).
