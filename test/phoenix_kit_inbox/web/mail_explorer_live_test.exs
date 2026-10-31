defmodule PhoenixKitInbox.Web.MailExplorerLiveTest do
  @moduledoc """
  The explorer on a page that called `MailExplorer.attach/3`: it follows new
  letters, delivery statuses and changes of access without a reload, and
  leaves alone what does not concern it.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Test.Repo
  alias PhoenixKitInbox.Web.Components.MailExplorer

  @order %{kind: "order", ref: "o-1"}
  @other %{kind: "order", ref: "o-2"}
  @external ["inbox", "inbox.send_external"]

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})

    %{
      admin: admin,
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      desk: desk,
      alice_scope: scope_for(alice),
      bob_scope: scope_for(bob)
    }
  end

  defp mail(ctx, from, to, attrs, opts \\ []) do
    scope = Map.fetch!(ctx, :"#{from}_scope")
    mailbox = Map.fetch!(ctx, :"#{from}_mb")

    {:ok, message} =
      Messages.send_message(
        scope,
        mailbox,
        Map.merge(%{"to" => to, "subject" => "Subject", "body" => "Body"}, attrs),
        opts
      )

    message
  end

  defp handle(user), do: "@" <> user.username

  defp open(ctx, conn, scope \\ nil) do
    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => MailExplorer,
        "assigns" => %{id: "demo", scope: scope || ctx.alice_scope, filter: [@order]},
        "attach" => {"demo", [@order]},
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  # The update arrives through PubSub and a send_update: wait for it.
  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the page did not change")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  # Waits until everything sent to the page so far, and the updates that
  # caused, has been handled.
  defp settle(view) do
    render(view)
    render(view)
  end

  test "new linked message appears without reload", %{conn: conn} = ctx do
    view = open(ctx, conn)
    refute has_element?(view, "[id^=mail-row-demo-]")

    letter = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Fresh"}, links: [@order])
    eventually(fn -> has_element?(view, "#mail-row-demo-#{letter.uuid}") end)

    # A letter linked by hand later is picked up the same way.
    plain = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Plain"})
    settle(view)
    refute has_element?(view, "#mail-row-demo-#{plain.uuid}")

    {:ok, _} =
      PhoenixKitInbox.Links.link(ctx.alice_scope, plain.uuid, "order", "o-1",
        can_link?: fn _, _, _ -> true end
      )

    eventually(fn -> has_element?(view, "#mail-row-demo-#{plain.uuid}") end)

    # And an unlinked one goes.
    :ok =
      PhoenixKitInbox.Links.unlink(ctx.alice_scope, plain.uuid, "order", "o-1",
        can_link?: fn _, _, _ -> true end
      )

    eventually(fn -> not has_element?(view, "#mail-row-demo-#{plain.uuid}") end)
  end

  describe "an external email" do
    setup :outbound_setup

    # Alice may send externally, as a common sender.
    setup ctx do
      senders = grant_role!(ctx.alice, @external)
      smtp = mail_integration_fixture(:system, username: "noreply@company.test")

      {:ok, common} =
        Identities.create_shared(scope_for(ctx.admin, ["inbox", "inbox.manage_shared"]), %{
          "label" => "Common",
          "integration_uuid" => smtp
        })

      %{sender_scope: scope_for(ctx.alice, @external, [senders]), common: common}
    end

    defp send_external(ctx, mailbox, identity \\ nil) do
      Messages.send_message(
        ctx.sender_scope,
        mailbox,
        %{
          "to" => "client@example.com",
          "subject" => "Offer",
          "body" => "Hello",
          "identity_uuid" => (identity || ctx.common).uuid
        },
        links: [@order]
      )
    end

    defp status_of(view, message) do
      view
      |> element("#mail-letter-demo-#{message.uuid} [id^=mail-external-demo-]")
      |> render()
    end

    test "external status change updates the row", %{conn: conn} = ctx do
      :ok = External.subscribe(ctx.alice_mb.uuid)
      outbound_result({:error, :smtp_down})
      {:ok, message} = send_external(ctx, ctx.alice_mb)
      await_external(message.uuid)

      view = open(ctx, conn, ctx.sender_scope)
      assert status_of(view, message) =~ "not delivered"

      # A retry is offered while the email log says nothing went out.
      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid}, "failed")
      outbound_result({:ok, %{id: "ok"}})

      assert {:ok, :pending} =
               Messages.retry_external(ctx.sender_scope, ctx.alice_mb, message.uuid)

      eventually(fn -> status_of(view, message) =~ "sent" end)
      refute status_of(view, message) =~ "not delivered"
      assert Enum.all?(External.list(message.uuid), &(&1.status == "sent"))
    end

    test "the status of a letter from a mailbox granted after the page opened",
         %{conn: conn} = ctx do
      view = open(ctx, conn, ctx.sender_scope)

      admin_scope = scope_for(ctx.admin, ["inbox", "inbox.manage_shared"])
      {:ok, _} = Mailboxes.grant_access(admin_scope, ctx.desk, ctx.alice.uuid, "write")
      settle(view)

      # The transport waits until the test lets it go, so "sending…" is what
      # the page shows first.
      test = self()

      outbound_result(fn _email, _integration, _opts ->
        send(test, {:waiting, self()})

        receive do
          :go -> {:ok, %{id: "ok"}}
        end
      end)

      {:ok, bound} =
        Identities.create_shared(scope_for(ctx.admin, ["inbox", "inbox.manage_shared"]), %{
          "label" => "Desk",
          "integration_uuid" => ctx.common.integration_uuid,
          "mailbox_uuid" => ctx.desk.uuid
        })

      {:ok, message} = send_external(ctx, ctx.desk, bound)
      eventually(fn -> has_element?(view, "#mail-letter-demo-#{message.uuid}") end)
      eventually(fn -> status_of(view, message) =~ "sending" end)

      assert_receive {:waiting, transport}
      send(transport, :go)

      eventually(fn ->
        status_of(view, message) =~ "sent" and not (status_of(view, message) =~ "sending")
      end)
    end
  end

  test "access change refreshes the list", %{conn: conn} = ctx do
    to_desk = mail(ctx, :bob, ctx.desk.address, %{"subject" => "To the desk"}, links: [@order])
    view = open(ctx, conn)
    refute has_element?(view, "#mail-row-demo-#{to_desk.uuid}")

    admin_scope = scope_for(ctx.admin, ["inbox", "inbox.manage_shared"])
    {:ok, _} = Mailboxes.grant_access(admin_scope, ctx.desk, ctx.alice.uuid, "read")
    eventually(fn -> has_element?(view, "#mail-row-demo-#{to_desk.uuid}") end)

    :ok = Mailboxes.revoke_access(admin_scope, ctx.desk, ctx.alice.uuid)
    eventually(fn -> not has_element?(view, "#mail-row-demo-#{to_desk.uuid}") end)
  end

  test "mail of a mailbox granted after the page opened is followed too", %{conn: conn} = ctx do
    view = open(ctx, conn)
    admin_scope = scope_for(ctx.admin, ["inbox", "inbox.manage_shared"])
    {:ok, _} = Mailboxes.grant_access(admin_scope, ctx.desk, ctx.alice.uuid, "read")
    settle(view)

    letter = mail(ctx, :bob, ctx.desk.address, %{"subject" => "After the grant"}, links: [@order])
    eventually(fn -> has_element?(view, "#mail-row-demo-#{letter.uuid}") end)
  end

  test "unrelated messages ignored", %{conn: conn} = ctx do
    kept = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Kept"}, links: [@order])
    view = open(ctx, conn)
    assert has_element?(view, "#mail-row-demo-#{kept.uuid}")

    queries = :counters.new(1, [])
    page = view.pid
    handler = {:count_page_queries, System.unique_integer()}

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measure, _meta, {counter, pid} ->
          if self() == pid, do: :counters.add(counter, 1, 1)
        end,
        {queries, page}
      )

    try do
      # A letter about another object, and the status of a letter that is not
      # on the page: neither makes the page read anything.
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Elsewhere"}, links: [@other])
      send(page, {:inbox_external_updated, Ecto.UUID.generate()})
      settle(view)

      assert :counters.get(queries, 1) == 0
    after
      :telemetry.detach(handler)
    end

    assert has_element?(view, "#mail-row-demo-#{kept.uuid}")
    assert length(Regex.scan(~r/id="mail-row-demo-/, render(view))) == 1
  end
end
