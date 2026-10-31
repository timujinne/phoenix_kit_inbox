defmodule PhoenixKitInbox.Web.ComposeFormUiTest do
  @moduledoc """
  The compose form as a person sees it: what is on the page at once, what
  sits behind the small buttons, what the host's draft fills in — and that
  nothing the browser sends about the sender or the blocks is believed.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Signatures
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{first_name: "Bob"})
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    senders = grant_role!(alice, @external)
    manager = scope_for(admin, ["inbox", "inbox.manage_shared"])

    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "write")
    archive = shared_mailbox_fixture(admin, %{name: "Archive", address: "archive@company.test"})
    grant_fixture(archive, alice, "read")
    elsewhere = shared_mailbox_fixture(admin, %{name: "Elsewhere", address: "else@company.test"})

    {:ok, common} =
      Identities.create_shared(manager, %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => smtp
      })

    {:ok, closed} =
      Identities.create_shared(manager, %{
        "label" => "Closed",
        "integration_uuid" => smtp,
        "role_uuids" => []
      })

    %{
      manager: manager,
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      desk: desk,
      archive: archive,
      elsewhere: elsewhere,
      common: common,
      closed: closed,
      scope: scope_for(alice, @external, [senders])
    }
  end

  defp draft(attrs \\ []) do
    struct!(
      ComposeDraft,
      Keyword.merge(
        [
          to: [%{address: "client@example.com", label: "The client", route: :email}],
          subject: "Offer",
          body: "Hello there",
          attachments: [%{id: "a", file_uuid: Ecto.UUID.generate(), name: "offer.pdf"}]
        ],
        attrs
      )
    )
  end

  defp mount_form(ctx, conn, draft, extra \\ %{}) do
    scope = ComponentHostLive.stash(Map.get(extra, :scope, ctx.scope))
    on_exit(fn -> ComponentHostLive.unstash(scope) end)
    assigns = Map.merge(%{id: "demo", draft: draft}, Map.put(extra, :scope, scope))

    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => ComposeForm,
        "assigns" => assigns,
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  # An event the page never offers, as a browser could still send it.
  defp forge(view, event, value) do
    view |> with_target("#compose-form-demo") |> render_click(event, value)
  end

  describe "the first look" do
    test "initial render shows from/to/subject/body/attachments only", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      for part <- ~w(from to attachments) do
        assert has_element?(view, "#compose-demo-#{part}"), "no #{part}"
      end

      assert has_element?(view, ~s(input#compose-demo-subject[value="Offer"]))
      assert has_element?(view, "textarea#compose-demo-body", "Hello there")
      assert render(element(view, "#compose-demo-to")) =~ "The client"
      assert render(element(view, "#compose-demo-attachments")) =~ "offer.pdf"

      # Everything else waits behind a small button.
      for part <- ~w(cc bcc signature) do
        refute has_element?(view, "#compose-demo-#{part}"), "#{part} is open"
      end

      assert has_element?(view, "button[phx-click=toggle][phx-value-block=cc]")
      assert has_element?(view, "button[phx-click=toggle][phx-value-block=bcc]")
      assert has_element?(view, "button[phx-click=cancel]")
    end

    test "cc, bcc, signature behind small buttons", %{conn: conn} = ctx do
      {:ok, _} =
        Signatures.create_signature(ctx.scope, ctx.alice_mb, %{
          "label" => "Plain",
          "body" => "Best regards, Alice"
        })

      view = mount_form(ctx, conn, draft())

      for block <- ~w(cc bcc signature) do
        button = "button[phx-click=toggle][phx-value-block=#{block}]"
        assert has_element?(view, button)
        assert has_element?(view, button <> "[aria-pressed=false]")

        view |> element(button) |> render_click()
        assert has_element?(view, "#compose-demo-#{block}"), "#{block} did not open"
        assert has_element?(view, button <> "[aria-pressed=true]")

        view |> element(button) |> render_click()
        refute has_element?(view, "#compose-demo-#{block}"), "#{block} did not close"
      end
    end

    test "the signature button is there only for a mailbox that has signatures",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      refute has_element?(view, "button[phx-click=toggle][phx-value-block=signature]")

      forge(view, "toggle", %{"block" => "signature"})
      refute has_element?(view, "#compose-demo-signature")
    end

    test "a chosen signature goes to the end of the text; a forged one does nothing",
         %{conn: conn} = ctx do
      {:ok, sig} =
        Signatures.create_signature(ctx.scope, ctx.alice_mb, %{
          "label" => "Plain",
          "body" => "Best regards, Alice"
        })

      {:ok, foreign} =
        Signatures.create_signature(ctx.manager, ctx.elsewhere, %{
          "label" => "Desk",
          "body" => "The desk speaks"
        })

      view = mount_form(ctx, conn, draft())
      view |> element("button[phx-click=toggle][phx-value-block=signature]") |> render_click()

      view
      |> form("#compose-demo-signature-form", %{"signature" => sig.uuid})
      |> render_change()

      assert render(element(view, "#compose-demo-body")) =~ "Best regards, Alice"

      forge(view, "select_signature", %{"signature" => foreign.uuid})
      refute render(element(view, "#compose-demo-body")) =~ "The desk speaks"
      forge(view, "select_signature", %{"signature" => "nope"})
      assert render(element(view, "#compose-demo-body")) =~ "Best regards, Alice"

      # "No signature" takes the block off again.
      forge(view, "select_signature", %{"signature" => ""})
      refute render(element(view, "#compose-demo-body")) =~ "Best regards"
    end

    test "host-filled bcc opens its block", %{conn: conn} = ctx do
      bcc = [%{address: "designer@company.test", label: "Designer", route: :email}]
      view = mount_form(ctx, conn, draft(bcc: bcc))

      assert has_element?(view, "#compose-demo-bcc")
      assert render(element(view, "#compose-demo-bcc")) =~ "Designer"
      refute has_element?(view, "#compose-demo-cc")

      assert has_element?(
               view,
               "button[phx-click=toggle][phx-value-block=bcc][aria-pressed=true]"
             )

      # A block that holds people is not hidden by a click: they would still
      # get the letter.
      view |> element("button[phx-click=toggle][phx-value-block=bcc]") |> render_click()
      assert has_element?(view, "#compose-demo-bcc")
    end

    test "personal mailbox shows the visible-only-to-you warning", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      assert has_element?(view, "#compose-demo-personal-note")
      assert render(element(view, "#compose-demo-personal-note")) =~ "only you"

      shared = draft(from: {:mailbox, ctx.desk.uuid}, from_editable: false)
      view = mount_form(ctx, conn, shared)
      refute has_element?(view, "#compose-demo-personal-note")
    end

    test "the warning follows the chosen sender", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      assert has_element?(view, "#compose-demo-personal-note")

      view
      |> form("#compose-demo-from-form", %{"from" => "mailbox:#{ctx.desk.uuid}"})
      |> render_change()

      refute has_element?(view, "#compose-demo-personal-note")

      view
      |> form("#compose-demo-from-form", %{"from" => "user_default"})
      |> render_change()

      assert has_element?(view, "#compose-demo-personal-note")
    end

    test "reply-to line shows the host value", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(reply_to_trusted: "orders@company.test"))
      assert render(element(view, "#compose-demo-reply-to")) =~ "orders@company.test"

      refute has_element?(mount_form(ctx, conn, draft()), "#compose-demo-reply-to")
    end

    test "scope without inbox renders nothing", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(), %{scope: scope_for(ctx.alice, [])})

      assert has_element?(view, "#compose-form-demo")
      refute has_element?(view, "#compose-form-demo *")

      for event <- ~w(cancel toggle select_from submit change) do
        forge(view, event, %{"block" => "cc", "from" => "user_default"})
      end

      refute_receive {:inbox_compose, _, _}, 100
      refute has_element?(view, "#compose-form-demo *")
    end
  end

  describe "who it is from" do
    test "the choice lists what the person may write as, and nothing else", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      select = render(element(view, "#compose-demo-from-select"))

      assert select =~ ~s(value="user_default")
      assert select =~ ~s(value="mailbox:#{ctx.desk.uuid}")
      assert select =~ ~s(value="identity:#{ctx.common.uuid}")
      assert select =~ "Desk"
      assert select =~ "Common"

      # Read-only mailboxes, other people's mailboxes and closed identities
      # are not offered.
      refute select =~ ctx.archive.uuid
      refute select =~ ctx.elsewhere.uuid
      refute select =~ ctx.closed.uuid
    end

    test "a sender the host fixed is shown, not offered", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(from: {:mailbox, ctx.desk.uuid}, from_editable: false))

      refute has_element?(view, "#compose-demo-from-select")
      assert render(element(view, "#compose-demo-from")) =~ "Desk"

      # Whatever the browser sends changes nothing.
      forge(view, "select_from", %{"from" => "user_default"})
      assert render(element(view, "#compose-demo-from")) =~ "Desk"
      refute has_element?(view, "#compose-demo-personal-note")
    end

    test "a sender the person may not use is refused, whatever the browser sends",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(from: {:mailbox, ctx.desk.uuid}))
      assert has_element?(view, ~s(option[value="mailbox:#{ctx.desk.uuid}"][selected]))

      for forged <- [
            "mailbox:#{ctx.elsewhere.uuid}",
            "mailbox:#{ctx.archive.uuid}",
            "identity:#{ctx.closed.uuid}",
            "identity:#{Ecto.UUID.generate()}",
            "mailbox:nonsense",
            1,
            nil
          ] do
        forge(view, "select_from", %{"from" => forged})
      end

      assert has_element?(view, ~s(option[value="mailbox:#{ctx.desk.uuid}"][selected]))
    end

    test "one place to write from is not a choice", %{conn: conn} = ctx do
      lone = user_fixture()
      view = mount_form(ctx, conn, draft(), %{scope: scope_for(lone)})

      refute has_element?(view, "#compose-demo-from-select")
      assert has_element?(view, "#compose-demo-from")
    end
  end

  describe "the form's own events" do
    test "typing keeps subject and text; the browser cannot add fields", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      view
      |> form("#compose-demo-form", %{"subject" => "New subject", "body" => "New text"})
      |> render_change()

      assert has_element?(view, ~s(input#compose-demo-subject[value="New subject"]))
      assert has_element?(view, "textarea#compose-demo-body", "New text")

      # Not text, or not ours: ignored.
      forge(view, "change", %{"subject" => 1, "body" => %{"x" => 1}, "links" => "[]"})
      assert has_element?(view, ~s(input#compose-demo-subject[value="New subject"]))
      refute render(view) =~ "links"
    end

    test "nothing the form renders is a field the host did not give the person",
         %{conn: conn} = ctx do
      draft =
        draft(
          html_body: "<b>host html</b>",
          links: [%{kind: "order", ref: "o-1"}],
          reply_to_message: Ecto.UUID.generate(),
          idempotency_key: "key-1",
          reply_to_trusted: "orders@company.test"
        )

      view = mount_form(ctx, conn, draft)
      html = render(view)

      for name <- ~w(identity_uuid links html_body reply_to_message idempotency_key reply_to) do
        refute html =~ ~s(name="#{name}"), "#{name} is a field"
      end

      refute html =~ "host html"
      refute html =~ "key-1"
    end

    test "cancel tells the parent", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      view |> element("button[phx-click=cancel]") |> render_click()
      assert_receive {:inbox_compose, "demo", :cancelled}
    end

    # Enter in the subject is an implicit submission of the form. A browser
    # fires it at the form's first submit button and does nothing at all when
    # that button is disabled. The real Send button sits outside the form
    # (bound by `form=`), so the form holds a disabled one of its own, first.
    # Confirmed here by the markup, not by a browser.
    test "Enter in the subject cannot send: the form's own submit button is disabled",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      view |> form("#compose-demo-form") |> render_submit()

      buttons = "#compose-demo-form button[type=submit]"
      assert has_element?(view, buttons <> "[disabled][tabindex='-1'][aria-hidden=true]")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(buttons)
             |> Enum.count() ==
               1

      assert has_element?(view, "input#compose-demo-subject")
      assert has_element?(view, "#compose-demo-form input#compose-demo-subject")
    end

    test "the Send button is outside the form, bound to it, and active", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      refute has_element?(view, "#compose-demo-form button[type=submit]:not([disabled])")

      assert has_element?(
               view,
               "button[type=submit][form=compose-demo-form]:not([disabled])",
               "Send"
             )
    end

    test "an unknown block is not opened", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      for block <- ["to", "attachments", "", nil, 1, "cc "] do
        forge(view, "toggle", %{"block" => block})
      end

      refute has_element?(view, "#compose-demo-cc")
    end
  end
end
