defmodule PhoenixKitInbox.Migrations do
  @moduledoc """
  Versioned migration coordinator for `phoenix_kit_inbox` — the module returned
  from `PhoenixKitInbox.migration_module/0`.

  **This module owns its DDL.** Historically PhoenixKit modules shipped their
  tables inside core's versioned chain (the V90+ scheme); that put every
  module's schema in one repo and made a module release depend on a core
  release. Inbox follows the newer, self-contained pattern already used by
  `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`, and
  `phoenix_kit_stats`: the tables live here, versioned here, released here.

  `mix phoenix_kit.update` discovers this module, compares
  `migrated_version_runtime/1` (what's installed) against `current_version/0`
  (what the code needs), and when behind generates a host migration whose
  `up/0` calls `up/1` here. Hosts never hand-write a migration, and named-schema
  (`--prefix`) installs are honored.

  ## Version tracking

  Version lives in a `COMMENT ON TABLE` on `phoenix_kit_inbox_mailboxes`,
  mirroring core's own `PhoenixKit.Migrations.Postgres`. It is deliberately not
  a bare "does the table exist?" check — that can't tell "not installed" from
  "installed at V1", which is exactly what a future V2 needs to know.

  Versions:

    * `0` — not installed
    * `1` — mailboxes, mailbox grants, messages, deliveries
    * `2` — a user's deletion keeps their mailboxes and correspondence;
      shared-mailbox addresses unique (case-insensitive)
    * `3` — message attachments
    * `4` — sending identities and mailbox signatures
    * `5` — external recipients of a message, with their delivery status
    * `6` — the roles a shared sender bound to no mailbox is open to

  ## Adding a version

  1. Add `lib/phoenix_kit_inbox/migrations/v02.ex` with `up/1` and `down/1`.
  2. Bump `@current_version` here and add the `2 -> ...` clause to
     `apply_step/2`.
  3. Never edit a shipped version module — hosts already past it will not
     re-run it.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitInbox.Migrations.V01
  alias PhoenixKitInbox.Migrations.V02
  alias PhoenixKitInbox.Migrations.V03
  alias PhoenixKitInbox.Migrations.V04
  alias PhoenixKitInbox.Migrations.V05
  alias PhoenixKitInbox.Migrations.V06

  @initial_version 1
  @current_version 6
  @default_prefix "public"
  @version_table "phoenix_kit_inbox_mailboxes"

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "Run migrations up to (and including) the target version. Migration-context only."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    initial = read_version(repo(), opts.escaped_prefix)

    cond do
      initial == 0 -> change(@initial_version..opts.version, :up, opts)
      initial < opts.version -> change((initial + 1)..opts.version, :up, opts)
      true -> :ok
    end

    :ok
  end

  @doc "Roll back to the target version (default: 0, i.e. everything). Migration-context only."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)
    current = read_version(repo(), opts.escaped_prefix)
    target = Map.get(opts, :version, 0)

    if current > target, do: change(current..(target + 1)//-1, :down, opts)

    :ok
  end

  @doc """
  The version currently installed in the database (0 if absent).
  Migration-context only — reads via `Ecto.Migration.repo/0`.
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.escaped_prefix)
  end

  @doc """
  Runtime-safe version of `migrated_version/1` — uses PhoenixKit's configured
  repo instead of the `Ecto.Migration` `repo()` helper, so it can be called
  from Mix tasks and other non-migration contexts (`mix phoenix_kit.update`).

  Returns `0` on any failure. `catch :exit` matters as much as `rescue` here: a
  dead or unstarted connection pool **exits** rather than raising, and this
  function is called by `mix phoenix_kit.status` / `mix phoenix_kit.update`
  across every installed module — an uncaught exit from one coordinator takes
  the whole report down with it.
  """
  @spec migrated_version_runtime(keyword()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.escaped_prefix)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp change(range, direction, opts) do
    Enum.each(range, &apply_step(direction, &1, opts.prefix))

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, max(Enum.min(range) - 1, 0))
    end
  end

  defp apply_step(:up, 1, prefix), do: V01.up(%{prefix: prefix})
  defp apply_step(:down, 1, prefix), do: V01.down(%{prefix: prefix})
  defp apply_step(:up, 2, prefix), do: V02.up(%{prefix: prefix})
  defp apply_step(:down, 2, prefix), do: V02.down(%{prefix: prefix})
  defp apply_step(:up, 3, prefix), do: V03.up(%{prefix: prefix})
  defp apply_step(:down, 3, prefix), do: V03.down(%{prefix: prefix})
  defp apply_step(:up, 4, prefix), do: V04.up(%{prefix: prefix})
  defp apply_step(:down, 4, prefix), do: V04.down(%{prefix: prefix})
  defp apply_step(:up, 5, prefix), do: V05.up(%{prefix: prefix})
  defp apply_step(:down, 5, prefix), do: V05.down(%{prefix: prefix})
  defp apply_step(:up, 6, prefix), do: V06.up(%{prefix: prefix})
  defp apply_step(:down, 6, prefix), do: V06.down(%{prefix: prefix})

  # Version 0 means "nothing installed" — there is no table left to comment on.
  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute("COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    Helpers.validate_prefix!(opts.prefix)

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end

  defp read_version(repo, escaped_prefix) do
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> read_comment_version(repo, escaped_prefix)
      _ -> 0
    end
  end

  defp read_comment_version(repo, escaped_prefix) do
    version_query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = '#{@version_table}'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo.query(version_query, [], log: false) do
      # The table exists but carries no version comment — it was created by V01
      # before comments were read, so treat it as the initial version.
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> @initial_version
    end
  end
end
