# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKit module providing an **internal mailbox** — an in-app email client for messages between the users of the host application. Implements the `PhoenixKit.Module` behaviour for auto-discovery.

Three admin pages:

- **Inbox** (`Web.InboxLive`) — three-pane webmail: folder sidebar, message list, reading pane
- **Compose** (`Web.ComposeLive`) — new / reply / forward / drafts (hidden tab, reached from the New message button)
- **Mailboxes** (`Web.MailboxesLive`) — shared mailboxes and who can use them

## Scope boundary — read this before adding features

Inbox is **internal**. Messages address mailboxes inside the app; nothing is fetched over IMAP, nothing is relayed out. This was an explicit product decision, not an oversight. Before adding transport, check whether the request actually belongs in a neighbour:

| Concern | Module |
|---|---|
| Users messaging each other | this one |
| Outbound campaigns, mailing lists | `phoenix_kit_newsletters` |
| Delivery tracking, bounces, SES/SQS | `phoenix_kit_emails` |
| Customer tickets, statuses, SLAs | `phoenix_kit_customer_support` |

The one outward-facing thing here is the **email nudge** in `PhoenixKitInbox.Notify` — a "you have a new message" email to the recipient's real address. It is a **soft** integration and must stay one:

- `phoenix_kit_emails` is deliberately **not** in `mix.exs`
- the call goes through `apply/3` behind `Code.ensure_loaded?/1` + `function_exported?/3` (a literal call is a `--warnings-as-errors` failure, and core uses the same idiom in `PhoenixKit.Mailer`)
- it is off by default behind the `inbox_email_nudges_enabled` setting
- it fires **after** the send transaction commits, and every failure is rescued and logged — a notification must never unsend a committed message

## Database & Migrations

**This module owns its DDL.** That is the point of the module, architecturally. Older PhoenixKit modules put their tables in core's versioned chain (V90+), which meant a module schema change needed a core release. Inbox follows the newer self-contained pattern used by `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`, and `phoenix_kit_stats`.

- `PhoenixKitInbox.Migrations` — coordinator, returned from `migration_module/0`
- `PhoenixKitInbox.Migrations.V01` — the tables; `V02` — deletion-safe foreign keys and unique shared addresses. **Immutable once shipped**
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
 └─ phoenix_kit_inbox_deliveries      one per recipient mailbox: folder, seen_at, starred
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

## Access control

Two gates, and they are different questions:

1. **Module permission** — `Scope.has_module_access?(scope, "inbox")`. Can this user open Inbox at all? Checked in every LiveView's `mount/3` and re-checked in `handle_params/3`. Sub-permissions (`inbox.manage_shared`, `inbox.send_external`) are checked with `Scope.can?/2` **in the context function** that needs them, so those functions take the caller's `%Scope{}` (`create_shared_mailbox/2`, `update_mailbox/3`).
2. **Mailbox grants** — `Mailboxes.authorize(mailbox, user_uuid, "write")`. Which mailboxes can they see once inside? Ownership short-circuits to `"admin"`, so an owner never has a grant row for their own mailbox.

**Every function that changes data takes the caller's `%Scope{}` and checks both gates itself** through `Mailboxes.authorize_scope/3` (which re-reads the mailbox, so a stale or hand-built struct grants nothing): seen/star need `read`; drafts, move, purge and sending need `write`; grants, archive/restore and `update_mailbox/3` need `admin`. LiveViews pass `socket.assigns.scope` and only render the outcome. The one exception is `Messages.send_message/3` (mailbox + sender uuid), kept for hosts and checked against the grants. Sending refuses an archived mailbox. A `parent_uuid` (send or draft) is kept only if the sender can read that message — a mailbox they own or are granted holds a copy, or sent it; otherwise it is dropped and the message starts its own thread. A caller-supplied `thread_uuid` is never used.

Levels are ordered `read < write < admin` via `MailboxGrant.covers?/2`.

**Re-check on every param change, not just at mount** — a user can hand-edit `?mailbox=` in the URL. `InboxLive.apply_params/2` and the `mutate/3` helper both do.

## Code Organization

```
lib/phoenix_kit_inbox.ex                  # PhoenixKit.Module callbacks
lib/phoenix_kit_inbox/
├── paths.ex                              # ALL URL building — never hardcode a path
├── errors.ex                             # error atom -> gettext string
├── mailboxes.ex                          # mailbox lifecycle + access control
├── members.ex                            # recipient circle (who is addressable)
├── messages.ex                           # compose, send, list, file
├── notify.ex                             # activity log + optional email nudge
├── migrations.ex                         # version coordinator
├── migrations/v01.ex                      # immutable
├── schemas/{mailbox,mailbox_grant,message,delivery}.ex
└── web/{inbox_live,compose_live,mailboxes_live}.ex
```

- **Contexts own every query.** LiveViews call context functions; no `Repo` or `Ecto.Query` in `web/`.
- **`render/1` is a flat dispatch** over private function components, each declaring `attr` for what it reads (the section-decomposition pattern from `phoenix_kit_hello_world`'s `ComponentsLive`). Don't pass whole `assigns` into a section.
- **`patch_to/2` in `InboxLive`** takes only what changes and reads the rest off the socket, then builds the URL via `Paths.inbox/1`. Add a new query param in `Paths.inbox/1` first, then thread it through `patch_to/2` and `apply_params/2`.

## Critical Conventions

- **Module key** `"inbox"` — consistent across `module_key/0`, `permission_metadata/0`, tab `:permission`, notification type key, and settings prefix
- **Tab IDs** prefixed `:admin_inbox`
- **URL paths** use hyphens, never underscores
- **Navigation** always via `PhoenixKitInbox.Paths`, never a relative or hardcoded path. Notification links are the exception: store the **raw** path (`Paths.raw_message_path/2`) because core prefixes stored links itself — a pre-prefixed one double-prefixes.
- **`enabled?/0`** rescues and returns `false`; it runs before the DB is guaranteed up
- **Wrap user-facing strings in gettext** via the local `gettext_str/1` helper (`Gettext.gettext(PhoenixKitWeb.Gettext, ...)`) — including `page_title`, flashes, button labels, empty-state copy
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

- `test/support/data_case.ex` — sandbox + `user_fixture/1`. Inbox's tables have FKs to `phoenix_kit_users`, so a fabricated uuid fails on insert; every mailbox needs a real owner row.
- `test/support/live_case.ex` — `fake_scope/1` + `put_test_scope/2` for permission-gated LiveView tests
- `test/support/test_migration.ex` — wraps `PhoenixKitInbox.Migrations` so `Ecto.Migrator` can run it. The suite applies **the real coordinator**, so it can't pass against a schema that differs from what installs get.
- `test/test_helper.exs` — runs `PhoenixKit.Migration.ensure_current/2` (core's tables, incl. `phoenix_kit_users`) **then** this module's migration. Order matters: our FKs reference core's tables.

Test URLs are `/en/admin/inbox…` — `Routes.path/1` defaults to no prefix in tests and admin paths always carry the default locale.

## Known gaps / deliberate omissions in 0.1.0

Not oversights — decided against for the first release:

- **No user-dashboard tab.** `user_dashboard_tabs/0` exists on the behaviour, but core's `compile_module_admin_routes/0` only collects `:admin_tabs` and `:settings_tabs` — a `user_dashboard_tabs/0` entry gets **no route generated**. Adding one needs a core change first.
- **No attachments.** Needs a storage backend and MIME handling; a V02 table plus upload plumbing.
- **No threaded reading pane.** The data supports it (`thread_uuid`, `list_thread/1`); the UI shows one message at a time.
- **No user-defined labels/folders.** Folders are a fixed six-value column.
- **No full-text index.** Search is `ILIKE`. `pg_trgm` is already a core-required extension, so a trigram index is a cheap V02 when volume justifies it.
- **Grants take a raw user UUID in the admin UI.** A user picker (like `phoenix_kit_calendar`'s participant search) is the obvious next step.

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

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **No AI attribution or `Co-Authored-By` footers.**

## Pull Requests

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`, named `{AGENT}_REVIEW.md`.

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `IMPROVEMENT - HIGH`, `IMPROVEMENT - MEDIUM`, `NITPICK`.
