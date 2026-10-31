defmodule PhoenixKitInbox.Web.ComposeFormAttachmentsTest do
  @moduledoc """
  The files on the compose form: the host's attachments (they can be taken
  off, never added to by the browser), the person's own uploads, and the
  host's picker — whose picks only count once the host's callback accepted
  them.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  defmodule Authorizer do
    @moduledoc false
    # Tells the test what it was asked; refuses when the draft's context says so.
    def authorize(_scope, context, uuids) do
      if pid = Process.whereis(:compose_attachments_test),
        do: send(pid, {:authorize, context, uuids})

      if context[:deny],
        do: {:error, {:attachment_forbidden, hd(uuids)}},
        else: :ok
    end
  end

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    senders = grant_role!(alice, @external)
    Process.register(self(), :compose_attachments_test)
    %{alice: alice, scope: scope_for(alice, @external, [senders])}
  end

  defp host_file(n),
    do: %{id: "f#{n}", file_uuid: Ecto.UUID.generate(), name: "offer-#{n}.pdf"}

  defp draft(attrs \\ []) do
    struct!(
      ComposeDraft,
      Keyword.merge(
        [
          to: [%{address: "client@example.com", route: :email}],
          subject: "Offer",
          body: "Hello",
          attachments: [host_file(1), host_file(2)],
          links: [%{kind: "order", ref: "o-1"}],
          context: %{}
        ],
        attrs
      )
    )
  end

  defp mount_form(ctx, conn, draft) do
    scope = ComponentHostLive.stash(ctx.scope)
    draft = ComponentHostLive.stash(draft)

    on_exit(fn ->
      ComponentHostLive.unstash(scope)
      ComponentHostLive.unstash(draft)
    end)

    assigns = %{
      id: "demo",
      draft: draft,
      scope: scope,
      authorize_attachments: {:capture, Authorizer, :authorize, 3}
    }

    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => ComposeForm,
        "assigns" => assigns,
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  defp forge(view, event, value),
    do: view |> with_target("#compose-form-demo") |> render_click(event, value)

  defp nodes(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(view, selector), do: view |> nodes(selector) |> Enum.count()

  defp files(view), do: count(view, "#compose-demo-attachments li[data-file]")

  defp upload(view, entries) do
    file_input(view, "#compose-demo-upload-form", :attachments, entries)
  end

  describe "the host's attachments" do
    test "host attachment can be removed", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      assert files(view) == 2

      assert ["Remove offer-1.pdf"] =
               nodes(view, "#compose-demo-file-h-1 button[phx-click=remove_attachment]")
               |> LazyHTML.attribute("aria-label")

      view
      |> element("#compose-demo-file-h-1 button[phx-click=remove_attachment]")
      |> render_click()

      assert files(view) == 1
      refute has_element?(view, "#compose-demo-attachments", "offer-1.pdf")
      assert has_element?(view, "#compose-demo-attachments", "offer-2.pdf")
    end

    test "a key that is not on the page changes nothing", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      forge(view, "remove_attachment", %{"key" => "h-99"})
      forge(view, "remove_attachment", %{"key" => "p-1"})
      forge(view, "remove_attachment", %{"key" => 7})
      forge(view, "remove_attachment", %{})

      assert files(view) == 2
    end

    test "a host attachment the draft does not hold cannot be added by the browser",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      stranger = Ecto.UUID.generate()

      forge(view, "add_attachment", %{"file_uuid" => stranger, "id" => "x", "name" => "evil.pdf"})
      forge(view, "change", %{"attachments" => [stranger], "added_attachments" => [stranger]})

      assert files(view) == 2
      refute render(view) =~ "evil.pdf"
      refute render(view) =~ stranger
      refute_received {:authorize, _, _}
    end

    test "nothing the page sends carries a file as a field", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      names =
        nodes(view, "#compose-form-demo input[name]:not([type=file])")
        |> LazyHTML.attribute("name")

      refute Enum.any?(names, &String.contains?(&1, "attach"))
    end
  end

  describe "own uploads" do
    test "own upload added", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(attachments: []))

      file = upload(view, [%{name: "my notes.txt", content: "hello", type: "text/plain"}])
      render_upload(file, "my notes.txt")

      assert has_element?(view, "#compose-demo-attachments li[data-upload]", "my notes.txt")
    end

    test "an upload can be cancelled; a ref that is not there changes nothing",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(attachments: []))
      file = upload(view, [%{name: "a.txt", content: "a", type: "text/plain"}])
      render_upload(file, "a.txt", 50)
      assert count(view, "#compose-demo-attachments li[data-upload]") == 1

      forge(view, "cancel_upload", %{"ref" => "nope"})
      forge(view, "cancel_upload", %{"ref" => 5})
      assert count(view, "#compose-demo-attachments li[data-upload]") == 1

      view |> element("#compose-demo-attachments li[data-upload] button") |> render_click()
      assert count(view, "#compose-demo-attachments li[data-upload]") == 0
    end

    test "a file over the module's limit gets a clear error", %{conn: conn} = ctx do
      PhoenixKit.Settings.update_setting("inbox_max_upload_bytes", "10")
      view = mount_form(ctx, conn, draft(attachments: []))

      file = upload(view, [%{name: "huge.bin", content: "more than ten bytes"}])

      render_upload(file, "huge.bin")
      assert render(view) =~ "Larger than the upload limit."
    end

    test "a path in a file's name is not shown", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(attachments: []))
      file = upload(view, [%{name: "..\\..\\etc/passwd.txt", content: "x", type: "text/plain"}])
      render_upload(file, "..\\..\\etc/passwd.txt")

      assert has_element?(view, "#compose-demo-attachments li[data-upload]", "passwd.txt")
      refute render(view) =~ "etc/passwd"
    end

    test "more files than a message may carry are refused with a message",
         %{conn: conn} = ctx do
      max = Attachments.max_files()
      view = mount_form(ctx, conn, draft(attachments: for(n <- 1..max, do: host_file(n))))

      file = upload(view, [%{name: "one-more.txt", content: "x", type: "text/plain"}])
      render_upload(file, "one-more.txt")

      assert has_element?(view, "#compose-demo-files-error[role=alert]", "at most #{max}")
      assert count(view, "#compose-demo-attachments li[data-upload]") == 0
    end
  end

  describe "the host's picker" do
    test "picked uuids go through authorize_attachments with the draft links as context",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(context: %{note: "x"}))
      uuid = Ecto.UUID.generate()

      forge(view, "pick_attachments", %{"uuids" => [uuid]})

      assert_received {:authorize, context, [^uuid]}
      assert context.links == [%{kind: "order", ref: "o-1"}]
      assert context.note == "x"
      assert files(view) == 3
    end

    test "refused pick adds nothing", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(context: %{deny: true}))
      uuid = Ecto.UUID.generate()

      forge(view, "pick_attachments", %{"uuids" => [uuid]})

      assert_received {:authorize, _, [^uuid]}
      assert files(view) == 2
      assert has_element?(view, "#compose-demo-files-error[role=alert]")
    end

    test "the same uuid picked twice is one file, and a held one is not asked again",
         %{conn: conn} = ctx do
      held = Ecto.UUID.generate()
      view = mount_form(ctx, conn, draft(attachments: [%{host_file(1) | file_uuid: held}]))
      uuid = Ecto.UUID.generate()

      forge(view, "pick_attachments", %{"uuids" => [uuid, uuid]})
      forge(view, "pick_attachments", %{"uuids" => [uuid]})
      forge(view, "pick_attachments", %{"uuids" => [held]})

      assert files(view) == 2
      assert_received {:authorize, _, [^uuid]}
      refute_received {:authorize, _, _}
    end

    test "garbage in a pick adds nothing and asks nobody", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      forge(view, "pick_attachments", %{"uuids" => ["not-a-uuid"]})
      forge(view, "pick_attachments", %{"uuids" => "nope"})
      forge(view, "pick_attachments", %{"uuids" => [%{"a" => 1}]})
      forge(view, "pick_attachments", %{})

      assert files(view) == 2
      refute_received {:authorize, _, _}
    end

    test "a picked file can be taken off again", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(attachments: []))
      forge(view, "pick_attachments", %{"uuids" => [Ecto.UUID.generate()]})
      assert files(view) == 1

      view
      |> element("#compose-demo-attachments li button[phx-click=remove_attachment]")
      |> render_click()

      assert files(view) == 0
    end

    test "a pick over the count is refused as a whole", %{conn: conn} = ctx do
      max = Attachments.max_files()
      view = mount_form(ctx, conn, draft(attachments: for(n <- 1..(max - 1), do: host_file(n))))

      forge(view, "pick_attachments", %{"uuids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]})

      assert files(view) == max - 1
      assert has_element?(view, "#compose-demo-files-error", "at most #{max}")
      refute_received {:authorize, _, _}
    end
  end
end
