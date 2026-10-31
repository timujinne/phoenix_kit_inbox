defmodule PhoenixKitInbox.Web.MailExplorerTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.MailboxGrant
  alias PhoenixKitInbox.Test.Repo
  alias PhoenixKitInbox.Web.Components.MailExplorer

  import Ecto.Query

  @order %{kind: "order", ref: "o-1"}

  # What the host passes as functions (a session cannot carry a function, see
  # ComponentHostLive).
  def compose(attrs), do: %{to: "client@example.com", reply_to_message: attrs.reply_to_message}
  def allow(_scope, "order", "o-1"), do: true
  def allow(_scope, _kind, _ref), do: false

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "read")

    %{
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

  defp mount_explorer(ctx, conn, extra \\ %{}) do
    assigns =
      Map.merge(
        %{id: "demo", scope: ctx.alice_scope, filter: [@order], title: "Order mail"},
        extra
      )

    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => MailExplorer,
        "assigns" => assigns,
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  # An event the page never offers, as a browser could still send it.
  defp forge(view, event, value) do
    view |> with_target("#mail-explorer-demo") |> render_click(event, value)
  end

  defp composing, do: {:capture, __MODULE__, :compose, 1}
  defp allowing, do: {:capture, __MODULE__, :allow, 3}

  describe "the list" do
    test "renders thread rows with replies nested", %{conn: conn} = ctx do
      root =
        mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Offer", "body" => "Root body"},
          links: [@order]
        )

      reply =
        mail(ctx, :alice, handle(ctx.bob), %{
          "subject" => "Re: Offer",
          "body" => "Reply body",
          "parent_uuid" => root.uuid
        })

      other = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Question"}, links: [@order])

      view = mount_explorer(ctx, conn)
      thread = "#mail-thread-#{root.thread_uuid}"

      assert has_element?(view, "#{thread} #mail-row-#{root.uuid}")
      assert has_element?(view, "#{thread} #mail-row-#{reply.uuid}.ml-4")
      refute has_element?(view, "#{thread} #mail-row-#{root.uuid}.ml-4")
      assert has_element?(view, "#mail-thread-#{other.thread_uuid} #mail-row-#{other.uuid}")
      assert render(element(view, "#{thread} #mail-row-#{root.uuid}")) =~ "2 letters"

      # The head row selects the conversation: every letter in the pane.
      view |> element("#mail-row-#{root.uuid}") |> render_click()
      assert has_element?(view, "#mail-detail #mail-letter-#{root.uuid}")
      assert has_element?(view, "#mail-detail #mail-letter-#{reply.uuid}")
      assert render(element(view, "#mail-detail")) =~ "Root body"

      # A nested row only its own letter.
      view |> element("#mail-row-#{reply.uuid}") |> render_click()
      assert has_element?(view, "#mail-detail #mail-letter-#{reply.uuid}")
      refute has_element?(view, "#mail-detail #mail-letter-#{root.uuid}")

      assert render(view) =~ "Other people&#39;s personal mail is not shown here."
    end

    test "folder buttons filter", %{conn: conn} = ctx do
      incoming = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "In"}, links: [@order])
      outgoing = mail(ctx, :alice, handle(ctx.bob), %{"subject" => "Out"}, links: [@order])

      view = mount_explorer(ctx, conn)
      assert has_element?(view, "#mail-row-#{incoming.uuid}")
      assert has_element?(view, "#mail-row-#{outgoing.uuid}")
      assert has_element?(view, ~s(button[phx-value-folder=all][aria-pressed=true]))

      view |> element("button[phx-value-folder=inbox]") |> render_click()
      assert has_element?(view, "#mail-row-#{incoming.uuid}")
      refute has_element?(view, "#mail-row-#{outgoing.uuid}")
      assert has_element?(view, ~s(button[phx-value-folder=inbox][aria-pressed=true]))
      assert has_element?(view, ~s(button[phx-value-folder=all][aria-pressed=false]))

      view |> element("button[phx-value-folder=sent]") |> render_click()
      refute has_element?(view, "#mail-row-#{incoming.uuid}")
      assert has_element?(view, "#mail-row-#{outgoing.uuid}")

      view |> element("button[phx-value-folder=all]") |> render_click()
      assert has_element?(view, "#mail-row-#{incoming.uuid}")
      assert has_element?(view, "#mail-row-#{outgoing.uuid}")
    end

    test "folders the host did not offer are not shown, nor accepted", %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      view = mount_explorer(ctx, conn, %{folders: [:inbox, :sent]})

      assert has_element?(view, ~s(button[phx-value-folder=inbox][aria-pressed=true]))
      assert has_element?(view, "button[phx-value-folder=sent]")
      refute has_element?(view, "button[phx-value-folder=all]")

      forge(view, "folder", %{"folder" => "all"})
      forge(view, "folder", %{"folder" => "trash"})
      assert has_element?(view, ~s(button[phx-value-folder=inbox][aria-pressed=true]))
    end

    test "source labels shown (host, thread, subject, manual)", %{conn: conn} = ctx do
      host = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Alpha"}, links: [@order])

      inherited =
        mail(ctx, :alice, handle(ctx.bob), %{"subject" => "Re: Alpha", "parent_uuid" => host.uuid})

      by_subject = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Beta"})
      by_hand = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Gamma"})
      Links.record(by_subject.uuid, [@order], "subject")
      Links.record(by_hand.uuid, [@order], "manual")

      view = mount_explorer(ctx, conn)

      for {message, label} <- [
            {host, "host"},
            {inherited, "thread"},
            {by_subject, "subject"},
            {by_hand, "manual"}
          ] do
        row = view |> element("#mail-row-#{message.uuid}") |> render()
        assert row =~ ~r/badge[^>]*>\s*#{label}\s*</, "no #{label} label on #{message.subject}"
      end
    end
  end

  describe "writing" do
    test "reply builds a draft with reply_to_message", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      view = mount_explorer(ctx, conn, %{compose: composing()})

      view
      |> element("button[phx-click=reply][phx-value-uuid='#{letter.uuid}']")
      |> render_click()

      assert_receive {:inbox_explorer, "demo",
                      {:compose, %{to: "client@example.com", reply_to_message: reply_to}}}

      assert reply_to == letter.uuid

      view |> element("button[phx-click=write]") |> render_click()
      assert_receive {:inbox_explorer, "demo", {:compose, %{reply_to_message: nil}}}
    end

    test "Write and Reply are there only when the host gives compose", %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      view = mount_explorer(ctx, conn)

      refute has_element?(view, "button[phx-click=write]")
      refute has_element?(view, "button[phx-click=reply]")

      # A forged event does not make one either.
      forge(view, "write", %{})
      refute_receive {:inbox_explorer, _, {:compose, _}}, 100
    end

    test "reply to a letter the reader can no longer open is refused", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, ctx.desk.address, %{}, links: [@order])
      view = mount_explorer(ctx, conn, %{compose: composing()})
      assert has_element?(view, "#mail-row-#{letter.uuid}")

      Repo.delete_all(from(g in MailboxGrant, where: g.user_uuid == ^ctx.alice.uuid))

      view
      |> element("button[phx-click=reply][phx-value-uuid='#{letter.uuid}']")
      |> render_click()

      refute_receive {:inbox_explorer, _, {:compose, _}}, 100
      assert render(view) =~ "Message not found."
    end
  end

  describe "linking by hand" do
    test "unlink rechecks read access", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, ctx.desk.address, %{}, links: [@order])
      view = mount_explorer(ctx, conn, %{can_link?: allowing()})
      [link] = Links.for_message(letter.uuid)

      button = element(view, "button[phx-click=unlink][phx-value-link='#{link.uuid}']")
      assert has_element?(button)

      # The grant is taken away while the page is open.
      Repo.delete_all(from(g in MailboxGrant, where: g.user_uuid == ^ctx.alice.uuid))
      render_click(button)

      assert [_still_there] = Links.for_message(letter.uuid)
      refute_receive {:inbox_explorer, _, {:unlinked, _}}, 100
      assert render(view) =~ "Message not found."
    end

    test "unlink takes the link off and tells the host", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      view = mount_explorer(ctx, conn, %{can_link?: allowing()})
      [link] = Links.for_message(letter.uuid)

      view |> element("button[phx-click=unlink][phx-value-link='#{link.uuid}']") |> render_click()

      assert Links.for_message(letter.uuid) == []
      assert_receive {:inbox_explorer, "demo", {:unlinked, uuid}}
      assert uuid == letter.uuid
      refute has_element?(view, "#mail-row-#{letter.uuid}")
    end

    test "unlink is not offered, and not done, without can_link?", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{}, links: [@order])
      view = mount_explorer(ctx, conn)
      [link] = Links.for_message(letter.uuid)

      refute has_element?(view, "button[phx-click=unlink]")

      forge(view, "unlink", %{"link" => link.uuid})

      assert [_] = Links.for_message(letter.uuid)
      refute_receive {:inbox_explorer, _, {:unlinked, _}}, 100
    end

    test "link refused without can_link?", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{})
      view = mount_explorer(ctx, conn)

      refute has_element?(view, "button[phx-click=open_picker]")

      forge(view, "link", %{"uuid" => letter.uuid})

      assert Links.for_message(letter.uuid) == []
      refute_receive {:inbox_explorer, _, {:linked, _}}, 100
      assert render(view) =~ "You don&#39;t have permission to do that."

      # Nor when the host answers no for this very object.
      view =
        mount_explorer(ctx, conn, %{filter: [%{kind: "order", ref: "o-2"}], can_link?: allowing()})

      refute has_element?(view, "button[phx-click=open_picker]")

      forge(view, "link", %{"uuid" => letter.uuid})
      assert Links.for_message(letter.uuid) == []
    end

    test "a letter without a link is picked and linked to the object", %{conn: conn} = ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free one"})
      linked = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Has link"}, links: [@order])
      foreign = mail(ctx, :bob, handle(ctx.bob), %{"subject" => "Not Alice"})

      view = mount_explorer(ctx, conn, %{can_link?: allowing()})
      refute has_element?(view, "#mail-row-#{free.uuid}")

      view |> element("button[phx-click=open_picker]") |> render_click()
      assert has_element?(view, "#mail-picker button[phx-value-uuid='#{free.uuid}']")
      refute has_element?(view, "#mail-picker button[phx-value-uuid='#{linked.uuid}']")
      refute has_element?(view, "#mail-picker button[phx-value-uuid='#{foreign.uuid}']")

      view |> element("#mail-picker button[phx-value-uuid='#{free.uuid}']") |> render_click()

      assert_receive {:inbox_explorer, "demo", {:linked, uuid}}
      assert uuid == free.uuid
      assert [%{kind: "order", ref: "o-1", source: "manual"}] = Links.for_message(free.uuid)
      assert has_element?(view, "#mail-row-#{free.uuid}")
      refute has_element?(view, "#mail-picker")
    end

    test "the picker offers neither trashed nor foreign letters", %{conn: conn} = ctx do
      mine = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Trashed soon"})
      foreign = mail(ctx, :bob, handle(ctx.bob), %{"subject" => "Not Alice"})
      view = mount_explorer(ctx, conn, %{can_link?: allowing()})

      Repo.update_all(
        from(d in Delivery,
          where: d.message_uuid == ^mine.uuid and d.mailbox_uuid == ^ctx.alice_mb.uuid
        ),
        set: [folder: "trash"]
      )

      view |> element("button[phx-click=open_picker]") |> render_click()
      refute has_element?(view, "#mail-picker button[phx-value-uuid='#{mine.uuid}']")
      refute has_element?(view, "#mail-picker button[phx-value-uuid='#{foreign.uuid}']")

      # Someone else's letter is refused whatever the browser sends.
      forge(view, "link", %{"uuid" => foreign.uuid})
      assert Links.for_message(foreign.uuid) == []
      assert render(view) =~ "Message not found."
    end
  end
end
