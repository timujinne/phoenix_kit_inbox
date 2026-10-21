defmodule PhoenixKitInbox.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitInbox.Web.HelloLiveTest do
        use PhoenixKitInbox.LiveCase

        test "renders the overview page", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/inbox")
          assert html =~ "Inbox Plugin"
        end
      end

  ## Scope assigns

  Inbox's LiveViews read `socket.assigns[:phoenix_kit_current_scope]`
  and `socket.assigns[:phoenix_kit_current_user]` to decide what UI to
  show (the "Log demo event" button is hidden for users without the
  `inbox` permission). Tests can plug a fake scope via
  `with_scope/2` (a Plug-style helper that sets `:phoenix_kit_current_scope`
  on the conn before `live/2`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitInbox.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitInbox.ActivityLogAssertions

      import PhoenixKitInbox.DataCase,
        only: [
          user_fixture: 0,
          user_fixture: 1,
          enable_inbox!: 0,
          shared_mailbox_fixture: 2,
          grant_fixture: 3,
          scope_for: 1,
          scope_for: 2,
          storage_setup: 1,
          stored_file_fixture: 2,
          stored_file_fixture: 3,
          files_in_library: 1
        ]

      import PhoenixKitInbox.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitInbox.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Inbox's LiveView calls `Scope.has_module_access?(scope,
  "inbox")` and `Scope.can_access_admin_area?(scope)` — both are pattern-matched
  on `%PhoenixKit.Users.Auth.Scope{}`, so a plain map won't satisfy
  them. The struct's `:cached_permissions` field is a `MapSet` that
  `has_module_access?/2` checks via membership, and `:cached_roles` /
  `:authenticated?` drive `admin?/1`.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4 (good enough for tests)
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role atoms; `[:owner]` makes `admin?/1` true
    * `:permissions` — list of module-key strings; `["inbox"]`
      grants the demo button
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope(permissions: ["inbox"]))
      {:ok, _view, html} = live(conn, "/en/admin/inbox")
      assert html =~ "Log demo event"
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, [:owner])
    permissions = Keyword.get(opts, :permissions, ["inbox"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: MapSet.new(roles),
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the test
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/inbox")
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
