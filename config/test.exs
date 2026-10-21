import Config

# Test database configuration
# Integration tests need a real PostgreSQL database. Create it with:
#   mix test.setup       # createdb + migrate
config :phoenix_kit_inbox, ecto_repos: [PhoenixKitInbox.Test.Repo]

config :phoenix_kit_inbox, PhoenixKitInbox.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_inbox_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/postgres"

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitInbox.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_inbox` has no
# endpoint of its own in production — the host app provides one — so
# this endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_inbox, PhoenixKitInbox.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "inbox-test-salt"],
  server: false,
  url: [host: "localhost"],
  # LiveView upload tests join the upload channel through the endpoint's
  # PubSub; core's internal one is started by test_helper.exs.
  pubsub_server: :phoenix_kit_internal_pubsub,
  render_errors: [formats: [html: PhoenixKitInbox.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
