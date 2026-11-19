defmodule PhoenixKitInbox.Web.ComposeFormRecipientLinesTest do
  @moduledoc """
  `recipient_lines` of the compose form: `:all` keeps Cc and Bcc on the form
  at all times and takes their buttons away; anything else, or leaving it
  out, keeps the two lines behind «+ Cc» / «+ Bcc».
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    senders = grant_role!(alice, @external)
    %{scope: scope_for(alice, @external, [senders])}
  end

  defp mount_form(ctx, conn, extra) do
    scope = ComponentHostLive.stash(ctx.scope)

    draft =
      ComponentHostLive.stash(%ComposeDraft{
        to: [%{address: "client@example.com", route: :email}],
        subject: "Offer",
        body: "Hello"
      })

    on_exit(fn ->
      ComponentHostLive.unstash(scope)
      ComponentHostLive.unstash(draft)
    end)

    assigns = Map.merge(%{id: "demo", draft: draft, scope: scope}, extra)

    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => ComposeForm,
        "assigns" => assigns,
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  defp line?(view, role), do: has_element?(view, "#compose-demo-#{role}-input")
  defp button?(view, block), do: has_element?(view, "#compose-demo-toggle-#{block}")

  test "by default Cc and Bcc wait behind their buttons", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{})

    assert line?(view, "to")
    refute line?(view, "cc")
    refute line?(view, "bcc")
    assert button?(view, "cc")
    assert button?(view, "bcc")
  end

  test ":all shows the three lines and no buttons for them", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{recipient_lines: :all})

    assert line?(view, "to")
    assert line?(view, "cc")
    assert line?(view, "bcc")
    refute button?(view, "cc")
    refute button?(view, "bcc")
  end

  test "with :all a forged toggle closes nothing", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{recipient_lines: :all})

    render_click(view, "toggle", %{"block" => "cc"})
    render_hook(element(view, "#compose-form-demo"), "toggle", %{"block" => "cc"})

    assert line?(view, "cc")
  end

  test "any other value is today's behaviour", %{conn: conn} = ctx do
    for value <- [nil, :some, "all"] do
      view = mount_form(ctx, conn, %{recipient_lines: value})
      refute line?(view, "cc")
      assert button?(view, "cc")
    end
  end

  test "an update that leaves recipient_lines out keeps the value", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{recipient_lines: :all})

    send(view.pid, {:test_assigns, %{around_send: nil}})
    render(view)
    assert line?(view, "bcc")

    send(view.pid, {:test_assigns, %{recipient_lines: nil}})
    render(view)
    refute line?(view, "bcc")
    assert button?(view, "bcc")
  end
end
