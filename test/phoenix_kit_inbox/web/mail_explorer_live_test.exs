defmodule PhoenixKitInbox.Web.MailExplorerLiveTest do
  @moduledoc """
  The explorer on a page that called `MailExplorer.attach/3`: it follows new
  letters, delivery statuses and changes of access without a reload, and
  leaves alone what does not concern it.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Test.Repo
  alias PhoenixKitInbox.Web.Components.MailExplorer

  @order %{kind: "order", ref: "o-1"}
  @other %{kind: "order", ref: "o-2"}
  @external ["inbox", "inbox.send_external"]
  @pubsub :phoenix_kit_internal_pubsub

  # What the host is asked while a page loads, reported to the test: one
  # message per question, so a reload of an explorer is visible.
  def counting(_scope, kind, ref) do
    send(Application.fetch_env!(:phoenix_kit_inbox, :explorer_test_pid), {:asked, kind, ref})
    true
  end

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

  defp open(ctx, conn, scope \\ nil, extra \\ %{}, page \\ %{}) do
    assigns =
      Map.merge(
        %{id: "demo", scope: scope || ctx.alice_scope, filter: [@order]},
        extra
      )

    session =
      %{
        "component" => MailExplorer,
        "assigns" => assigns,
        "attach" => [{"demo", assigns.filter}] ++ second_attach(page),
        "test_pid" => self()
      }
      |> Map.merge(second(page))

    conn = Plug.Test.init_test_session(conn, session)

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  defp second(%{second_assigns: assigns}), do: %{"second_assigns" => assigns}
  defp second(_page), do: %{}

  defp second_attach(%{second_assigns: assigns}), do: [{assigns.id, assigns.filter}]
  defp second_attach(_page), do: []

  def allow(_scope, _kind, _ref), do: true
  defp counting, do: {:capture, __MODULE__, :counting, 3}

  # The update arrives through PubSub and a send_update, after the hook's
  # moment of gathering: look again until it has, up to a deadline. Each look
  # is a call to the page, answered after the messages sent to it before.
  defp eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until(fun, deadline)
  end

  defp wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the page did not change")

      true ->
        Process.sleep(10)
        wait_until(fun, deadline)
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

  # ── what the page follows ───────────────────────────────────────────────────

  describe "subscriptions of the explorers on a page" do
    defp topics(view), do: Registry.keys(@pubsub, view.pid)

    # The topic Links uses for an object, learned from a process that
    # subscribes to it.
    defp object_topic(%{kind: kind, ref: ref}) do
      Task.async(fn ->
        Links.subscribe(kind, ref)
        Registry.keys(@pubsub, self())
      end)
      |> Task.await()
      |> hd()
    end

    defp drain_asked(acc \\ []) do
      receive do
        {:asked, kind, ref} -> drain_asked([{kind, ref} | acc])
      after
        150 -> Enum.reverse(acc)
      end
    end

    setup do
      Application.put_env(:phoenix_kit_inbox, :explorer_test_pid, self())
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :explorer_test_pid) end)
    end

    test "attaching the same explorer again keeps one subscription per topic",
         %{conn: conn} = ctx do
      view = open(ctx, conn)
      before = topics(view)
      assert object_topic(@order) in before

      for _ <- 1..3, do: send(view.pid, {:test_attach, "demo", [@order]})
      settle(view)

      assert Enum.sort(topics(view)) == Enum.sort(before)
      assert before == Enum.uniq(before)
    end

    test "a changed filter follows the new objects and drops the departed ones",
         %{conn: conn} = ctx do
      view = open(ctx, conn)

      send(view.pid, {:test_attach, "demo", [@other]})
      settle(view)

      assert object_topic(@other) in topics(view)
      refute object_topic(@order) in topics(view)

      # An object another explorer still has stays.
      send(view.pid, {:test_attach, "second", [@other, @order]})
      send(view.pid, {:test_attach, "demo", [@other]})
      settle(view)
      assert object_topic(@order) in topics(view)
    end

    test "detach drops what the explorer alone needed, the last one everything",
         %{conn: conn} = ctx do
      view = open(ctx, conn)
      send(view.pid, {:test_attach, "second", [@other]})
      settle(view)
      assert object_topic(@other) in topics(view)

      send(view.pid, {:test_detach, "second"})
      settle(view)
      refute object_topic(@other) in topics(view)
      assert object_topic(@order) in topics(view)

      send(view.pid, {:test_detach, "demo"})
      settle(view)
      assert topics(view) == []

      # Detaching what is not there is harmless, and attaching again works.
      send(view.pid, {:test_detach, "demo"})
      send(view.pid, {:test_attach, "demo", [@order]})
      settle(view)
      assert object_topic(@order) in topics(view)
    end

    test "the same objects in another order are not a new filter", %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      view = open(ctx, conn, nil, %{filter: [@order, @other], can_link?: counting()})
      drain_asked()

      send(view.pid, {:test_assigns, %{filter: [@other, @order]}})
      settle(view)
      assert drain_asked() == []

      send(view.pid, {:test_assigns, %{filter: [@order]}})
      settle(view)
      assert {"order", "o-1"} in drain_asked()
    end

    test "a link event reloads only the explorers of the object concerned",
         %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "One"}, links: [@order])
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Two"}, links: [@other])

      view =
        open(ctx, conn, nil, %{can_link?: counting()}, %{
          second_assigns: %{
            id: "second",
            filter: [@other],
            can_link?: counting()
          }
        })

      drain_asked()
      fresh = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Three"})
      settle(view)

      {:ok, _} = Links.link(ctx.alice_scope, fresh.uuid, "order", "o-2", can_link?: &allow/3)
      eventually(fn -> has_element?(view, "#mail-row-second-#{fresh.uuid}") end)

      asked = drain_asked()
      assert {"order", "o-2"} in asked
      refute {"order", "o-1"} in asked
    end
  end

  describe "a burst of events" do
    setup do
      Application.put_env(:phoenix_kit_inbox, :explorer_test_pid, self())
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :explorer_test_pid) end)
    end

    defp asks do
      receive do
        {:asked, _kind, _ref} -> [:asked | asks()]
      after
        200 -> []
      end
    end

    test "is one reload", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Kept"}, links: [@order])
      view = open(ctx, conn, nil, %{can_link?: counting()})
      assert length(asks()) >= 1

      for _ <- 1..25 do
        send(view.pid, {:inbox_message_linked, letter.uuid})
        send(view.pid, {:inbox_external_updated, letter.uuid})
        send(view.pid, {:inbox_access_changed, :mailboxes})
      end

      settle(view)
      # One reload asks the host about the one object once.
      assert asks() == [:asked]
    end

    test "the viewer's own link is not read twice", %{conn: conn} = ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})
      view = open(ctx, conn, nil, %{can_link?: counting()})
      asks()

      view |> element("button[phx-click=open_picker]") |> render_click()
      view |> element("#mail-picker-demo button[phx-value-uuid='#{free.uuid}']") |> render_click()
      assert_receive {:inbox_explorer, "demo", {:linked, _}}

      assert has_element?(view, "#mail-row-demo-#{free.uuid}")
      # `Links.link/5` asks the host once, the click's own reload once, and
      # nothing after the event the link caused.
      assert asks() == [:asked, :asked]
    end

    test "events after a reload of the explorer still count", %{conn: conn} = ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})
      view = open(ctx, conn, nil, %{can_link?: counting()})
      asks()

      view |> element("button[phx-click=open_picker]") |> render_click()
      view |> element("#mail-picker-demo button[phx-value-uuid='#{free.uuid}']") |> render_click()
      asks()

      later = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Later"}, links: [@order])
      eventually(fn -> has_element?(view, "#mail-row-demo-#{later.uuid}") end)
    end
  end

  describe "events the page keeps for itself" do
    test "senders changes (not the explorer's) pass on to the page, and read nothing",
         %{conn: conn} = ctx do
      kept = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Kept"}, links: [@order])
      view = open(ctx, conn)
      assert has_element?(view, "#mail-row-demo-#{kept.uuid}")

      {result, queries} =
        page_queries(view, fn ->
          send(view.pid, {:inbox_access_changed, :senders})
          send(view.pid, {:inbox_access_changed, :something_new})
          settle(view)
        end)

      assert result
      assert_receive {:inbox_access_changed, :senders}
      assert_receive {:inbox_access_changed, :something_new}
      assert queries == 0
    end

    test "a change of mailboxes is the explorer's alone", %{conn: conn} = ctx do
      view = open(ctx, conn)
      send(view.pid, {:inbox_access_changed, :mailboxes})
      settle(view)

      refute_receive {:inbox_access_changed, _}, 100
    end
  end

  # How many queries the page process ran while `fun` did its work.
  defp page_queries(view, fun) do
    counter = :counters.new(1, [])
    page = view.pid
    handler = {:count_page_queries, System.unique_integer()}

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measure, _meta, {counter, pid} ->
          if self() == pid, do: :counters.add(counter, 1, 1)
        end,
        {counter, page}
      )

    try do
      {fun.(), :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end
end
