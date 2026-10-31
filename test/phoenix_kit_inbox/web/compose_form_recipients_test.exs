defmodule PhoenixKitInbox.Web.ComposeFormRecipientsTest do
  @moduledoc """
  The people on the compose form: chips with their label and route, adding
  from suggestions and by hand, removing, doubles, limits — and that the
  browser only ever names a suggestion the server made, never brings a
  recipient of its own.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Test.ComponentHostLive
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposeForm

  defmodule ClientSource do
    @moduledoc false
    # What the host's draft context says about the client, for any query that
    # names them (or for none at all, as the host's own list).
    @behaviour PhoenixKitInbox.RecipientSource

    @impl true
    def suggest(_scope, context, query) do
      for %{label: label} = entry <- Map.get(context, :clients, []),
          query == "" or String.contains?(String.downcase(label), String.downcase(query)) do
        Map.put_new(entry, :group, "Client")
      end
    end
  end

  @external ["inbox", "inbox.send_external"]
  @anna %{address: "anna@client.test", label: "Anna Client", route: :email}

  setup :outbound_setup

  setup do
    enable_inbox!()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{first_name: "Bobby", last_name: "Member"})
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)
    senders = grant_role!(alice, @external)
    %{alice: alice, bob: bob, scope: scope_for(alice, @external, [senders])}
  end

  defp draft(attrs \\ []) do
    struct!(
      ComposeDraft,
      Keyword.merge(
        [
          to: [%{address: "client@example.com", label: "The client", route: :email}],
          subject: "Offer",
          body: "Hello there",
          context: %{clients: [@anna]}
        ],
        attrs
      )
    )
  end

  defp mount_form(ctx, conn, draft, extra \\ %{recipient_sources: [ClientSource]}) do
    scope = ComponentHostLive.stash(ctx.scope)
    on_exit(fn -> ComponentHostLive.unstash(scope) end)
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

  defp forge(view, event, value) do
    view |> with_target("#compose-form-demo") |> render_click(event, value)
  end

  defp nodes(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(view, selector), do: view |> nodes(selector) |> Enum.count()
  defp text_of(view, selector), do: view |> nodes(selector) |> LazyHTML.text()

  defp type_into(view, role, query),
    do: view |> form("#compose-demo-#{role}-form", %{"query" => query}) |> render_change()

  defp add_by_hand(view, role, text),
    do: view |> form("#compose-demo-#{role}-form", %{"query" => text}) |> render_submit()

  defp suggestion_ids(view, role),
    do:
      view
      |> nodes("#compose-demo-#{role}-suggestions button")
      |> LazyHTML.attribute("phx-value-id")

  describe "chips" do
    test "chip shows label and internal marker from route", %{conn: conn} = ctx do
      draft =
        draft(
          to: [
            %{address: "client@example.com", label: "The client", route: :email},
            %{user: ctx.bob.uuid, label: "Bobby Member", route: :internal}
          ]
        )

      view = mount_form(ctx, conn, draft)

      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), "The client")
      refute has_element?(view, ~s(#compose-demo-to li[data-route=email] [data-internal-marker]))

      assert has_element?(view, ~s(#compose-demo-to li[data-route=internal]), "Bobby Member")

      assert has_element?(
               view,
               ~s(#compose-demo-to li[data-route=internal] [data-internal-marker]),
               "internal"
             )

      # The address behind a name is one hover away.
      assert ["client@example.com"] =
               nodes(view, ~s(#compose-demo-to li[data-route=email]))
               |> LazyHTML.attribute("title")
    end

    test "a chip's remove button names the person for a screen reader", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      assert [label] =
               nodes(view, "#compose-demo-to li button[phx-click=remove]")
               |> LazyHTML.attribute("aria-label")

      assert label =~ "The client"
    end

    test "removing a chip takes it off; a forged key changes nothing", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(cc: [%{address: "cc@example.com", route: :email}]))
      assert count(view, "#compose-demo-to li[data-route]") == 1

      forge(view, "remove", %{"key" => "to-999"})
      forge(view, "remove", %{"key" => "bcc-1"})
      forge(view, "remove", %{"key" => 42})
      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert count(view, "#compose-demo-cc li[data-route]") == 1

      view |> element("#compose-demo-to li button[phx-click=remove]") |> render_click()
      assert count(view, "#compose-demo-to li[data-route]") == 0
      assert count(view, "#compose-demo-cc li[data-route]") == 1
    end

    test "a block that lost its last person can be closed again", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(cc: [%{address: "cc@example.com", route: :email}]))
      view |> element("#compose-demo-cc li button[phx-click=remove]") |> render_click()

      view |> element("button[phx-click=toggle][phx-value-block=cc]") |> render_click()
      refute has_element?(view, "#compose-demo-cc")
    end
  end

  describe "adding by hand" do
    test "manual address becomes email route", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      add_by_hand(view, "to", "  New.Person@Example.com ")

      assert has_element?(
               view,
               ~s(#compose-demo-to li[data-route=email]),
               "New.Person@Example.com"
             )

      refute has_element?(view, "#compose-demo-to [data-internal-marker]")
      # The field is empty again, ready for the next one.
      assert has_element?(view, ~s(#compose-demo-to-form input[name=query][value=""]))
    end

    test "an address that is not one is refused with a message", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      add_by_hand(view, "to", "not an address")

      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert has_element?(view, "#compose-demo-to-error[role=alert]")
      assert text_of(view, "#compose-demo-to-error") =~ "email address"
    end

    test "a member's address typed by hand says to choose them from the list",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      add_by_hand(view, "to", ctx.bob.email)

      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert text_of(view, "#compose-demo-to-error") =~ "Choose them from the list"
    end

    test "an empty entry does nothing", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      add_by_hand(view, "to", "   ")
      assert count(view, "#compose-demo-to li[data-route]") == 1
      refute has_element?(view, "#compose-demo-to-error")
    end

    test "the Add button is there only while something is typed", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      refute has_element?(view, "#compose-demo-to-form button[type=submit]")

      type_into(view, "to", "ann")
      assert has_element?(view, "#compose-demo-to-form button[type=submit]")
    end
  end

  describe "suggestions" do
    test "suggestions come from all sources", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(context: %{clients: [%{@anna | label: "Bobby Client"}]}))

      type_into(view, "to", "bobby")

      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Client")
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
      # Grouped under the headings the sources gave.
      assert has_element?(view, "#compose-demo-to-suggestions", "Client")
      assert has_element?(view, "#compose-demo-to-suggestions", "People and shared mailboxes")
    end

    test "picking a suggestion adds a chip with the source's route and label",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(context: %{clients: [%{@anna | label: "Bobby Client"}]}))
      type_into(view, "to", "bobby")

      view |> element("#compose-demo-to-suggestions button", "Bobby Client") |> render_click()
      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), "Bobby Client")

      type_into(view, "to", "bobby")
      view |> element("#compose-demo-to-suggestions button", "Bobby Member") |> render_click()
      assert has_element?(view, ~s(#compose-demo-to li[data-route=internal]), "Bobby Member")
      assert has_element?(view, "#compose-demo-to [data-internal-marker]")

      # The list and the field are cleared after a pick.
      refute has_element?(view, "#compose-demo-to-suggestions")
    end

    test "a blank query shows no suggestions", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      type_into(view, "to", "ann")
      assert has_element?(view, "#compose-demo-to-suggestions", "Anna Client")

      type_into(view, "to", " ")
      refute has_element?(view, "#compose-demo-to-suggestions")
    end

    test "at most eight suggestions are shown", %{conn: conn} = ctx do
      many =
        for n <- 1..12, do: %{address: "c#{n}@client.test", label: "Client #{n}", route: :email}

      view = mount_form(ctx, conn, draft(context: %{clients: many}))
      type_into(view, "to", "client")
      assert count(view, "#compose-demo-to-suggestions button[phx-click=pick]") == 8
    end

    test "the input is debounced and labelled", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      assert count(view, "#compose-demo-to-form input[name=query][phx-debounce]") == 1
      assert has_element?(view, ~s(label[for="compose-demo-to-input"]))
    end
  end

  describe "the picker of the host's lists" do
    test "the button is there only when the host brought sources", %{conn: conn} = ctx do
      with_source = mount_form(ctx, conn, draft())
      assert has_element?(with_source, "button[phx-click=toggle_picker]")

      without = mount_form(ctx, conn, draft(), %{})
      refute has_element?(without, "button[phx-click=toggle_picker]")
    end

    test "it lists the host's people under their group and adds the one picked",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
      assert has_element?(view, "#compose-demo-to-suggestions", "Anna Client")
      assert has_element?(view, "#compose-demo-to-suggestions", "Client")
      # Only the host's own lists, not every member of the application.
      refute has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")

      view |> element("#compose-demo-to-suggestions button", "Anna Client") |> render_click()
      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), "Anna Client")

      view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
      view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
      refute has_element?(view, "#compose-demo-to-suggestions")
    end
  end

  describe "doubles and limits" do
    test "duplicate recipient is not added twice", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(context: %{clients: [@anna]}))

      # By hand, in another spelling of the same address.
      add_by_hand(view, "to", "CLIENT@example.com")
      assert count(view, "#compose-demo-to li[data-route]") == 1

      # From a suggestion, twice.
      for _ <- 1..2 do
        view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
        view |> element("#compose-demo-to-suggestions button", "Anna Client") |> render_click()
      end

      assert count(view, "#compose-demo-to li[data-route]") == 2

      # The same person already there as a chip of the draft, offered again.
      type_into(view, "to", "ann")
      view |> element("#compose-demo-to-suggestions button", "Anna Client") |> render_click()
      assert count(view, "#compose-demo-to li[data-route]") == 2
    end

    test "the same person may be on another line", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(bcc: [%{address: "client@example.com", route: :email}]))
      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert count(view, "#compose-demo-bcc li[data-route]") == 1
    end

    test "bcc stops at five with a clear message", %{conn: conn} = ctx do
      bcc = for n <- 1..5, do: %{address: "b#{n}@example.com", route: :email}
      view = mount_form(ctx, conn, draft(bcc: bcc))

      add_by_hand(view, "bcc", "sixth@example.com")

      assert count(view, "#compose-demo-bcc li[data-route]") == 5
      assert text_of(view, "#compose-demo-bcc-error") =~ "At most 5 addresses in Bcc."

      # Taking one off makes room, and the message goes with the next action.
      view |> element("#compose-demo-chip-bcc-2 button[phx-click=remove]") |> render_click()
      add_by_hand(view, "bcc", "sixth@example.com")
      assert count(view, "#compose-demo-bcc li[data-route]") == 5
      refute has_element?(view, "#compose-demo-bcc-error")
    end

    test "cc stops at five and to at twenty", %{conn: conn} = ctx do
      cc = for n <- 1..5, do: %{address: "c#{n}@example.com", route: :email}
      to = for n <- 1..20, do: %{address: "t#{n}@example.com", route: :email}
      view = mount_form(ctx, conn, draft(to: to, cc: cc))

      add_by_hand(view, "cc", "more@example.com")
      assert count(view, "#compose-demo-cc li[data-route]") == 5
      assert text_of(view, "#compose-demo-cc-error") =~ "At most 5 addresses in Cc."

      add_by_hand(view, "to", "more@example.com")
      assert count(view, "#compose-demo-to li[data-route]") == 20
      assert text_of(view, "#compose-demo-to-error") =~ "At most 20 addresses in To."
    end
  end

  describe "what the browser may not decide" do
    test "a forged event with a suggestion that does not exist is ignored", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      # No list was ever made.
      forge(view, "pick", %{"id" => "s-1"})
      # A made-up recipient in place of an id.
      forge(view, "pick", %{"address" => "evil@example.com", "route" => "internal"})
      forge(view, "pick", %{"id" => %{"address" => "evil@example.com", "route" => "internal"}})

      type_into(view, "to", "ann")
      [real] = suggestion_ids(view, "to") |> Enum.take(1)
      forge(view, "pick", %{"id" => real <> "9"})
      forge(view, "pick", %{"id" => "s-0"})

      assert count(view, "#compose-demo-to li[data-route]") == 1
      refute render(view) =~ "evil@example.com"
    end

    test "a suggestion of an earlier list cannot be picked once the list changed",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      type_into(view, "to", "ann")
      [old] = suggestion_ids(view, "to")

      type_into(view, "to", "zzz")
      forge(view, "pick", %{"id" => old})
      assert count(view, "#compose-demo-to li[data-route]") == 1
    end

    test "a pick lands on the line its list belongs to, whatever role is sent",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      type_into(view, "to", "ann")
      [id] = suggestion_ids(view, "to")

      forge(view, "pick", %{"id" => id, "role" => "bcc"})

      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), "Anna Client")
      refute has_element?(view, "#compose-demo-bcc")
    end

    test "a role the form does not have is ignored", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      html = forge(view, "suggest", %{"role" => "admin", "query" => "ann"})
      forge(view, "add", %{"role" => "reply_to", "query" => "x@example.com"})
      forge(view, "toggle_picker", %{"role" => "signature"})
      forge(view, "toggle_picker", %{"role" => 3})

      refute html =~ "Anna Client"
      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert count(view, "li[data-route]") == 1
    end

    test "the page sends no recipient as a field of its own", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      type_into(view, "to", "ann")

      # Only the query and the role line to write in are inputs; a chip is
      # text, never a field the browser could rewrite before sending.
      names = nodes(view, "#compose-form-demo input[name]") |> LazyHTML.attribute("name")
      assert Enum.sort(Enum.uniq(names)) == ["query", "role", "subject"]
    end
  end
end
