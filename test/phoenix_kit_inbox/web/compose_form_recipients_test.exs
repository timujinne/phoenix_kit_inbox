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

  defmodule OffersMemberSource do
    @moduledoc false
    # A host list that names an account of the application by its address.
    @behaviour PhoenixKitInbox.RecipientSource

    @impl true
    def suggest(_scope, context, _query) do
      for %{label: label, address: address} <- Map.get(context, :offered, []),
          do: %{label: label, address: address, route: :internal, group: "Client"}
    end
  end

  defmodule OffersAccountSource do
    @moduledoc false
    # A host list that names an account by its uuid, with no address.
    @behaviour PhoenixKitInbox.RecipientSource

    @impl true
    def suggest(_scope, context, _query) do
      for %{label: label, user: user} <- Map.get(context, :offered, []),
          do: %{label: label, user: user, route: :internal, group: "Client"}
    end
  end

  defmodule RaisingSource do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource

    @impl true
    def suggest(_scope, _context, _query), do: raise("lookup failed")
  end

  defmodule ScopedSource do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource

    alias PhoenixKit.Users.Auth.Scope

    @impl true
    def suggest(scope, context, query) do
      if Scope.can?(scope, "inbox.send_external"),
        do: ClientSource.suggest(scope, context, query),
        else: []
    end
  end

  defmodule ObservedSource do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource

    @impl true
    def suggest(scope, context, query) do
      send(context.observer, {:source_asked, query})
      ClientSource.suggest(scope, context, query)
    end
  end

  @external ["inbox", "inbox.send_external"]
  @anna %{address: "anna@client.test", label: "Anna Client", route: :email}

  setup :outbound_setup
  setup :internal_mail_setup

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
    test "an account chip shows the address the pipeline will actually use",
         %{conn: conn} = ctx do
      recipient = %{
        user: ctx.bob.uuid,
        address: "someone-else@example.com",
        label: "Bobby",
        route: :internal
      }

      view = mount_form(ctx, conn, draft(to: [recipient]))
      assert text_of(view, "#compose-demo-to") =~ "@#{ctx.bob.username}"
      refute render(view) =~ "someone-else@example.com"

      gone = %{recipient | user: Ecto.UUID.generate()}
      send(view.pid, {:test_assigns, %{draft: draft(to: [gone])}})
      assert has_element?(view, "[data-unresolved]")
      assert has_element?(view, "button[form=compose-demo-form][disabled]")
      refute render(view) =~ "someone-else@example.com"
    end

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

      # The address behind a name is on the chip itself, not only on hover.
      assert ["client@example.com"] =
               nodes(view, ~s(#compose-demo-to li[data-route=email]))
               |> LazyHTML.attribute("title")

      assert has_element?(
               view,
               ~s(#compose-demo-to li[data-route=email] [data-chip-address]),
               "client@example.com"
             )
    end

    test "a chip's remove button names the person for a screen reader", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())

      assert [label] =
               nodes(view, "#compose-demo-to li button[phx-click=remove]")
               |> LazyHTML.attribute("aria-label")

      assert label =~ "The client"
      assert label =~ "client@example.com"
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

    test "with internal mail off, a member's address typed by hand is an outside address",
         %{conn: conn} = ctx do
      {:ok, _} = PhoenixKitInbox.set_internal_enabled(false)
      view = mount_form(ctx, conn, draft())

      add_by_hand(view, "to", ctx.bob.email)

      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), ctx.bob.email)
      refute has_element?(view, "#compose-demo-to-error")
    end

    test "with internal mail off, an inside handle typed by hand is no address",
         %{conn: conn} = ctx do
      {:ok, _} = PhoenixKitInbox.set_internal_enabled(false)
      view = mount_form(ctx, conn, draft())

      add_by_hand(view, "to", "@#{ctx.bob.username}")

      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert text_of(view, "#compose-demo-to-error") =~ "email address"
    end

    test "with internal mail off, the host's inside chip is shown on the email route",
         %{conn: conn} = ctx do
      {:ok, _} = PhoenixKitInbox.set_internal_enabled(false)

      view =
        mount_form(
          ctx,
          conn,
          draft(to: [%{user: ctx.bob.uuid, label: "Bobby", route: :internal}])
        )

      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), ctx.bob.email)
      refute has_element?(view, "#compose-demo-to [data-internal-marker]")
    end

    test "with the members hidden, a member's address the host does not offer is refused plainly",
         %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(), %{
          recipient_sources: [ClientSource],
          member_suggestions: false
        })

      add_by_hand(view, "to", ctx.bob.email)

      assert count(view, "#compose-demo-to li[data-route]") == 1
      error = text_of(view, "#compose-demo-to-error")
      assert error =~ "inside this application"
      refute error =~ "Choose them from the list"

      # An outside address still goes through.
      add_by_hand(view, "to", "new.person@example.com")

      assert has_element?(
               view,
               ~s(#compose-demo-to li[data-route=email]),
               "new.person@example.com"
             )
    end

    test "with the members hidden, a member's address the host offers says to choose them from the list",
         %{conn: conn} = ctx do
      offered = [%{label: "Bobby at the client", address: String.upcase(ctx.bob.email)}]

      view =
        mount_form(ctx, conn, draft(context: %{offered: offered}), %{
          recipient_sources: [OffersMemberSource],
          member_suggestions: false
        })

      add_by_hand(view, "to", ctx.bob.email)

      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert text_of(view, "#compose-demo-to-error") =~ "Choose them from the list"
    end

    test "with the members hidden, a host entry that names the account by its handle is offered",
         %{conn: conn} = ctx do
      handle = "@" <> ctx.bob.username

      view =
        mount_form(
          ctx,
          conn,
          draft(context: %{offered: [%{label: "Bobby", address: String.upcase(handle)}]}),
          %{recipient_sources: [OffersMemberSource], member_suggestions: false}
        )

      add_by_hand(view, "to", ctx.bob.email)

      assert text_of(view, "#compose-demo-to-error") =~ "Choose them from the list"
    end

    test "with the members hidden, a shared mailbox the host names by its slug is offered",
         %{conn: conn} = ctx do
      desk =
        shared_mailbox_fixture(ctx.alice, %{
          name: "Desk",
          slug: "desk",
          address: "desk@company.test"
        })

      view =
        mount_form(
          ctx,
          conn,
          draft(context: %{offered: [%{label: "Desk", address: desk.slug}]}),
          %{recipient_sources: [OffersMemberSource], member_suggestions: false}
        )

      add_by_hand(view, "to", "Desk@Company.test")

      assert text_of(view, "#compose-demo-to-error") =~ "Choose them from the list"
    end

    test "with the members hidden, an account the host names without an address is offered too",
         %{conn: conn} = ctx do
      view =
        mount_form(
          ctx,
          conn,
          draft(context: %{offered: [%{label: "Bobby", user: ctx.bob.uuid}]}),
          %{
            recipient_sources: [OffersAccountSource],
            member_suggestions: false
          }
        )

      add_by_hand(view, "to", ctx.bob.email)

      assert text_of(view, "#compose-demo-to-error") =~ "Choose them from the list"
    end

    test "with the members hidden, a source that raises still leaves the plain refusal",
         %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(), %{
          recipient_sources: [RaisingSource, ClientSource],
          member_suggestions: false
        })

      add_by_hand(view, "to", ctx.bob.email)

      assert count(view, "#compose-demo-to li[data-route]") == 1
      assert text_of(view, "#compose-demo-to-error") =~ "inside this application"

      # The typed suggestions survive the failing source too.
      type_into(view, "to", "ann")
      assert has_element?(view, "#compose-demo-to-suggestions", "Anna Client")
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
    test "losing access while changing member_suggestions does not query the host sources",
         %{conn: conn} = ctx do
      form_draft = draft(context: %{clients: [@anna], observer: self()})
      view = mount_form(ctx, conn, form_draft, %{recipient_sources: [ObservedSource]})
      type_into(view, "to", "ann")
      assert_receive {:source_asked, "ann"}

      Phoenix.LiveView.send_update(view.pid, ComposeForm,
        id: "demo",
        scope: scope_for(ctx.alice, []),
        member_suggestions: false
      )

      render(view)

      refute has_element?(view, "#compose-demo-form")
      refute_receive {:source_asked, _}
    end

    test "replacing the host sources rebuilds a typed list and invalidates its old ids",
         %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(), %{
          recipient_sources: [ClientSource],
          member_suggestions: false
        })

      type_into(view, "to", "ann")
      [old_id] = suggestion_ids(view, "to")

      Phoenix.LiveView.send_update(view.pid, ComposeForm, id: "demo", recipient_sources: [])
      render(view)

      refute has_element?(view, "#compose-demo-to-suggestions")
      forge(view, "pick", %{"id" => old_id})
      assert count(view, "#compose-demo-to li[data-route]") == 1
    end

    test "a new scope rebuilds suggestions with the viewer's current rights",
         %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(), %{
          recipient_sources: [ScopedSource],
          member_suggestions: false
        })

      type_into(view, "to", "ann")
      [old_id] = suggestion_ids(view, "to")

      Phoenix.LiveView.send_update(view.pid, ComposeForm,
        id: "demo",
        scope: scope_for(ctx.alice, ["inbox"])
      )

      render(view)

      refute has_element?(view, "#compose-demo-to-suggestions")
      forge(view, "pick", %{"id" => old_id})
      assert count(view, "#compose-demo-to li[data-route]") == 1
    end

    test "an access refresh rebuilds the list after a shared mailbox is archived",
         %{conn: conn} = ctx do
      desk = shared_mailbox_fixture(ctx.alice, %{name: "Help Desk", slug: "help-desk"})
      view = mount_form(ctx, conn, draft())
      type_into(view, "to", "help-desk")
      assert has_element?(view, "#compose-demo-to-suggestions", "Help Desk")

      assert {:ok, _} = Mailboxes.archive_mailbox(ctx.scope, desk)
      Phoenix.LiveView.send_update(view.pid, ComposeForm, id: "demo", refresh: true)
      render(view)

      refute has_element?(view, "#compose-demo-to-suggestions", "Help Desk")
    end

    test "suggestions come from all sources", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(context: %{clients: [%{@anna | label: "Bobby Client"}]}))

      type_into(view, "to", "bobby")

      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Client")
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
      # Grouped under the headings the sources gave.
      assert has_element?(view, "#compose-demo-to-suggestions", "Client")
      assert has_element?(view, "#compose-demo-to-suggestions", "People and shared mailboxes")
    end

    test "with member_suggestions off only the host's sources are asked", %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(context: %{clients: [%{@anna | label: "Bobby Client"}]}), %{
          recipient_sources: [ClientSource],
          member_suggestions: false
        })

      type_into(view, "to", "bobby")

      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Client")
      refute has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
      refute has_element?(view, "#compose-demo-to-suggestions", "People and shared mailboxes")
    end

    test "member_suggestions on, or left out, asks the members too", %{conn: conn} = ctx do
      for extra <- [
            %{recipient_sources: [ClientSource], member_suggestions: true},
            %{recipient_sources: [ClientSource], member_suggestions: nil}
          ] do
        view = mount_form(ctx, conn, draft(), extra)
        type_into(view, "to", "bobby")
        assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
      end
    end

    test "member_suggestions off without host sources suggests nobody", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(), %{member_suggestions: false})

      type_into(view, "to", "bobby")

      refute has_element?(view, "#compose-demo-to-suggestions")
    end

    test "member_suggestions keeps its value over an update that leaves it out",
         %{conn: conn} = ctx do
      view =
        mount_form(ctx, conn, draft(), %{
          recipient_sources: [ClientSource],
          member_suggestions: false
        })

      Phoenix.LiveView.send_update(view.pid, ComposeForm, id: "demo", scope: ctx.scope)
      _ = render(view)

      type_into(view, "to", "bobby")
      refute has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
    end

    test "turning member_suggestions off drops a list that showed members", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      type_into(view, "to", "bobby")
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")

      Phoenix.LiveView.send_update(view.pid, ComposeForm,
        id: "demo",
        scope: ctx.scope,
        member_suggestions: false
      )

      render(view)
      refute has_element?(view, "#compose-demo-to-suggestions")
    end

    test "turning member_suggestions off keeps the host's matches for the same query",
         %{conn: conn} = ctx do
      bobby = %{@anna | label: "Bobby Client", address: "bobby@client.test"}

      view =
        mount_form(ctx, conn, draft(context: %{clients: [bobby]}), %{
          recipient_sources: [ClientSource]
        })

      type_into(view, "to", "bobby")
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Client")
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")

      Phoenix.LiveView.send_update(view.pid, ComposeForm,
        id: "demo",
        scope: ctx.scope,
        member_suggestions: false
      )

      render(view)
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Client")
      refute has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")

      Phoenix.LiveView.send_update(view.pid, ComposeForm,
        id: "demo",
        scope: ctx.scope,
        member_suggestions: true
      )

      render(view)
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Client")
    end

    test "turning member_suggestions off leaves the host's picker open", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
      assert has_element?(view, "#compose-demo-to-suggestions", "Anna Client")

      Phoenix.LiveView.send_update(view.pid, ComposeForm,
        id: "demo",
        scope: ctx.scope,
        member_suggestions: false
      )

      render(view)
      assert has_element?(view, "#compose-demo-to-suggestions", "Anna Client")
      refute has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
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
    test "removing the host sources invalidates an open picker's entries",
         %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      view |> element("button[phx-click=toggle_picker][phx-value-role=to]") |> render_click()
      [old_id] = suggestion_ids(view, "to")

      Phoenix.LiveView.send_update(view.pid, ComposeForm, id: "demo", recipient_sources: [])
      render(view)

      refute has_element?(view, "#compose-demo-to-suggestions", "Anna Client")
      forge(view, "pick", %{"id" => old_id})
      assert count(view, "#compose-demo-to li[data-route]") == 1
    end

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
      names =
        nodes(view, "#compose-form-demo input[name]:not([type=file])")
        |> LazyHTML.attribute("name")

      assert Enum.sort(Enum.uniq(names)) == ["query", "role", "subject"]
    end
  end

  describe "a draft written the way the pipeline reads one" do
    test "string keys and bare texts are recipients too", %{conn: conn} = ctx do
      draft =
        draft(
          to: [
            %{"address" => "str@example.com", "label" => "Str Keys", "route" => "email"},
            "bare@example.com",
            %{"user" => ctx.bob.uuid, "route" => "internal"}
          ]
        )

      view = mount_form(ctx, conn, draft)

      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), "Str Keys")
      assert has_element?(view, ~s(#compose-demo-to li[data-route=email]), "bare@example.com")
      assert has_element?(view, ~s(#compose-demo-to li[data-route=internal]), "@")
      refute has_element?(view, "#compose-demo-to li[data-unresolved]")
    end

    test "an entry that can not be read is shown as an error, not lost", %{conn: conn} = ctx do
      for junk <- [42, %{}, %{label: "No address"}, [:x], {:a, :b}] do
        view = mount_form(ctx, conn, draft(to: [junk, @anna]))

        assert has_element?(view, "#compose-demo-to li[data-unresolved]"), inspect(junk)
        assert has_element?(view, "#compose-demo-to-error[role=alert]")
        assert has_element?(view, "#compose-demo-to li", "Anna Client")
      end
    end

    test "a value that is no text in an entry is an entry that can not be read, not a crash",
         %{conn: conn} = ctx do
      for junk <- [
            %{address: 5, user: ""},
            %{address: "", user: 5},
            %{user: 5},
            %{address: :atom},
            %{address: nil, user: nil}
          ] do
        view = mount_form(ctx, conn, draft(to: [junk, @anna]))

        assert has_element?(view, "#compose-demo-to li[data-unresolved]"), inspect(junk)
        assert has_element?(view, "#compose-demo-to li", "Anna Client")
      end
    end

    test "an update with only the scope keeps the host's sources", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft())
      assert has_element?(view, "button[phx-click=toggle_picker]")

      Phoenix.LiveView.send_update(view.pid, ComposeForm, id: "demo", scope: ctx.scope)
      render(view)

      assert has_element?(view, "button[phx-click=toggle_picker]")
    end

    test "no sources at all is no sources", %{conn: conn} = ctx do
      view = mount_form(ctx, conn, draft(), %{recipient_sources: nil})

      refute has_element?(view, "button[phx-click=toggle_picker]")
      type_into(view, "to", "bobby")

      assert has_element?(view, "#compose-demo-to-suggestions", "Bobby Member")
    end
  end
end
