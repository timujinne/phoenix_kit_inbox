defmodule PhoenixKitInbox.Web.ComposeFormSendTest do
  @moduledoc """
  The send from the compose form: a task that outlives the page, one send per
  opening however many clicks, a key that makes a retry the same letter, a
  line that says who gets it — and an error that tells the person what to do,
  not what broke.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Test.OutboundFilters
  alias PhoenixKitInbox.Test.Repo
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  defmodule Host do
    @moduledoc false
    # The host's wrapper. Tells the test what it got and does what the test
    # configured (`:compose_send_mode` in the app env) before or instead of
    # sending.
    def around(_scope, draft, send_fun) do
      if pid = Process.whereis(:compose_send_test), do: send(pid, {:around, self(), draft})
      act(Application.get_env(:phoenix_kit_inbox, :compose_send_mode, :pass), draft, send_fun)
    end

    defp act(:pass, draft, send_fun), do: send_fun.(draft)
    defp act(:hold, draft, send_fun), do: hold(draft, send_fun)

    defp act(:error, _draft, _send_fun), do: {:error, :host_said_no}
    defp act(:text_error, _draft, _send_fun), do: {:error, "SQL timeout at db-7.internal:5432"}

    defp act(:refused, _draft, _send_fun),
      do: {:error, {:refused, "Fill in {{client_name}} first."}}

    defp act(:refused_markup, _draft, _send_fun),
      do:
        {:error,
         {:refused, "<script>alert(1)</script> stale offer\n" <> String.duplicate("x", 400)}}

    defp act(:unknown_error, _draft, _send_fun), do: {:error, {:db_down, "10.0.0.7"}}
    defp act(:raise, _draft, _send_fun), do: raise("wrapper bug with secret-token")
    defp act(:exit, _draft, _send_fun), do: exit(:wrapper_died)
    defp act(:kill, _draft, _send_fun), do: Process.exit(self(), :kill)

    defp act(:raise_after, draft, send_fun) do
      send_fun.(draft)
      raise "wrapper bug after the send, secret-token"
    end

    defp act(:exit_after, draft, send_fun) do
      send_fun.(draft)
      exit(:wrapper_died_after)
    end

    defp hold(draft, send_fun) do
      receive do
        :go -> send_fun.(draft)
      after
        5_000 -> {:error, :never_released}
      end
    end
  end

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    Process.register(self(), :compose_send_test)
    on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :compose_send_mode) end)

    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{username: "staff_bob", first_name: "Bob"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)
    senders = grant_role!(alice, @external)
    %{alice: alice, bob: bob, scope: scope_for(alice, @external, [senders])}
  end

  defp mode(mode), do: Application.put_env(:phoenix_kit_inbox, :compose_send_mode, mode)

  defp draft(ctx, attrs \\ []) do
    struct!(
      ComposeDraft,
      Keyword.merge(
        [
          to: [%{address: "@#{ctx.bob.username}", label: "Bob", route: :internal}],
          subject: "Offer",
          body: "Hello there"
        ],
        attrs
      )
    )
  end

  defp mount_form(ctx, conn, draft, extra \\ %{}) do
    scope = ComponentHostLive.stash(ctx.scope)
    draft = ComponentHostLive.stash(draft)

    on_exit(fn ->
      ComponentHostLive.unstash(scope)
      ComponentHostLive.unstash(draft)
    end)

    assigns =
      Map.merge(
        %{
          id: "demo",
          draft: draft,
          scope: scope,
          around_send: {:capture, Host, :around, 3}
        },
        extra
      )

    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => ComposeForm,
        "assigns" => assigns,
        "test_pid" => self()
      })

    {:ok, view, _html} = live(conn, "/component-host")
    view
  end

  defp submit(view),
    do:
      view
      |> form("#compose-demo-form", %{"subject" => "Offer", "body" => "Hello there"})
      |> render_submit()

  defp messages, do: Repo.aggregate(Message, :count)

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen in time")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp send_button_disabled?(view),
    do: has_element?(view, "button[type=submit][form=compose-demo-form][disabled]")

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  describe "sending" do
    test "sent message goes to the parent", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      submit(view)

      assert_receive {:inbox_compose, "demo", {:sent, %Message{subject: "Offer"} = message}}, 2000
      assert Repo.get!(Message, message.uuid).body =~ "Hello there"
      assert messages() == 1
    end

    test "the button is blocked while it runs and the page says so", %{conn: conn} = ctx do
      mode(:hold)
      view = mount_form(ctx, conn, draft(ctx))

      submit(view)
      assert_receive {:around, task, _draft}, 2000

      assert send_button_disabled?(view)
      assert has_element?(view, "[data-sending]")

      send(task, :go)
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
    end

    test "double click sends once", %{conn: conn} = ctx do
      mode(:hold)
      view = mount_form(ctx, conn, draft(ctx))

      submit(view)
      submit(view)
      submit(view)

      assert_receive {:around, task, _}, 2000
      send(task, :go)
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
      submit(view)

      refute_receive {:around, _, _}, 200
      assert messages() == 1
    end

    test "cancel does not stop a send that is running", %{conn: conn} = ctx do
      mode(:hold)
      view = mount_form(ctx, conn, draft(ctx))
      submit(view)
      assert_receive {:around, task, _}, 2000

      view |> with_target("#compose-form-demo") |> render_click("cancel", %{})
      refute_receive {:inbox_compose, "demo", :cancelled}, 100

      send(task, :go)
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
      assert messages() == 1
    end

    test "page process crash after submit still completes the send task",
         %{conn: conn} = ctx do
      mode(:hold)
      view = mount_form(ctx, conn, draft(ctx))
      submit(view)
      assert_receive {:around, task, _}, 2000

      Process.flag(:trap_exit, true)
      page = view.pid
      ref = Process.monitor(page)
      Process.exit(page, :kill)
      assert_receive {:DOWN, ^ref, :process, ^page, _}, 2000

      send(task, :go)
      eventually(fn -> messages() == 1 end)
    end
  end

  describe "the key" do
    test "fresh key on every open", %{conn: conn} = ctx do
      mode(:pass)
      first = mount_form(ctx, conn, draft(ctx))
      submit(first)
      assert_receive {:around, _, %{idempotency_key: one}}, 2000
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000

      second = mount_form(ctx, conn, draft(ctx))
      submit(second)
      assert_receive {:around, _, %{idempotency_key: two}}, 2000
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000

      assert is_binary(one) and is_binary(two) and one != two
      assert messages() == 2
    end

    test "the host's own key is not the form's", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx, idempotency_key: "from-the-host"))
      submit(view)
      assert_receive {:around, _, %{idempotency_key: key}}, 2000
      assert key != "from-the-host"
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
    end

    test "an error leaves the button active and the next try keeps the key",
         %{conn: conn} = ctx do
      mode(:error)
      view = mount_form(ctx, conn, draft(ctx))

      submit(view)
      assert_receive {:around, _, %{idempotency_key: key}}, 2000
      eventually(fn -> not send_button_disabled?(view) and has_element?(view, "[role=alert]") end)
      assert messages() == 0

      mode(:pass)
      submit(view)
      assert_receive {:around, _, %{idempotency_key: ^key}}, 2000
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000

      assert messages() == 1
    end
  end

  describe "errors" do
    test "a refusal of the pipeline is shown plainly and the button is active",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx, to: []))

      submit(view)

      eventually(fn -> text(view, "[role=alert]") =~ "recipient" end)
      refute send_button_disabled?(view)
      assert messages() == 0
    end

    test "raw text, unknown reasons and crashes of the wrapper are not shown",
         %{conn: conn} = ctx do
      for {mode, secret} <- [
            text_error: "db-7.internal",
            unknown_error: "10.0.0.7",
            raise: "secret-token",
            exit: "wrapper_died"
          ] do
        mode(mode)
        view = mount_form(ctx, conn, draft(ctx))
        submit(view)
        assert_receive {:around, _, _}, 2000
        eventually(fn -> has_element?(view, "[role=alert]") end)

        refute render(view) =~ secret
        assert text(view, "[role=alert]") =~ "could not be sent"
        refute send_button_disabled?(view)
      end

      assert messages() == 0
    end

    test "a wrapper that fails after the letter went does not make it a failure",
         %{conn: conn} = ctx do
      for {mode, n} <- [raise_after: 1, exit_after: 2] do
        mode(mode)
        view = mount_form(ctx, conn, draft(ctx))
        submit(view)

        ExUnit.CaptureLog.capture_log(fn ->
          assert_receive {:inbox_compose, "demo", {:sent, %Message{} = message}}, 2000
          assert Repo.get!(Message, message.uuid).subject == "Offer"
        end)

        assert messages() == n
        refute has_element?(view, "[role=alert]")
        refute render(view) =~ "secret-token"
      end
    end

    test "a refusal the host marks as its own is shown in its words", %{conn: conn} = ctx do
      mode(:refused)
      view = mount_form(ctx, conn, draft(ctx))
      submit(view)
      assert_receive {:around, _, _}, 2000
      eventually(fn -> has_element?(view, "[role=alert]") end)

      assert text(view, "[role=alert]") =~ "Fill in {{client_name}} first."
      refute send_button_disabled?(view)
      assert messages() == 0
    end

    test "a host's refusal is cut and cannot bring markup in", %{conn: conn} = ctx do
      mode(:refused_markup)
      view = mount_form(ctx, conn, draft(ctx))
      submit(view)
      assert_receive {:around, _, _}, 2000
      eventually(fn -> has_element?(view, "[role=alert]") end)

      refute render(view) =~ "<script>alert"
      assert String.length(text(view, "[role=alert]")) <= 320
    end

    test "a task that is killed gives a plain error and an active button",
         %{conn: conn} = ctx do
      mode(:kill)
      view = mount_form(ctx, conn, draft(ctx))

      submit(view)
      assert_receive {:around, _, _}, 2000

      eventually(fn -> has_element?(view, "[role=alert]") end)
      assert text(view, "[role=alert]") =~ "Check"
      refute send_button_disabled?(view)
    end
  end

  describe "what was typed but not added" do
    test "a typed address is added as a chip before the send", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      view |> element("button[phx-click=toggle][phx-value-block=cc]") |> render_click()
      view |> form("#compose-demo-cc-form", %{"query" => "typed@example.com"}) |> render_change()

      submit(view)

      assert_receive {:around, _, %{cc: [%{address: "typed@example.com", route: :email}]}}, 2000
      # The letter itself may be refused (no sender for outside mail): the
      # point is that the address went along.
      eventually(fn -> not send_button_disabled?(view) end)
    end

    test "a typed address that cannot be added stops the send and says why at the field",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      view |> form("#compose-demo-to-form", %{"query" => "not an address"}) |> render_change()

      submit(view)

      refute_receive {:around, _, _}, 200
      assert has_element?(view, "#compose-demo-to-error[role=alert]")
      refute send_button_disabled?(view)
      assert messages() == 0
    end

    test "text typed in a Cc that was then closed is not a recipient", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      cc_button = element(view, "button[phx-click=toggle][phx-value-block=cc]")
      render_click(cc_button)
      view |> form("#compose-demo-cc-form", %{"query" => "typed@example.com"}) |> render_change()
      render_click(cc_button)
      refute has_element?(view, "#compose-demo-cc")

      submit(view)

      assert_receive {:around, _, given}, 2000
      assert given.cc == []
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000

      render_click(cc_button)
      assert has_element?(view, ~s(#compose-demo-cc-input[value=""]))
    end

    test "junk typed in a Cc that was then closed does not hold the send back",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      cc_button = element(view, "button[phx-click=toggle][phx-value-block=cc]")
      render_click(cc_button)
      view |> form("#compose-demo-cc-form", %{"query" => "not an address"}) |> render_submit()
      assert has_element?(view, "#compose-demo-cc-error")
      render_click(cc_button)

      submit(view)

      assert_receive {:around, _, %{cc: []}}, 2000
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
    end

    test "a field the page does not show is not read at the send", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      view
      |> with_target("#compose-form-demo")
      |> render_click("suggest", %{"role" => "bcc", "query" => "ghost@example.com"})

      submit(view)

      assert_receive {:around, _, given}, 2000
      assert given.bcc == []
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
    end

    test "junk typed in an open Cc stops the send with the error at that field",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      view |> element("button[phx-click=toggle][phx-value-block=cc]") |> render_click()
      view |> form("#compose-demo-cc-form", %{"query" => "not an address"}) |> render_change()

      submit(view)

      refute_receive {:around, _, _}, 200
      assert has_element?(view, "#compose-demo-cc-error[role=alert]")
      assert messages() == 0
    end

    test "a member typed as an email stops the send with the hint", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))
      view |> form("#compose-demo-to-form", %{"query" => ctx.bob.email}) |> render_change()

      submit(view)

      refute_receive {:around, _, _}, 200
      assert text(view, "#compose-demo-to-error") =~ "Choose them from the list"
    end
  end

  describe "a recipient of the draft that has no address" do
    test "shows as an error, blocks the send, and the page still mounts", %{conn: conn} = ctx do
      for user <- [Ecto.UUID.generate(), "not-a-uuid"], route <- [:email, :internal] do
        draft = draft(ctx, to: [%{user: user, route: route}])

        view = mount_form(ctx, conn, draft)

        assert has_element?(view, "#compose-demo-to li[data-unresolved]")
        assert has_element?(view, "#compose-demo-to-error[role=alert]")
        assert send_button_disabled?(view)

        submit(view)
        refute_receive {:around, _, _}, 100
        assert messages() == 0

        view |> element("#compose-demo-to li button[phx-click=remove]") |> render_click()
        refute has_element?(view, "#compose-demo-to li[data-unresolved]")
      end
    end

    test "takes the other recipients' send along once it is removed", %{conn: conn} = ctx do
      draft =
        draft(ctx,
          to: [
            %{user: Ecto.UUID.generate(), route: :email},
            %{address: "@#{ctx.bob.username}", label: "Bob", route: :internal}
          ]
        )

      view = mount_form(ctx, conn, draft)

      view
      |> element("#compose-demo-to li[data-unresolved] button[phx-click=remove]")
      |> render_click()

      refute send_button_disabled?(view)

      submit(view)

      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
    end
  end

  describe "what goes to the pipeline" do
    test "the recipients are the chips, whatever the browser sent", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      view
      |> form("#compose-demo-form", %{"subject" => "Offer", "body" => "Hello there"})
      |> render_submit(%{
        "to" => ["evil@example.com"],
        "to_route" => "internal",
        "bcc" => ["spy@example.com"],
        "added_attachments" => [Ecto.UUID.generate()],
        "attachments" => [],
        "identity_uuid" => Ecto.UUID.generate(),
        "links" => ["order:x"],
        "html_body" => "<b>x</b>",
        "idempotency_key" => "mine"
      })

      assert_receive {:around, _, given}, 2000
      assert [%{address: "@staff_bob"}] = given.to
      assert given.bcc == []
      assert given.links == []
      assert given.html_body == nil
      assert given.idempotency_key != "mine"
      assert_receive {:inbox_compose, "demo", {:sent, _}}, 2000
    end

    test "an edited subject and text are what is sent", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      view
      |> form("#compose-demo-form", %{"subject" => "New subject", "body" => "New text"})
      |> render_submit()

      assert_receive {:inbox_compose, "demo", {:sent, message}}, 2000
      assert message.subject == "New subject"
    end
  end

  describe "files" do
    test "the host's files that stayed, the picks and an own upload go along",
         %{conn: conn} = ctx do
      mode(:error)
      kept = %{id: "f1", file_uuid: Ecto.UUID.generate(), name: "kept.pdf"}
      removed = %{id: "f2", file_uuid: Ecto.UUID.generate(), name: "removed.pdf"}

      view =
        mount_form(ctx, conn, draft(ctx, attachments: [kept, removed]), %{
          authorize_attachments: {:capture, __MODULE__, :allow, 3}
        })

      view
      |> element("#compose-demo-file-h-2 button[phx-click=remove_attachment]")
      |> render_click()

      picked = Ecto.UUID.generate()

      view
      |> with_target("#compose-form-demo")
      |> render_click("pick_attachments", %{"uuids" => [picked]})

      file =
        file_input(view, "#compose-demo-upload-form", :attachments, [
          %{name: "dir/my notes.txt", content: "hi", type: "text/plain"}
        ])

      render_upload(file, "dir/my notes.txt")

      submit(view)

      assert_receive {:around, _, given}, 2000

      assert [%{id: "f1"}, %{filename: "my notes.txt", path: path}, %{file_uuid: ^picked}] =
               given.attachments

      assert is_binary(path)
      # Asked at the pick and again by the pipeline at the send.
      assert_received {:authorized, [^picked]}
      assert_received {:authorized, [^picked]}
    end

    test "files still uploading hold the send back", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(ctx))

      file =
        file_input(view, "#compose-demo-upload-form", :attachments, [
          %{name: "slow.bin", content: String.duplicate("x", 100)}
        ])

      render_upload(file, "slow.bin", 40)

      submit(view)

      refute_receive {:around, _, _}, 200
      assert text(view, "[role=alert]") =~ "uploads to finish"
    end
  end

  def allow(_scope, _context, uuids) do
    send(Process.whereis(:compose_send_test), {:authorized, uuids})
    :ok
  end

  describe "the line above the button" do
    setup do
      on_exit(fn -> PhoenixKitInbox.DataCase.outbound_filter(:none) end)
    end

    defp outside_draft(ctx) do
      draft(ctx,
        to: [%{address: "client@example.com", label: "The client", route: :email}],
        cc: [%{address: "cc@example.com", route: :email}],
        bcc: [%{address: "spy@example.com", route: :email}]
      )
    end

    test "it names the sender, the people and the counts", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, outside_draft(ctx))

      line = text(view, "#compose-demo-summary")
      assert line =~ "Alice Smith"
      assert line =~ "The client"
      assert line =~ "1 in copy"
      assert line =~ "1 hidden"
    end

    test "summary line shows preview addressing", %{conn: conn} = ctx do
      PhoenixKitInbox.DataCase.outbound_filter({OutboundFilters, :redirect})
      view = mount_form(ctx, conn, outside_draft(ctx))

      line = text(view, "#compose-demo-summary")
      assert line =~ "redirect@test.example"
      assert line =~ "bcc-redirect@test.example"
    end

    test "without a rewrite there is nothing to add", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, outside_draft(ctx))
      refute text(view, "#compose-demo-summary") =~ "goes to"
      refute text(view, "#compose-demo-summary") =~ "could not be checked"
    end

    test "a filter that refuses, or breaks, leaves a plain line", %{conn: conn} = ctx do
      for filter <- [:refuse, :raises, :throws, :garbage] do
        PhoenixKitInbox.DataCase.outbound_filter({OutboundFilters, filter})
        view = mount_form(ctx, conn, outside_draft(ctx))
        line = text(view, "#compose-demo-summary")
        assert line =~ "The client"
        refute line =~ "goes to"
        # Not silence: the person is told the address could not be checked.
        assert line =~ "could not be checked"
      end
    end

    test "nothing is sent to look", %{conn: conn} = ctx do
      PhoenixKitInbox.DataCase.outbound_filter({OutboundFilters, :redirect})
      _view = mount_form(ctx, conn, outside_draft(ctx))
      refute_receive {:outbound, _}, 100
      assert messages() == 0
    end

    test "it follows the recipients", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, outside_draft(ctx))
      view |> element("#compose-demo-to li button[phx-click=remove]") |> render_click()
      refute text(view, "#compose-demo-summary") =~ "The client"
    end
  end
end
