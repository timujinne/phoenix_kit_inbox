defmodule PhoenixKitInbox.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_inbox"

  def project do
    [
      app: :phoenix_kit_inbox,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "Internal mailbox module for PhoenixKit — user and shared mailboxes, compose/send, folders",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitInbox",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitInbox.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitInbox.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_EMAILS_PATH=../phoenix_kit_emails. Unset => the published pin,
  # so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, RepoHelper, and
      # the migration helpers this module's own versioned migrations call into
      # (PhoenixKit.Migrations.Postgres.Helpers). 2.16 is the first release
      # with everything used here: sub_permissions and Scope.can?/2 (1.7.194),
      # the before_user_delete/1 callback (2.4.0), Activity.log permanent:
      # (2.16.0).
      pk_dep(:phoenix_kit, "~> 2.16"),

      # LiveView for the admin mailbox UI.
      {:phoenix_live_view, "~> 1.1"},

      # Ecto for the module-owned schemas and migrations.
      {:ecto_sql, "~> 3.10"},

      # NOTE: phoenix_kit_emails is a SOFT dependency — it is deliberately NOT
      # listed here. `PhoenixKitInbox.Notify` guards every call with
      # `Code.ensure_loaded?/1`, so hosts that also run phoenix_kit_emails get
      # outbound email notifications for free and hosts that don't are
      # unaffected. Adding a hard dep here would couple the two release cycles.

      # Optional: add ex_doc for generating documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # HTML parser for Phoenix.LiveViewTest in LiveView smoke tests
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitInbox",
      # Tags in this repo are bare version numbers, not v-prefixed — a "v" ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: @version
    ]
  end
end
