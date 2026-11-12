defmodule PhoenixKitInbox.Web.ComposeFormOwnUploadTest do
  @moduledoc """
  `own_upload` of the compose form: `false` takes the form's own «Upload
  files» control away (a host whose picker already uploads shows one button,
  not two); anything else, or leaving it out, keeps it. Picks the host's
  picker names still go through `authorize_attachments`.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  defmodule Authorizer do
    @moduledoc false
    def authorize(_scope, _context, _uuids), do: :ok
  end

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

  defp upload_form?(view), do: has_element?(view, "#compose-demo-upload-form")

  test "by default the form has its own upload control", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{})

    assert upload_form?(view)
    assert has_element?(view, "#compose-demo-upload-form input[type=file]")
  end

  test "own_upload off takes it away; the rest of the files area stays", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{own_upload: false})

    refute upload_form?(view)
    refute has_element?(view, "#compose-form-demo input[type=file]")
    assert has_element?(view, "#compose-demo-attachments")
  end

  test "own_upload on, or nil, keeps it: only a literal false hides it", %{conn: conn} = ctx do
    for value <- [true, nil] do
      assert conn |> then(&mount_form(ctx, &1, %{own_upload: value})) |> upload_form?()
    end
  end

  test "an update that leaves own_upload out keeps the value", %{conn: conn} = ctx do
    view = mount_form(ctx, conn, %{own_upload: false})

    send(view.pid, {:test_assigns, %{around_send: nil}})
    render(view)
    refute upload_form?(view)

    send(view.pid, {:test_assigns, %{own_upload: true}})
    render(view)
    assert upload_form?(view)

    send(view.pid, {:test_assigns, %{around_send: nil}})
    render(view)
    assert upload_form?(view)
  end

  describe "picks the host names, with the form's own upload off" do
    defp pick(view),
      do:
        view
        |> with_target("#compose-form-demo")
        |> render_click("pick_attachments", %{"uuids" => [Ecto.UUID.generate()]})

    test "are attached once the host's callback accepts them", %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, %{
          own_upload: false,
          authorize_attachments: {:capture, Authorizer, :authorize, 3}
        })

      pick(view)

      assert has_element?(view, "#compose-demo-attachments li[data-file]")
      refute has_element?(view, "#compose-demo-files-error")
      refute upload_form?(view)
    end

    test "still need the host's word: with no callback they are refused", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, %{own_upload: false})

      pick(view)

      refute has_element?(view, "#compose-demo-attachments li[data-file]")
      assert has_element?(view, "#compose-demo-files-error[role=alert]")
    end
  end
end
