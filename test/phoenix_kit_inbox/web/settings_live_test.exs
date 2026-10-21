defmodule PhoenixKitInbox.Web.SettingsLiveTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKit.Integrations
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Schemas.Identity
  alias PhoenixKitInbox.Signatures
  alias PhoenixKitInbox.Test.Repo

  @path "/en/admin/inbox/settings"
  @manage ["inbox", "inbox.manage_shared"]

  setup %{conn: conn} do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    system_smtp = mail_integration_fixture(:system, username: "desk@company.test")

    %{conn: conn, admin: admin, alice: alice, desk: desk, system_smtp: system_smtp}
  end

  defp as(conn, user, permissions), do: put_test_scope(conn, scope_for(user, permissions))

  describe "without inbox.manage_shared" do
    test "shows no form", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), @path)

      refute has_element?(view, "#shared-identities")
      refute has_element?(view, "#shared-signatures")
    end

    test "a forged check changes no shared sender", ctx do
      {:ok, identity} =
        Identities.create_shared(scope_for(ctx.admin, @manage), %{
          "label" => "Common",
          "integration_uuid" => ctx.system_smtp
        })

      :ok = Integrations.remove_connection(ctx.system_smtp, nil, owner: :system)
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), @path)

      render_click(view, "ident_check", %{"uuid" => identity.uuid})

      assert Repo.get(Identity, identity.uuid).status == "active"
    end

    test "a forged sender submit creates nothing", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), @path)

      render_click(view, "ident_new", %{})

      render_submit(view, "ident_save", %{
        "identity" => %{"label" => "Forged", "integration_uuid" => ctx.system_smtp}
      })

      assert has_element?(view, "#flash-error")
      assert Repo.aggregate(Identity, :count) == 0
    end

    test "a forged signature submit for a shared mailbox writes nothing", ctx do
      grant_fixture(ctx.desk, ctx.alice, "admin")
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), @path)

      render_click(view, "sig_mailbox", %{"mailbox" => ctx.desk.uuid})
      render_click(view, "sig_new", %{})
      render_submit(view, "sig_save", %{"signature" => %{"label" => "Forged"}})

      assert Signatures.list(ctx.desk.uuid) == []
    end
  end

  describe "with inbox.manage_shared" do
    test "a shared sender is bound to a mailbox and listed with its From address", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view |> element("#shared-identities button[phx-click='ident_new']") |> render_click()

      view
      |> form("#shared-identities-form", %{
        "identity" => %{
          "label" => "Desk",
          "from_name" => "Company Desk",
          "integration_uuid" => ctx.system_smtp,
          "mailbox_uuid" => ctx.desk.uuid
        }
      })
      |> render_submit()

      assert [%{identity: %Identity{mailbox_uuid: mailbox_uuid} = identity}] =
               Identities.list_shared(scope_for(ctx.admin, @manage))

      assert mailbox_uuid == ctx.desk.uuid
      assert has_element?(view, "#identity-#{identity.uuid}", "desk@company.test")
      assert has_element?(view, "#identity-#{identity.uuid}", "Desk")
    end

    test "a personal connection is not offered, and refused when forged", ctx do
      personal = mail_integration_fixture({:user, ctx.admin.uuid}, username: "mine@own.test")
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view |> element("#shared-identities button[phx-click='ident_new']") |> render_click()
      refute has_element?(view, "#shared-identities-form option[value='#{personal}']")

      render_submit(view, "ident_save", %{
        "identity" => %{"label" => "Mine", "integration_uuid" => personal}
      })

      assert has_element?(view, "#flash-error")
      assert Repo.aggregate(Identity, :count) == 0
    end

    test "a sender whose connection is gone is marked broken", ctx do
      {:ok, identity} =
        Identities.create_shared(scope_for(ctx.admin, @manage), %{
          "label" => "Common",
          "integration_uuid" => ctx.system_smtp
        })

      :ok = Integrations.remove_connection(ctx.system_smtp, nil, owner: :system)
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)
      assert Repo.get(Identity, identity.uuid).status == "active"

      view
      |> element("#identity-#{identity.uuid} button[phx-click='ident_check']")
      |> render_click()

      assert has_element?(view, "#identity-#{identity.uuid} .badge-error", "Broken")
      assert Repo.get(Identity, identity.uuid).status == "broken"
    end

    test "signatures of an administered shared mailbox are written here", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view |> element("#shared-signatures button[phx-click='sig_new']") |> render_click()

      view
      |> form("#shared-signatures-form", %{
        "signature" => %{"label" => "Desk", "body" => "The Desk", "is_default" => "true"}
      })
      |> render_submit()

      assert [%{label: "Desk", is_default: true}] = Signatures.list(ctx.desk.uuid)
    end

    test "a mailbox the viewer does not administer can't be picked", ctx do
      other = shared_mailbox_fixture(ctx.alice, %{name: "Alice's"})
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      refute has_element?(view, "#signature-mailbox-form option[value='#{other.uuid}']")
      render_click(view, "sig_mailbox", %{"mailbox" => other.uuid})
      render_click(view, "sig_new", %{})
      render_submit(view, "sig_save", %{"signature" => %{"label" => "Forged"}})

      assert Signatures.list(other.uuid) == []
    end
  end
end
