defmodule PhoenixKitInbox.Web.MailExplorerTest do
  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Attachments
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

  # What the host is asked, counted by the test through the app env.
  def counting(_scope, kind, ref) do
    send(Application.fetch_env!(:phoenix_kit_inbox, :explorer_test_pid), {:asked, kind, ref})
    true
  end

  def raising(_scope, _kind, _ref), do: raise("host bug about o-1")

  def allow_all(_scope, _kind, _ref), do: true

  def flipping(_scope, _kind, _ref),
    do: Application.get_env(:phoenix_kit_inbox, :explorer_allow, true)

  def labelling(%{kind: "order", ref: "o-1"}) do
    send(Application.fetch_env!(:phoenix_kit_inbox, :explorer_test_pid), {:labelled, "o-1"})
    "Order #1042"
  end

  def labelling(_object), do: nil

  def label_raising(_object), do: raise("label bug about o-1")

  # The host's attachment policy: refuses the files whose name it was told.
  def policy(_scope, _users, rows) do
    refused = Application.get_env(:phoenix_kit_inbox, :explorer_refused_file)
    if Enum.any?(rows, &(&1.filename == refused)), do: {:error, :money}, else: :ok
  end

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
      thread = "#mail-thread-demo-#{root.thread_uuid}"

      assert has_element?(view, "#{thread} #mail-row-demo-#{root.uuid}")
      assert has_element?(view, "#{thread} #mail-row-demo-#{reply.uuid}.ml-4")
      refute has_element?(view, "#{thread} #mail-row-demo-#{root.uuid}.ml-4")

      assert has_element?(
               view,
               "#mail-thread-demo-#{other.thread_uuid} #mail-row-demo-#{other.uuid}"
             )

      assert render(element(view, "#{thread} #mail-row-demo-#{root.uuid}")) =~ "2 letters"

      # The head row selects the conversation: every letter in the pane.
      view |> element("#mail-row-demo-#{root.uuid}") |> render_click()
      assert has_element?(view, "#mail-detail-demo #mail-letter-demo-#{root.uuid}")
      assert has_element?(view, "#mail-detail-demo #mail-letter-demo-#{reply.uuid}")
      assert render(element(view, "#mail-detail-demo")) =~ "Root body"

      # A nested row only its own letter.
      view |> element("#mail-row-demo-#{reply.uuid}") |> render_click()
      assert has_element?(view, "#mail-detail-demo #mail-letter-demo-#{reply.uuid}")
      refute has_element?(view, "#mail-detail-demo #mail-letter-demo-#{root.uuid}")

      assert render(view) =~ "Other people&#39;s personal mail is not shown here."
    end

    test "folder buttons filter", %{conn: conn} = ctx do
      incoming = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "In"}, links: [@order])
      outgoing = mail(ctx, :alice, handle(ctx.bob), %{"subject" => "Out"}, links: [@order])

      view = mount_explorer(ctx, conn)
      assert has_element?(view, "#mail-row-demo-#{incoming.uuid}")
      assert has_element?(view, "#mail-row-demo-#{outgoing.uuid}")
      assert has_element?(view, ~s(button[phx-value-folder=all][aria-pressed=true]))

      view |> element("button[phx-value-folder=inbox]") |> render_click()
      assert has_element?(view, "#mail-row-demo-#{incoming.uuid}")
      refute has_element?(view, "#mail-row-demo-#{outgoing.uuid}")
      assert has_element?(view, ~s(button[phx-value-folder=inbox][aria-pressed=true]))
      assert has_element?(view, ~s(button[phx-value-folder=all][aria-pressed=false]))

      view |> element("button[phx-value-folder=sent]") |> render_click()
      refute has_element?(view, "#mail-row-demo-#{incoming.uuid}")
      assert has_element?(view, "#mail-row-demo-#{outgoing.uuid}")

      view |> element("button[phx-value-folder=all]") |> render_click()
      assert has_element?(view, "#mail-row-demo-#{incoming.uuid}")
      assert has_element?(view, "#mail-row-demo-#{outgoing.uuid}")
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
        row = view |> element("#mail-row-demo-#{message.uuid}") |> render()
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
      assert has_element?(view, "#mail-row-demo-#{letter.uuid}")

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
      refute has_element?(view, "#mail-row-demo-#{letter.uuid}")
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

    test "link is not offered, and not done, without can_link?", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{})
      view = mount_explorer(ctx, conn)

      refute has_element?(view, "button[phx-click=open_picker]")

      # No picker open: a link event is not one the page could have sent.
      forge(view, "link", %{"uuid" => letter.uuid})

      assert Links.for_message(letter.uuid) == []
      refute_receive {:inbox_explorer, _, {:linked, _}}, 100

      # Nor when the host answers no for this very object.
      view =
        mount_explorer(ctx, conn, %{filter: [%{kind: "order", ref: "o-2"}], can_link?: allowing()})

      refute has_element?(view, "button[phx-click=open_picker]")

      forge(view, "link", %{"uuid" => letter.uuid})
      assert Links.for_message(letter.uuid) == []
    end

    test "the host's no at the moment of the click is final", %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})
      view = mount_explorer(ctx, conn, %{can_link?: {:capture, __MODULE__, :flipping, 3}})
      Application.put_env(:phoenix_kit_inbox, :explorer_allow, true)
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :explorer_allow) end)

      view |> element("button[phx-click=open_picker]") |> render_click()
      Application.put_env(:phoenix_kit_inbox, :explorer_allow, false)

      view
      |> element("#mail-picker-demo button[phx-value-uuid='#{letter.uuid}']")
      |> render_click()

      assert Links.for_message(letter.uuid) == []
      assert render(view) =~ "You don&#39;t have permission to do that."
    end

    test "a letter without a link is picked and linked to the object", %{conn: conn} = ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free one"})
      linked = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Has link"}, links: [@order])
      foreign = mail(ctx, :bob, handle(ctx.bob), %{"subject" => "Not Alice"})

      view = mount_explorer(ctx, conn, %{can_link?: allowing()})
      refute has_element?(view, "#mail-row-demo-#{free.uuid}")

      view |> element("button[phx-click=open_picker]") |> render_click()
      assert has_element?(view, "#mail-picker-demo button[phx-value-uuid='#{free.uuid}']")
      refute has_element?(view, "#mail-picker-demo button[phx-value-uuid='#{linked.uuid}']")
      refute has_element?(view, "#mail-picker-demo button[phx-value-uuid='#{foreign.uuid}']")

      view |> element("#mail-picker-demo button[phx-value-uuid='#{free.uuid}']") |> render_click()

      assert_receive {:inbox_explorer, "demo", {:linked, uuid}}
      assert uuid == free.uuid
      assert [%{kind: "order", ref: "o-1", source: "manual"}] = Links.for_message(free.uuid)
      assert has_element?(view, "#mail-row-demo-#{free.uuid}")
      refute has_element?(view, "#mail-picker-demo")
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
      refute has_element?(view, "#mail-picker-demo button[phx-value-uuid='#{mine.uuid}']")
      refute has_element?(view, "#mail-picker-demo button[phx-value-uuid='#{foreign.uuid}']")

      # A letter the picker did not show is not linked, whatever the browser
      # sends: neither someone else's, nor one of the viewer's own.
      forge(view, "link", %{"uuid" => foreign.uuid})
      forge(view, "link", %{"uuid" => mine.uuid})
      assert Links.for_message(foreign.uuid) == []
      assert Links.for_message(mine.uuid) == []
      refute_receive {:inbox_explorer, _, {:linked, _}}, 100
    end
  end

  describe "several explorers on one page" do
    test "the DOM ids are scoped by the explorer's id", %{conn: conn} = ctx do
      letter =
        mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Both"},
          links: [@order, %{kind: "order", ref: "o-2"}]
        )

      assigns = %{id: "demo", scope: ctx.alice_scope, filter: [@order]}

      conn =
        Plug.Test.init_test_session(conn, %{
          "component" => MailExplorer,
          "assigns" => assigns,
          "second_assigns" => %{id: "again", filter: [%{kind: "order", ref: "o-2"}]},
          "test_pid" => self()
        })

      # Two explorers showing the same letter: LiveViewTest raises on a
      # duplicate id.
      {:ok, view, _html} = live(conn, "/component-host")

      for id <- ["demo", "again"] do
        assert has_element?(view, "#mail-explorer-#{id}")
        assert has_element?(view, "#mail-list-#{id} #mail-row-#{id}-#{letter.uuid}")
        assert has_element?(view, "#mail-detail-#{id} #mail-letter-#{id}-#{letter.uuid}")
      end

      view |> element("#mail-row-again-#{letter.uuid}") |> render_click()
      assert has_element?(view, "#mail-detail-again #mail-letter-again-#{letter.uuid}")
    end
  end

  describe "attachments of a letter" do
    setup :storage_setup

    setup do
      on_exit(fn ->
        Application.delete_env(:phoenix_kit_inbox, :attachment_policy)
        Application.delete_env(:phoenix_kit_inbox, :explorer_refused_file)
      end)
    end

    defp with_files(ctx, files) do
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Files"},
        links: [@order],
        attachments_data: Enum.map(files, &%{binary: "content of " <> &1, filename: &1})
      )
    end

    defp refuse_file(name) do
      Application.put_env(:phoenix_kit_inbox, :attachment_policy, {__MODULE__, :policy})
      Application.put_env(:phoenix_kit_inbox, :explorer_refused_file, name)
    end

    test "a file of the letter is offered as a download link", %{conn: conn} = ctx do
      letter = with_files(ctx, ["plan.pdf"])
      [file] = Attachments.list_for_message(letter.uuid)

      view = mount_explorer(ctx, conn)
      view |> element("#mail-row-demo-#{letter.uuid}") |> render_click()

      link = "#mail-letter-demo-#{letter.uuid} a#mail-attachment-demo-#{file.uuid}"

      assert has_element?(
               view,
               link <> ~s([href="#{PhoenixKitInbox.Paths.attachment(file.uuid)}"])
             )

      assert render(element(view, link)) =~ "plan.pdf"
    end

    test "a file the host policy withholds shows a plate without link or name",
         %{conn: conn} = ctx do
      letter = with_files(ctx, ["plan.pdf", "priced.pdf"])
      refuse_file("priced.pdf")
      [open, priced] = Attachments.list_for_message(letter.uuid)

      view = mount_explorer(ctx, conn)
      view |> element("#mail-row-demo-#{letter.uuid}") |> render_click()

      assert has_element?(view, "a#mail-attachment-demo-#{open.uuid}")
      refute has_element?(view, "a#mail-attachment-demo-#{priced.uuid}")
      assert has_element?(view, "span#mail-attachment-demo-#{priced.uuid}")
      html = render(view)
      assert html =~ "Attachment not available"
      refute html =~ "priced.pdf"
      refute html =~ PhoenixKitInbox.Paths.attachment(priced.uuid)
    end

    test "every letter of a selected conversation shows its own files", %{conn: conn} = ctx do
      root = with_files(ctx, ["one.pdf"])

      reply =
        mail(ctx, :alice, handle(ctx.bob), %{"parent_uuid" => root.uuid},
          attachments_data: [%{binary: "two", filename: "two.pdf"}]
        )

      [one] = Attachments.list_for_message(root.uuid)
      [two] = Attachments.list_for_message(reply.uuid)

      view = mount_explorer(ctx, conn)
      view |> element("#mail-row-demo-#{root.uuid}") |> render_click()

      assert has_element?(
               view,
               "#mail-letter-demo-#{root.uuid} a#mail-attachment-demo-#{one.uuid}"
             )

      assert has_element?(
               view,
               "#mail-letter-demo-#{reply.uuid} a#mail-attachment-demo-#{two.uuid}"
             )

      refute has_element?(
               view,
               "#mail-letter-demo-#{root.uuid} a#mail-attachment-demo-#{two.uuid}"
             )
    end

    test "a file of a letter the viewer cannot read is not downloadable by its uuid",
         %{conn: conn} = ctx do
      mine = with_files(ctx, ["mine.pdf"])

      foreign =
        mail(ctx, :bob, handle(ctx.bob), %{},
          attachments_data: [%{binary: "x", filename: "x.pdf"}]
        )

      [foreign_file] = Attachments.list_for_message(foreign.uuid)

      view = mount_explorer(ctx, conn)
      view |> element("#mail-row-demo-#{mine.uuid}") |> render_click()

      refute render(view) =~ foreign_file.uuid
      # The download itself asks again, whatever uuid is put in a link.
      assert {:error, :not_found} =
               Attachments.fetch_for_download(ctx.alice_scope, foreign_file.uuid)
    end
  end

  describe "the host's say on linking (can_link?)" do
    setup do
      Application.put_env(:phoenix_kit_inbox, :explorer_test_pid, self())
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :explorer_test_pid) end)
    end

    defp asked(acc \\ []) do
      receive do
        {:asked, kind, ref} -> asked([{kind, ref} | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end

    test "is asked once per object per load, not on every render", %{conn: conn} = ctx do
      root = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "A"}, links: [@order])
      mail(ctx, :alice, handle(ctx.bob), %{"parent_uuid" => root.uuid}, links: [@order])
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "B"}, links: [@order])

      view = mount_explorer(ctx, conn, %{can_link?: {:capture, __MODULE__, :counting, 3}})

      # One question per load, and a page loads twice on mount (the static
      # render, then the connected one); three letters, one object.
      assert asked() == [{"order", "o-1"}, {"order", "o-1"}]

      view |> element("#mail-row-demo-#{root.uuid}") |> render_click()
      render(view)
      render(view)
      assert asked() == []

      assert has_element?(view, "button[phx-click=unlink]")
      assert has_element?(view, "button[phx-click=open_picker]")
    end

    test "a host callback that raises hides the buttons and does not crash the page",
         %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "A"}, links: [@order])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view = mount_explorer(ctx, conn, %{can_link?: {:capture, __MODULE__, :raising, 3}})
          assert render(view) =~ "A"
          refute has_element?(view, "button[phx-click=unlink]")
          refute has_element?(view, "button[phx-click=open_picker]")
        end)

      assert log =~ "can_link?"
      refute log =~ "o-1"
    end
  end

  describe "what the host says about the objects (link_label, link_to)" do
    setup do
      Application.put_env(:phoenix_kit_inbox, :explorer_test_pid, self())
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :explorer_test_pid) end)
    end

    @other_order %{kind: "order", ref: "o-2"}

    test "a link shows the host's label of the object, asked once per load",
         %{conn: conn} = ctx do
      root = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "A"}, links: [@order])
      mail(ctx, :alice, handle(ctx.bob), %{"parent_uuid" => root.uuid}, links: [@order])

      view = mount_explorer(ctx, conn, %{link_label: {:capture, __MODULE__, :labelling, 1}})
      view |> element("#mail-row-demo-#{root.uuid}") |> render_click()

      assert render(element(view, "#mail-detail-demo")) =~ "Order #1042"
      assert [:labelled, :labelled] = drain_labelled()
      render(view)
      assert [] = drain_labelled()
    end

    defp drain_labelled(acc \\ []) do
      receive do
        {:labelled, _} -> drain_labelled([:labelled | acc])
      after
        100 -> acc
      end
    end

    test "without a label the raw ref is not printed, only how the link came about",
         %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "A"}, links: [@order])
      view = mount_explorer(ctx, conn)

      html = render(view)
      refute html =~ "o-1"
      assert render(element(view, "#mail-detail-demo")) =~ "host"
    end

    test "a failing label callback is the same as none", %{conn: conn} = ctx do
      mail(ctx, :bob, handle(ctx.alice), %{"subject" => "A"}, links: [@order])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          view =
            mount_explorer(ctx, conn, %{link_label: {:capture, __MODULE__, :label_raising, 1}})

          refute render(view) =~ "o-1"
        end)

      assert log =~ "link_label"
      refute log =~ "o-1"
    end

    test "manual links go to link_to; two objects without it offer no linking",
         %{conn: conn} = ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})
      both = %{filter: [@order, @other_order], can_link?: {:capture, __MODULE__, :allow_all, 3}}

      view = mount_explorer(ctx, conn, both)
      refute has_element?(view, "button[phx-click=open_picker]")
      forge(view, "open_picker", %{})
      refute has_element?(view, "#mail-picker-demo")

      view = mount_explorer(ctx, conn, Map.put(both, :link_to, @other_order))
      view |> element("button[phx-click=open_picker]") |> render_click()
      view |> element("#mail-picker-demo button[phx-value-uuid='#{free.uuid}']") |> render_click()

      assert [%{kind: "order", ref: "o-2", source: "manual"}] = Links.for_message(free.uuid)
    end

    test "one object in the filter is the target without link_to, whatever its keys",
         %{conn: conn} = ctx do
      free = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})
      keyed = %{filter: [%{"kind" => "order", "ref" => "o-1"}], can_link?: allowing()}

      view = mount_explorer(ctx, conn, keyed)
      view |> element("button[phx-click=open_picker]") |> render_click()
      view |> element("#mail-picker-demo button[phx-value-uuid='#{free.uuid}']") |> render_click()
      assert [%{ref: "o-1"}] = Links.for_message(free.uuid)
    end

    test "an empty or unusable filter renders, and forged events do nothing",
         %{conn: conn} = ctx do
      letter = mail(ctx, :bob, handle(ctx.alice), %{"subject" => "Free"})

      for filter <- [[], [%{}], [%{kind: 1, ref: nil}]] do
        view = mount_explorer(ctx, conn, %{filter: filter, can_link?: allowing()})
        assert render(view) =~ "No letters yet."
        refute has_element?(view, "button[phx-click=open_picker]")
        forge(view, "open_picker", %{})
        forge(view, "link", %{"uuid" => letter.uuid})
        assert Links.for_message(letter.uuid) == []
      end
    end
  end
end
