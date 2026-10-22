defmodule PhoenixKitInbox.Web.SettingsLiveTest do
  use PhoenixKitInbox.LiveCase

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.Role
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Schemas.Identity
  alias PhoenixKitInbox.Schemas.IdentityRole
  alias PhoenixKitInbox.Test.Repo

  @path "/en/admin/settings/inbox"
  @manage ["inbox", "inbox.manage_shared"]

  setup %{conn: conn} do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    system_smtp = mail_integration_fixture(:system, username: "desk@company.test")
    sales = grant_role!(alice, ["inbox", "inbox.send_external"])
    reader = grant_role!(user_fixture(), ["inbox"])

    %{
      conn: conn,
      admin: admin,
      alice: alice,
      desk: desk,
      system_smtp: system_smtp,
      sales: sales,
      reader: reader
    }
  end

  defp role_uuids(identity) do
    Repo.all(
      from(r in IdentityRole, where: r.identity_uuid == ^identity.uuid, select: r.role_uuid)
    )
    |> Enum.sort()
  end

  defp common!(ctx, attrs) do
    {:ok, identity} =
      Identities.create_shared(
        scope_for(ctx.admin, @manage),
        Map.merge(%{"label" => "Common", "integration_uuid" => ctx.system_smtp}, attrs)
      )

    identity
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

    test "a forged edit changes no shared mail and its roles", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})
      {:ok, view, _html} = live(as(ctx.conn, ctx.alice, ["inbox"]), @path)

      render_click(view, "ident_edit", %{"uuid" => identity.uuid})

      render_submit(view, "ident_save", %{
        "identity" => %{"label" => "Forged", "role_uuids" => [ctx.reader.uuid]}
      })

      assert has_element?(view, "#flash-error")
      assert Repo.get(Identity, identity.uuid).label == "Common"
      assert role_uuids(identity) == [ctx.sales.uuid]
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
  end

  describe "with inbox.manage_shared" do
    test "shared mail is all the page holds: no mailbox signatures", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      assert has_element?(view, "#shared-identities")
      refute has_element?(view, "#shared-signatures")
      refute has_element?(view, "#signature-mailbox-form")
    end

    test "shared mail is added with the roles it is open to, and listed", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view
      |> element("#shared-identities button.btn-primary[phx-click='ident_new']")
      |> render_click()

      refute has_element?(view, "#shared-identities-form [name='identity[mailbox_uuid]']")
      owner = Repo.get_by!(Role, name: "Owner")
      refute has_element?(view, "#shared-identities-form input[value='#{owner.uuid}']")
      assert has_element?(view, "#shared-identities-form #ident-roles-owner")

      # A role that does not give the right to write externally is offered,
      # with a word on it; one that does is ticked for a new mail.
      assert has_element?(view, "#ident-role-#{ctx.reader.uuid}")
      assert has_element?(view, "#ident-role-#{ctx.reader.uuid}-no-right")
      refute has_element?(view, "#ident-role-#{ctx.sales.uuid}-no-right")
      assert has_element?(view, "#ident-role-#{ctx.sales.uuid}[checked]")
      refute has_element?(view, "#ident-role-#{ctx.reader.uuid}[checked]")

      view
      |> form("#shared-identities-form", %{
        "identity" => %{
          "label" => "Company",
          "from_name" => "Company Ltd",
          "integration_uuid" => ctx.system_smtp,
          "role_uuids" => [ctx.reader.uuid]
        }
      })
      |> render_submit()

      assert [%{identity: %Identity{mailbox_uuid: nil} = identity}] =
               Identities.list_shared(scope_for(ctx.admin, @manage))

      assert role_uuids(identity) == [ctx.reader.uuid]
      assert has_element?(view, "#identity-#{identity.uuid}", "desk@company.test")
      assert has_element?(view, "#identity-#{identity.uuid}", "Company Ltd")
      assert has_element?(view, "#identity-#{identity.uuid}-roles", ctx.reader.name)
    end

    test "no role ticked opens it to nobody", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)
      render_click(view, "ident_new", %{})

      render_submit(view, "ident_save", %{
        "identity" => %{
          "label" => "Closed",
          "integration_uuid" => ctx.system_smtp,
          "role_uuids" => [""]
        }
      })

      assert [%{identity: identity}] = Identities.list_shared(scope_for(ctx.admin, @manage))
      assert role_uuids(identity) == []
    end

    test "a forged mailbox is ignored: the form binds nothing", ctx do
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)
      render_click(view, "ident_new", %{})

      render_submit(view, "ident_save", %{
        "identity" => %{
          "label" => "Company",
          "integration_uuid" => ctx.system_smtp,
          "mailbox_uuid" => ctx.desk.uuid,
          "role_uuids" => [ctx.sales.uuid]
        }
      })

      assert [%{identity: %Identity{mailbox_uuid: nil} = identity}] =
               Identities.list_shared(scope_for(ctx.admin, @manage))

      assert role_uuids(identity) == [ctx.sales.uuid]
    end

    test "shared mail is edited: its fields and roles", ctx do
      identity = common!(ctx, %{"from_name" => "Old", "role_uuids" => [ctx.sales.uuid]})
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view
      |> element("#identity-#{identity.uuid} button[phx-click='ident_edit']")
      |> render_click()

      assert has_element?(
               view,
               "#shared-identities-form input[name='identity[label]'][value='Common']"
             )

      assert has_element?(view, "#ident-role-#{ctx.sales.uuid}[checked]")

      view
      |> form("#shared-identities-form", %{
        "identity" => %{
          "label" => "Renamed",
          "from_name" => "New",
          "integration_uuid" => ctx.system_smtp,
          "role_uuids" => [ctx.reader.uuid]
        }
      })
      |> render_submit()

      assert %Identity{label: "Renamed", from_name: "New", mailbox_uuid: nil} =
               Repo.get(Identity, identity.uuid)

      assert role_uuids(identity) == [ctx.reader.uuid]
      assert Repo.aggregate(Identity, :count) == 1
      assert has_element?(view, "#identity-#{identity.uuid}-roles", ctx.reader.name)
    end

    test "editing a mail whose connection is broken keeps that connection", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})
      :ok = Integrations.remove_connection(ctx.system_smtp, nil, owner: :system)
      _working = mail_integration_fixture(:system, username: "other@company.test")
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view
      |> element("#identity-#{identity.uuid} button[phx-click='ident_edit']")
      |> render_click()

      assert has_element?(view, "#shared-identities-form option[value='']")

      view
      |> form("#shared-identities-form", %{"identity" => %{"label" => "Renamed"}})
      |> render_submit()

      assert %Identity{label: "Renamed", integration_uuid: integration} =
               Repo.get(Identity, identity.uuid)

      assert integration == ctx.system_smtp
    end

    test "after a refused save the broken connection is still kept", ctx do
      identity = common!(ctx, %{"role_uuids" => [ctx.sales.uuid]})
      :ok = Integrations.remove_connection(ctx.system_smtp, nil, owner: :system)
      _working = mail_integration_fixture(:system, username: "other@company.test")
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      view
      |> element("#identity-#{identity.uuid} button[phx-click='ident_edit']")
      |> render_click()

      view
      |> form("#shared-identities-form", %{"identity" => %{"label" => String.duplicate("x", 256)}})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#shared-identities-form option[value='']")

      view
      |> form("#shared-identities-form", %{"identity" => %{"label" => "Renamed"}})
      |> render_submit()

      assert %Identity{label: "Renamed", integration_uuid: integration} =
               Repo.get(Identity, identity.uuid)

      assert integration == ctx.system_smtp
    end

    test "a sender bound to a shared mailbox is listed by its mailbox, without roles", ctx do
      bound = common!(ctx, %{"label" => "Desk", "mailbox_uuid" => ctx.desk.uuid})
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      assert has_element?(view, "#identity-#{bound.uuid}-roles", "Desk")

      view
      |> element("#identity-#{bound.uuid} button[phx-click='ident_edit']")
      |> render_click()

      refute has_element?(view, "#ident-role-#{ctx.sales.uuid}")

      view
      |> form("#shared-identities-form", %{"identity" => %{"label" => "Desk 2"}})
      |> render_submit()

      assert %Identity{label: "Desk 2", mailbox_uuid: mailbox_uuid} =
               Repo.get(Identity, bound.uuid)

      assert mailbox_uuid == ctx.desk.uuid
    end

    test "deleting asks first", ctx do
      identity = common!(ctx, %{})
      {:ok, view, _html} = live(as(ctx.conn, ctx.admin, @manage), @path)

      assert has_element?(
               view,
               "#identity-#{identity.uuid} button[phx-click='ident_delete'][data-confirm]"
             )
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
  end
end
