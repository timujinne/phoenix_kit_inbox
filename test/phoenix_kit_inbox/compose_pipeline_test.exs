defmodule PhoenixKitInbox.ComposePipelineTest do
  @moduledoc """
  What a compose form's send does on the server with what the browser sent:
  nothing is believed beyond what the draft (the host's) and the person's own
  rights allow. A forged sender, a foreign file, a link or an HTML body of the
  browser's making, a recipient reached by another route than the one chosen:
  each is refused or ignored here, and what is left goes through
  `Messages.send_message/4`, which checks the rest.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Links
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Web.Components.ComposeDraft
  alias PhoenixKitInbox.Web.Components.ComposePipeline

  @external ["inbox", "inbox.send_external"]
  @order %{kind: "order", ref: "o-1"}

  defmodule ClientFilter do
    @moduledoc false
    # A host's circle: staff always, a client only while the host's wrapper
    # has put them in the process (the way Andi's with_clients works).
    def addressable?(user),
      do: String.starts_with?(user.username, "staff_") or user.uuid in Process.get(:clients, [])
  end

  setup :outbound_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture(%{username: "staff_bob", first_name: "Bob"})

    client =
      user_fixture(%{username: "client_x", email: "client-x@example.com", inbox_member: false})

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    smtp = mail_integration_fixture(:system, username: "noreply@company.test")
    senders = grant_role!(alice, @external)
    manager = scope_for(admin, ["inbox", "inbox.manage_shared"])

    {:ok, common} =
      Identities.create_shared(manager, %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => smtp
      })

    # Open to nobody but Owner: not Alice's to use.
    {:ok, closed} =
      Identities.create_shared(manager, %{
        "label" => "Closed",
        "integration_uuid" => smtp,
        "role_uuids" => []
      })

    desk = shared_mailbox_fixture(admin, %{name: "Desk", address: "desk@company.test"})
    grant_fixture(desk, alice, "write")
    read_only = shared_mailbox_fixture(admin, %{name: "Archive", address: "archive@company.test"})
    grant_fixture(read_only, alice, "read")

    {:ok, bound} =
      Identities.create_shared(manager, %{
        "label" => "Desk sender",
        "integration_uuid" => smtp,
        "mailbox_uuid" => desk.uuid
      })

    :ok = External.subscribe(alice_mb.uuid)
    :ok = External.subscribe(desk.uuid)

    %{
      alice: alice,
      bob: bob,
      client: client,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      common: common,
      closed: closed,
      desk: desk,
      read_only: read_only,
      bound: bound,
      alice_scope: scope_for(alice, @external, [senders])
    }
  end

  defp internal(ctx), do: %{address: "@#{ctx.bob.username}", label: "Bob", route: :internal}
  defp outside, do: %{address: "client@example.com", label: "The client", route: :email}

  defp draft(ctx, attrs \\ []) do
    struct!(
      ComposeDraft,
      Keyword.merge([to: [internal(ctx)], subject: "Hello", body: "Body text"], attrs)
    )
  end

  defp run(ctx, params, draft, callbacks \\ %{}) do
    ctx.alice_scope
    |> ComposePipeline.run(params, draft, callbacks)
    |> tap(fn
      {:ok, %Message{external_status: :pending} = message} -> await_external(message.uuid)
      _ -> :ok
    end)
  end

  defp stored(message), do: Repo.get!(Message, message.uuid)
  defp message_count, do: Repo.aggregate(Message, :count)

  defp use_client_filter do
    Application.put_env(:phoenix_kit_inbox, :recipient_filter, {ClientFilter, :addressable?})
    on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :recipient_filter) end)
  end

  describe "the sender" do
    test "forged identity_uuid refused", ctx do
      forged = "identity:#{ctx.closed.uuid}"

      assert {:error, {:identity_unusable, :not_found}} =
               run(ctx, %{"from" => forged}, draft(ctx, to: [outside()]))

      # One that is not an identity of this application at all.
      assert {:error, {:identity_unusable, :not_found}} =
               run(
                 ctx,
                 %{"from" => "identity:#{Ecto.UUID.generate()}"},
                 draft(ctx, to: [outside()])
               )

      assert {:error, :invalid_from} = run(ctx, %{"from" => "identity:nope"}, draft(ctx))
      assert message_count() == 0
      refute_received {:outbound, _, _, _}

      # The old form field means nothing here: the sender is worked out again.
      assert {:ok, message} =
               run(ctx, %{"identity_uuid" => ctx.closed.uuid}, draft(ctx, to: [outside()]))

      assert stored(message).metadata["identity"]["uuid"] == ctx.common.uuid

      # An identity the person may use is accepted.
      assert {:ok, chosen} =
               run(ctx, %{"from" => "identity:#{ctx.common.uuid}"}, draft(ctx, to: [outside()]))

      assert stored(chosen).metadata["identity"]["uuid"] == ctx.common.uuid
    end

    test "from_editable false ignores submitted from", ctx do
      params = %{"from" => "mailbox:#{ctx.desk.uuid}"}

      assert {:ok, fixed} = run(ctx, params, draft(ctx, from_editable: false))
      assert fixed.sender_mailbox_uuid == ctx.alice_mb.uuid

      # The host's own choice stands, whatever else is submitted.
      assert {:ok, host_chosen} =
               run(
                 ctx,
                 %{"from" => "user_default"},
                 draft(ctx, from: {:mailbox, ctx.desk.uuid}, from_editable: false)
               )

      assert host_chosen.sender_mailbox_uuid == ctx.desk.uuid

      # Editable: the person's choice, within what they may write from.
      assert {:ok, chosen} = run(ctx, params, draft(ctx, from_editable: true))
      assert chosen.sender_mailbox_uuid == ctx.desk.uuid
    end

    test "user_default uses the personal mailbox and its default identity", ctx do
      assert {:ok, external} = run(ctx, %{}, draft(ctx, to: [outside()], from: :user_default))
      assert external.sender_mailbox_uuid == ctx.alice_mb.uuid
      assert stored(external).metadata["identity"]["uuid"] == ctx.common.uuid
      assert_received {:outbound, _, _, _}

      # Nobody to send out to: no identity is put on it.
      assert {:ok, internal} = run(ctx, %{}, draft(ctx, from: :user_default))
      assert internal.sender_mailbox_uuid == ctx.alice_mb.uuid
      refute Map.has_key?(stored(internal).metadata, "identity")
    end

    test "with several senders open to the person, a personal one is the default", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@mine.test")

      {:ok, mine} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Zzz mine",
          "integration_uuid" => own
        })

      assert {:ok, message} = run(ctx, %{}, draft(ctx, to: [outside()], from: :user_default))
      assert stored(message).metadata["identity"]["uuid"] == mine.uuid
    end

    test "with several shared senders and no personal one, the person must choose", ctx do
      manager = scope_for(user_fixture(), ["inbox", "inbox.manage_shared"])
      other = mail_integration_fixture(:system, username: "other@company.test")

      {:ok, _} =
        Identities.create_shared(manager, %{
          "label" => "A second common sender",
          "integration_uuid" => other
        })

      assert {:error, :identity_required} =
               run(ctx, %{}, draft(ctx, to: [outside()], from: :user_default))

      assert message_count() == 0
      refute_received {:outbound, _, _, _}
      assert Errors.message(:identity_required) =~ "sender"

      # Inside the application there is nothing to choose; naming one settles it.
      assert {:ok, _} = run(ctx, %{}, draft(ctx, from: :user_default))

      assert {:ok, chosen} =
               run(
                 ctx,
                 %{"from" => "identity:#{ctx.common.uuid}"},
                 draft(ctx, to: [outside()])
               )

      assert stored(chosen).metadata["identity"]["uuid"] == ctx.common.uuid
    end

    test "a mailbox identity is the one bound to it", ctx do
      draft = draft(ctx, to: [outside()], from: {:identity, ctx.bound.uuid})
      assert {:ok, message} = run(ctx, %{}, draft)
      assert message.sender_mailbox_uuid == ctx.desk.uuid
      assert stored(message).metadata["identity"]["uuid"] == ctx.bound.uuid
    end

    test "writing rights are the send's own: not relaxed", ctx do
      assert {:error, :mailbox_access_denied} =
               run(ctx, %{"from" => "mailbox:#{ctx.read_only.uuid}"}, draft(ctx))

      assert {:error, :mailbox_access_denied} =
               run(ctx, %{"from" => "mailbox:#{Ecto.UUID.generate()}"}, draft(ctx))

      # Without the right to write outside, an outside address is refused, an
      # inside one still goes.
      weak = %{ctx | alice_scope: scope_for(ctx.alice)}
      assert {:error, _} = run(weak, %{}, draft(ctx, to: [outside()]))
      assert {:ok, _} = run(weak, %{}, draft(ctx))
      refute_received {:outbound, _, _, _}
    end

    test "scope without inbox refused", ctx do
      calls = self()

      callbacks = %{
        around_send: fn _scope, draft, send_fun ->
          send(calls, :around_send_ran)
          send_fun.(draft)
        end
      }

      for scope <- [scope_for(ctx.alice, []), nil] do
        assert {:error, :forbidden} = ComposePipeline.run(scope, %{}, draft(ctx), callbacks)
      end

      refute_received :around_send_ran
      assert message_count() == 0
    end
  end

  describe "recipients" do
    test "typed e-mail of a member rejected with hint", ctx do
      typed = %{"to" => [%{"address" => ctx.bob.email, "route" => "email"}]}

      assert {:error, {:member_as_email, [address]}} = run(ctx, typed, draft(ctx))
      assert address == ctx.bob.email
      assert Errors.message({:member_as_email, [address]}) =~ ctx.bob.email
      assert Errors.message({:member_as_email, [address]}) =~ "list"

      # The same person typed as a plain string is the same.
      assert {:error, {:member_as_email, [^address]}} =
               run(ctx, %{"to" => [ctx.bob.email]}, draft(ctx))

      assert message_count() == 0

      # Chosen from the list (internal) it goes.
      chosen = %{"to" => [%{"address" => "@#{ctx.bob.username}", "route" => "internal"}]}
      assert {:ok, _} = run(ctx, chosen, draft(ctx))
    end

    test "route internal vs resolved email refused inside around_send", ctx do
      use_client_filter()
      client = %{address: "@#{ctx.client.username}", label: "Client", route: :internal}
      draft = draft(ctx, to: [client])

      # As the host chose it, but the process is not the host's wrapper: the
      # client is an outside address here.
      assert {:error, {:route_mismatch, [mismatch]}} = run(ctx, %{}, draft)
      assert %{address: "@client_x", route: :internal, resolved: :email} = mismatch
      assert message_count() == 0

      # Inside the wrapper that lists the client, the same draft goes inside.
      wrapper = fn _scope, draft, send_fun ->
        Process.put(:clients, [ctx.client.uuid])

        try do
          send_fun.(draft)
        after
          Process.delete(:clients)
        end
      end

      assert {:ok, message} = run(ctx, %{}, draft, %{around_send: wrapper})
      assert message.external_status == :none
      assert Repo.exists?(from(d in Delivery, where: d.message_uuid == ^message.uuid))
      refute_received {:outbound, _, _, _}

      # And an e-mail route to that same client, in the wrapper, is the hint.
      typed = draft(ctx, to: [%{address: ctx.client.email, route: :email}])

      assert {:error, {:member_as_email, [address]}} =
               run(ctx, %{}, typed, %{around_send: wrapper})

      assert address == ctx.client.email

      # Outside the wrapper an e-mail route to the client is plain email.
      assert {:ok, emailed} = run(ctx, %{}, typed)
      assert emailed.external_status == :pending
    end

    test "internal recipient goes the internal path", ctx do
      assert {:ok, message} = run(ctx, %{}, draft(ctx))
      assert message.external_status == :none
      assert_receive_no_outbound()

      assert [%{mailbox_uuid: mailbox}] =
               Repo.all(
                 from(d in Delivery,
                   where: d.message_uuid == ^message.uuid and d.role == "to",
                   select: %{mailbox_uuid: d.mailbox_uuid}
                 )
               )

      assert mailbox == ctx.bob_mb.uuid
    end

    test "a user is addressed by uuid, by the way of its route", ctx do
      by_user = [%{user: ctx.bob.uuid, label: "Bob", route: :internal}]
      assert {:ok, message} = run(ctx, %{}, draft(ctx, to: by_user))
      assert message.external_status == :none

      # Outside the circle but sent to as an e-mail address: its login email.
      use_client_filter()
      emailed = [%{user: ctx.client.uuid, route: :email}]
      assert {:ok, out} = run(ctx, %{}, draft(ctx, to: emailed))
      assert out.external_status == :pending
      assert_received {:outbound, email, _, _}
      assert email.to == [{"", ctx.client.email}]

      assert {:error, {:invalid_recipient, _}} =
               run(ctx, %{}, draft(ctx, to: [%{user: Ecto.UUID.generate(), route: :internal}]))
    end

    test "a user the browser names is not turned into a login address", ctx do
      use_client_filter()
      forged = %{"to" => [%{"user" => ctx.client.uuid, "route" => "email"}]}

      result = run(ctx, forged, draft(ctx))

      assert {:error, :invalid_recipients} = result
      refute inspect(result) =~ ctx.client.email
      refute inspect(result) =~ ctx.client.username
      assert message_count() == 0

      # A member's login email is no more to be had by uuid than a client's.
      assert {:error, :invalid_recipients} =
               run(ctx, %{"to" => [%{"user" => ctx.bob.uuid, "route" => "email"}]}, draft(ctx))

      # Nobody at all answers the same as a user who is not to be had.
      assert {:error, :invalid_recipients} =
               run(
                 ctx,
                 %{"to" => [%{"user" => Ecto.UUID.generate(), "route" => "internal"}]},
                 draft(ctx)
               )

      # Nor is one outside the circle by the inside route.
      assert {:error, :invalid_recipients} =
               run(
                 ctx,
                 %{"to" => [%{"user" => ctx.client.uuid, "route" => "internal"}]},
                 draft(ctx)
               )
    end

    test "a user named by the browser who is in the circle goes by the inside route", ctx do
      form = %{"to" => [%{"user" => ctx.bob.uuid, "route" => "internal", "label" => "Bob"}]}
      assert {:ok, message} = run(ctx, form, draft(ctx, to: []))
      assert [%{"role" => "to", "handle" => "@staff_bob"}] = recipients(message)
    end

    test "a user the host's draft names is the host's to name, by any route", ctx do
      use_client_filter()
      test = self()

      wrapper = fn _scope, seen, _send_fun ->
        send(test, {:seen, seen.to})
        {:error, :stop}
      end

      emailed = [%{user: ctx.client.uuid, route: :email}]
      assert {:error, :stop} = run(ctx, %{}, draft(ctx, to: emailed), %{around_send: wrapper})
      assert_received {:seen, [%{address: address, user: user}]}
      assert address == ctx.client.email and user == ctx.client.uuid

      # The form keeping that recipient in its own params keeps it.
      echoed = %{"to" => [%{"user" => ctx.client.uuid, "route" => "email"}]}
      assert {:error, :stop} = run(ctx, echoed, draft(ctx, to: emailed), %{around_send: wrapper})
      assert_received {:seen, [%{address: ^address}]}
    end

    test "a user from the browser with an address of its own is that address typed", ctx do
      form = %{
        "to" => [
          %{"user" => ctx.client.uuid, "address" => "typed@example.com", "route" => "email"}
        ]
      }

      test = self()

      wrapper = fn _scope, seen, _send_fun ->
        send(test, {:seen, seen.to})
        {:error, :stop}
      end

      assert {:error, :stop} = run(ctx, form, draft(ctx), %{around_send: wrapper})
      assert_received {:seen, [seen]}
      assert seen.address == "typed@example.com"
      refute Map.has_key?(seen, :user)
    end

    test "a flood of entries is refused before any of them is looked up", ctx do
      # Not one of them is a user: looked up, the first would be an invalid recipient.
      flood = for _ <- 1..41, do: %{"user" => Ecto.UUID.generate(), "route" => "internal"}

      assert {:error, {:too_many_recipients, :to, 20}} = run(ctx, %{"to" => flood}, draft(ctx))

      assert {:error, {:too_many_recipients, :cc, 5}} =
               run(ctx, %{"cc" => Enum.take(flood, 11)}, draft(ctx))

      # An index map is the same list.
      indexed = flood |> Enum.with_index() |> Map.new(fn {e, n} -> {"#{n}", e} end)
      assert {:error, {:too_many_recipients, :to, 20}} = run(ctx, %{"to" => indexed}, draft(ctx))
    end

    test "what is echoed back of a refused entry is cut short", ctx do
      long = String.duplicate("a", 400) <> ",b"

      assert {:error, {:invalid_recipient, echoed}} =
               run(ctx, %{"to" => [%{"address" => long, "route" => "email"}]}, draft(ctx))

      assert String.length(echoed) <= 200
      assert String.starts_with?(long, String.trim_trailing(echoed, "…"))
    end

    test "the form's recipients replace the draft's; absent, the draft's stay", ctx do
      assert {:ok, kept} = run(ctx, %{}, draft(ctx))
      assert [%{"role" => "to", "handle" => "@staff_bob"}] = recipients(kept)

      form = %{"to" => %{"0" => %{"address" => "client@example.com", "route" => "email"}}}
      assert {:ok, replaced} = run(ctx, form, draft(ctx))
      assert replaced.external_status == :pending
      assert recipients(replaced) == []
    end

    test "limits: Cc and Bcc five each, subject 500 characters", ctx do
      six = for n <- 1..6, do: %{address: "c#{n}@example.com", route: :email}
      five = Enum.take(six, 5)

      assert {:error, {:too_many_recipients, :cc, 5}} = run(ctx, %{}, draft(ctx, cc: six))
      assert {:error, {:too_many_recipients, :bcc, 5}} = run(ctx, %{}, draft(ctx, bcc: six))
      assert Errors.message({:too_many_recipients, :cc, 5}) =~ "5"

      # The same address twice is one.
      doubled = five ++ [%{address: "C1@example.com", route: :email}]
      assert {:ok, _} = run(ctx, %{}, draft(ctx, cc: doubled))

      long = String.duplicate("a", 501)
      assert {:error, :subject_too_long} = run(ctx, %{"subject" => long}, draft(ctx))
      assert {:error, :subject_too_long} = run(ctx, %{}, draft(ctx, subject: long))
      assert {:ok, _} = run(ctx, %{"subject" => String.duplicate("é", 500)}, draft(ctx))
      assert {:error, :invalid_text} = run(ctx, %{"subject" => "a\0b"}, draft(ctx))
      assert {:error, :invalid_text} = run(ctx, %{"body" => <<255, 254>>}, draft(ctx))

      assert {:error, :no_recipients} = run(ctx, %{"to" => []}, draft(ctx))
    end

    test "one address to an entry", ctx do
      for bad <- [
            "a@example.com, b@example.com",
            "a@example.com;b@example.com",
            "x\ny@example.com",
            ""
          ] do
        assert {:error, error} = run(ctx, %{"to" => [bad]}, draft(ctx))
        assert error in [:no_recipients, {:invalid_recipient, bad}]
      end

      assert message_count() == 0
    end
  end

  describe "what comes from the draft only" do
    test "links in form params ignored", ctx do
      forged = %{
        "links" => [%{"kind" => "order", "ref" => "someone-elses"}],
        "metadata" => %{"links" => 1}
      }

      assert {:ok, message} = run(ctx, forged, draft(ctx, links: [@order]))
      assert [%{kind: "order", ref: "o-1", source: "host"}] = Links.for_message(message.uuid)

      assert {:ok, bare} = run(ctx, forged, draft(ctx))
      assert Links.for_message(bare.uuid) == []
    end

    test "reply-to outside options refused; trusted accepted", ctx do
      outside_options = "designer@elsewhere.example"
      external = draft(ctx, to: [outside()])

      # From the form, outside what the person may use: refused.
      assert {:error, :reply_to_not_allowed} =
               run(ctx, %{"reply_to" => outside_options}, external)

      # The form cannot declare a trusted one.
      assert {:error, :reply_to_not_allowed} =
               run(
                 ctx,
                 %{"reply_to" => outside_options, "reply_to_trusted" => outside_options},
                 external
               )

      # One of the person's options is accepted.
      assert {:ok, own} = run(ctx, %{"reply_to" => ctx.alice.email}, external)
      assert stored(own).metadata["reply_to"] == ctx.alice.email

      # The host's trusted address is the default and may be picked again...
      trusted = draft(ctx, to: [outside()], reply_to_trusted: outside_options)
      assert {:ok, by_default} = run(ctx, %{}, trusted)
      assert stored(by_default).metadata["reply_to"] == outside_options
      assert {:ok, picked} = run(ctx, %{"reply_to" => String.upcase(outside_options)}, trusted)
      assert stored(picked).metadata["reply_to"] == outside_options

      # ...but nothing else beside it and the options.
      assert {:error, :reply_to_not_allowed} =
               run(ctx, %{"reply_to" => "other@elsewhere.example"}, trusted)

      # Cleared by the person.
      assert {:ok, cleared} = run(ctx, %{"reply_to" => ""}, trusted)
      refute Map.has_key?(stored(cleared).metadata, "reply_to")

      assert {:error, :reply_to_not_allowed} = run(ctx, %{"reply_to" => 5}, trusted)
    end

    test "html_body only from the draft, and not from the form", ctx do
      external = draft(ctx, to: [outside()])

      assert {:ok, forged} = run(ctx, %{"html_body" => "<script>x</script>"}, external)
      refute Map.has_key?(stored(forged).metadata, "html_body")

      assert {:ok, branded} =
               run(ctx, %{}, draft(ctx, to: [outside()], html_body: "<p>brand</p>"))

      assert stored(branded).metadata["html_body"] == "<p>brand</p>"

      too_big = String.duplicate("x", 256 * 1024 + 1)

      assert {:error, :html_body_too_large} =
               run(ctx, %{}, draft(ctx, to: [outside()], html_body: too_big))
    end

    test "reply_to_message fills the thread", ctx do
      {:ok, parent} =
        Messages.send_message(scope_for(ctx.bob), ctx.bob_mb, %{
          "to" => "@#{ctx.alice.username}",
          "subject" => "Question",
          "body" => "?"
        })

      assert {:ok, reply} = run(ctx, %{}, draft(ctx, reply_to_message: parent.uuid))
      assert reply.parent_uuid == parent.uuid
      assert reply.thread_uuid == parent.thread_uuid

      # The browser does not choose the conversation.
      assert {:ok, apart} =
               run(
                 ctx,
                 %{"reply_to_message" => parent.uuid, "parent_uuid" => parent.uuid},
                 draft(ctx)
               )

      assert apart.parent_uuid == nil
      assert apart.thread_uuid != parent.thread_uuid
    end

    test "idempotency_key makes a repeat one message", ctx do
      draft = draft(ctx, idempotency_key: "form-open-1")

      assert {:ok, first} = run(ctx, %{}, draft)
      assert {:ok, again} = run(ctx, %{}, draft)
      assert again.uuid == first.uuid
      assert message_count() == 1

      # The browser cannot pick the key.
      assert {:ok, other} = run(ctx, %{"idempotency_key" => "form-open-1"}, draft(ctx))
      refute other.uuid == first.uuid
    end
  end

  describe "the subject's length" do
    test "is counted in code points, as the schema counts it, before the wrapper", ctx do
      # 300 graphemes, 600 code points.
      accents = String.duplicate("e\u0301", 300)
      assert String.length(accents) == 300
      test = self()

      wrapper = fn _scope, draft, send_fun ->
        send(test, :wrapper_ran)
        send_fun.(draft)
      end

      assert {:error, :subject_too_long} =
               run(ctx, %{"subject" => accents}, draft(ctx), %{around_send: wrapper})

      refute_received :wrapper_ran
      assert message_count() == 0

      # 500 code points is the limit, and still goes.
      assert {:ok, _} = run(ctx, %{"subject" => String.duplicate("e\u0301", 250)}, draft(ctx))
    end
  end

  describe "around_send" do
    test "around_send may replace subject, body and html_body", ctx do
      wrapper = fn _scope, draft, send_fun ->
        send_fun.(%{draft | subject: "Rewritten", body: "New body", html_body: "<p>brand</p>"})
      end

      params = %{"subject" => "Typed", "body" => "Typed body"}

      assert {:ok, message} =
               run(ctx, params, draft(ctx, to: [outside()]), %{around_send: wrapper})

      stored = stored(message)
      assert stored.subject == "Rewritten"
      assert stored.body == "New body"
      assert stored.metadata["html_body"] == "<p>brand</p>"
      assert_received {:outbound, email, _, _}
      assert email.html_body == "<p>brand</p>"

      # Its replacement is checked like the person's text.
      too_long = fn _scope, draft, send_fun ->
        send_fun.(%{draft | subject: String.duplicate("a", 501)})
      end

      assert {:error, :subject_too_long} = run(ctx, %{}, draft(ctx), %{around_send: too_long})
    end

    test "around_send gets a draft with the recipients normalised, and its other changes are ignored",
         ctx do
      test = self()

      wrapper = fn _scope, draft, send_fun ->
        send(test, {:draft, draft})

        send_fun.(%{
          draft
          | to: [%{address: "somebody-else@example.com", route: :email}],
            links: [%{kind: "order", ref: "swapped"}],
            idempotency_key: "swapped"
        })
      end

      form = %{
        "to" => [%{"user" => ctx.bob.uuid, "route" => "internal"}, " @#{ctx.bob.username} "],
        "cc" => ["Client@Example.com", "client@example.com"],
        "subject" => "Typed"
      }

      assert {:ok, message} = run(ctx, form, draft(ctx, links: [@order]), %{around_send: wrapper})
      assert_received {:draft, seen}

      assert [%{address: "@staff_bob", route: :internal}] = seen.to
      assert [%{address: "Client@Example.com", route: :email}] = seen.cc
      assert seen.subject == "Typed"
      assert seen.links == [@order]

      assert [%{"role" => "to", "handle" => "@staff_bob"}] = recipients(message)
      assert [%{role: "cc", address: "Client@Example.com"}] = External.list(message.uuid)

      assert [%{ref: "o-1"}] = Links.for_message(message.uuid)
      assert message.external_status == :pending
    end

    test "what around_send answers is what the pipeline answers", ctx do
      refuse = fn _scope, _draft, _send_fun -> {:error, :over_the_limit} end
      assert {:error, :over_the_limit} = run(ctx, %{}, draft(ctx), %{around_send: refuse})

      # Never called: whatever it says besides a refusal, nothing went out.
      silent = fn _scope, _draft, _send_fun -> :done end
      assert {:error, :send_failed} = run(ctx, %{}, draft(ctx), %{around_send: silent})
      assert message_count() == 0
      assert {:ok, _} = run(ctx, %{}, draft(ctx), %{around_send: nil})
    end
  end

  describe "what the wrapper answers after the letter went" do
    test "a send that happened is answered as sent, whatever the wrapper says", ctx do
      for answer <- [:done, nil, {:error, :late}, {:ok, :not_a_message}] do
        before = message_count()

        wrapper = fn _scope, draft, send_fun ->
          send_fun.(draft)
          answer
        end

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, %Message{} = message} =
                     run(ctx, %{}, draft(ctx), %{around_send: wrapper})

            # It is the stored letter, not a stand-in.
            assert Repo.get!(Message, message.uuid).subject == "Hello"
          end)

        assert message_count() == before + 1
        assert log =~ "wrapper"
        refute log =~ "Body text"
      end
    end

    test "a wrapper that answers {:ok, a message} without sending has sent nothing", ctx do
      fabricated = fn _scope, _draft, _send_fun -> {:ok, %Message{uuid: Ecto.UUID.generate()}} end

      assert {:error, :send_failed} = run(ctx, %{}, draft(ctx), %{around_send: fabricated})
      assert message_count() == 0
    end

    test "send_fun called twice sends once and gives both the first answer", ctx do
      test = self()

      twice = fn _scope, draft, send_fun ->
        first = send_fun.(draft)
        second = send_fun.(draft)
        send(test, {:answers, first, second})
        first
      end

      assert {:ok, message} = run(ctx, %{}, draft(ctx), %{around_send: twice})
      assert_received {:answers, {:ok, ^message}, {:ok, ^message}}
      assert message_count() == 1
    end

    test "a send that failed is not turned into a success by the wrapper", ctx do
      liar = fn _scope, draft, send_fun ->
        send_fun.(%{draft | subject: String.duplicate("x", 501)})
        {:ok, %Message{uuid: Ecto.UUID.generate()}}
      end

      assert {:error, _} = run(ctx, %{}, draft(ctx), %{around_send: liar})
      assert message_count() == 0
    end
  end

  describe "callbacks" do
    test "a wrapper that is set but not a fun of three never becomes a direct send", ctx do
      for bad <- ["not a function", {__MODULE__, :wrap}, fn draft -> draft end, 42] do
        assert {:error, :invalid_callbacks} = run(ctx, %{}, draft(ctx), %{around_send: bad})
      end

      assert message_count() == 0
    end

    test "a mistyped key is refused, not ignored", ctx do
      wrapper = fn _scope, _draft, _send_fun -> {:error, :host_rule} end

      assert {:error, :invalid_callbacks} =
               run(ctx, %{}, draft(ctx), %{around_sned: wrapper})

      assert {:error, :invalid_callbacks} =
               run(ctx, %{}, draft(ctx), around_send: wrapper, other: 1)

      assert message_count() == 0
    end

    test "authorize_attachments that is set but not a fun of three is refused", ctx do
      assert {:error, :invalid_callbacks} =
               run(ctx, %{}, draft(ctx), %{authorize_attachments: "yes"})

      assert message_count() == 0
    end

    test "callbacks that are not a map or a keyword list are refused, and nothing raises", ctx do
      for bad <- ["wrapper", [1, 2], [{:around_send}], [:around_send], 42, {:a, :b}] do
        assert {:error, :invalid_callbacks} = run(ctx, %{}, draft(ctx), bad)
      end

      assert message_count() == 0
    end

    test "nothing set, nil, an empty map or list: the direct send", ctx do
      for ok <- [%{}, [], nil, %{around_send: nil}, [authorize_attachments: nil]] do
        assert {:ok, _} = run(ctx, %{}, draft(ctx), ok)
      end
    end

    test "the refusal comes before any work, even for a draft that would fail", ctx do
      assert {:error, :invalid_callbacks} =
               run(ctx, %{}, draft(ctx, to: []), %{around_send: "x"})
    end

    test "it reads plainly" do
      assert Errors.message(:invalid_callbacks) =~ "set up"
    end
  end

  describe "attachments" do
    setup :storage_setup

    defp host_file(ctx, content, name),
      do: ctx.alice |> stored_file_fixture(content, filename: name) |> Map.fetch!(:uuid)

    defp attachment_names(message) do
      message.uuid
      |> PhoenixKitInbox.Attachments.list_for_message()
      |> Enum.map(& &1.filename)
      |> Enum.sort()
    end

    test "foreign file_uuid refused by authorize_attachments", ctx do
      theirs =
        ctx.bob |> stored_file_fixture("bob's own", filename: "theirs.txt") |> Map.fetch!(:uuid)

      test = self()

      refusing = fn scope, context, uuids ->
        send(test, {:authorize, scope.user.uuid, context, uuids})
        {:error, {:attachment_forbidden, hd(uuids)}}
      end

      callbacks = %{authorize_attachments: refusing}
      draft = draft(ctx, links: [@order], context: %{order: 7})

      assert {:error, {:attachment_forbidden, ^theirs}} =
               run(ctx, %{"added_attachments" => [theirs]}, draft, callbacks)

      assert_received {:authorize, user, context, [^theirs]}
      assert user == ctx.alice.uuid
      assert context.links == [@order]
      assert context.order == 7
      assert message_count() == 0

      # Without a callback nothing the form adds is believed.
      assert {:error, {:attachment_forbidden, ^theirs}} =
               run(ctx, %{"added_attachments" => [theirs]}, draft, %{})

      assert {:error, :invalid_attachments} =
               run(ctx, %{"added_attachments" => ["not-a-uuid"]}, draft, callbacks)

      # One the host vouches for is attached.
      mine = host_file(ctx, "mine", "mine.txt")
      allow = %{authorize_attachments: fn _scope, _context, _uuids -> :ok end}
      assert {:ok, message} = run(ctx, %{"added_attachments" => [mine]}, draft, allow)
      assert attachment_names(message) == ["mine.txt"]
    end

    test "host attachments come from the draft only", ctx do
      first = host_file(ctx, "one", "one.txt")
      second = host_file(ctx, "two", "two.txt")

      stranger =
        ctx.bob |> stored_file_fixture("bob's", filename: "bobs.txt") |> Map.fetch!(:uuid)

      attachments = [
        %{id: "a", file_uuid: first, name: "one.txt"},
        %{id: "b", file_uuid: second, name: "two.txt", flags: %{"money_free" => true}},
        %{id: "c", binary: "made by the host", filename: "made.txt", content_type: "text/plain"}
      ]

      draft = draft(ctx, attachments: attachments)

      assert {:ok, all} = run(ctx, %{}, draft)
      assert attachment_names(all) == ["made.txt", "one.txt", "two.txt"]

      assert [%{flags: %{"money_free" => true}}] =
               all.uuid
               |> PhoenixKitInbox.Attachments.list_for_message()
               |> Enum.filter(&(&1.filename == "two.txt"))

      # The person may take some away; ids that are not the draft's mean nothing,
      # and neither does a file uuid in their place.
      params = %{"attachments" => ["b", "zzz", stranger, %{"file_uuid" => stranger}, 7]}
      assert {:ok, some} = run(ctx, params, draft)
      assert attachment_names(some) == ["two.txt"]

      assert {:ok, none} = run(ctx, %{"attachments" => []}, draft)
      assert attachment_names(none) == []

      # A file of another person is not made attachable by naming it.
      assert {:ok, still} = run(ctx, %{"attachments" => ["a"], "file_uuid" => stranger}, draft)
      assert attachment_names(still) == ["one.txt"]
    end
  end

  describe "hostile params" do
    test "junk in the params is an error or ignored, never an exception", ctx do
      junk = [
        nil,
        [],
        5,
        "text",
        %{"to" => 5, "cc" => %{"a" => 1}, "bcc" => [nil, 3, %{}], "subject" => [1]},
        %{"body" => %{}, "from" => 7, "reply_to" => 3, "attachments" => "x"},
        %{
          "added_attachments" => 4,
          "to" => [%{"address" => 5}, %{"user" => 1}, %{"route" => "x"}]
        },
        %{"to" => [%{"address" => "a@example.com", "route" => "carrier pigeon"}]},
        %{"from" => "mailbox:", "subject" => <<0xC3, 0x28>>}
      ]

      for params <- junk do
        assert match?({:ok, _}, run(ctx, params, draft(ctx))) or
                 match?({:error, _}, run(ctx, params, draft(ctx))),
               "raised or answered oddly for #{inspect(params)}"
      end
    end
  end

  defp recipients(message),
    do:
      stored(message).metadata["recipients"]
      |> List.wrap()
      |> Enum.filter(&(&1["role"] != nil and &1["mailbox_uuid"] != nil))

  defp assert_receive_no_outbound, do: refute_received({:outbound, _, _, _})
end
