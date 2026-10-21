defmodule PhoenixKitInbox.ExternalSendTest do
  @moduledoc """
  A message to addresses outside the application: who may send one, the
  rows it writes, the email that leaves through `Outbound` after the commit,
  its status, its Bcc, and its retry.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKitInbox.Body
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.ExternalRecipient
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Test.OutboundFilters

  @external ["inbox", "inbox.send_external"]

  setup :outbound_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture(%{first_name: "Alice", last_name: "Smith"})
    bob = user_fixture()
    client = user_fixture(%{email: "client@example.com", inbox_member: false})
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    system_smtp = mail_integration_fixture(:system, username: "noreply@company.test")

    {:ok, common} =
      Identities.create_shared(scope_for(admin, ["inbox", "inbox.manage_shared"]), %{
        "label" => "Common",
        "from_name" => "Company",
        "integration_uuid" => system_smtp
      })

    :ok = External.subscribe(alice_mb.uuid)

    %{
      admin: admin,
      alice: alice,
      bob: bob,
      client: client,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      common: common,
      system_smtp: system_smtp,
      scope: scope_for(alice, @external)
    }
  end

  defp send_mail(ctx, extra, opts \\ []) do
    Messages.send_message(
      Keyword.get(opts, :scope, ctx.scope),
      Keyword.get(opts, :mailbox, ctx.alice_mb),
      Map.merge(
        %{
          "to" => "@#{ctx.bob.username}, client@example.com",
          "cc" => "partner@example.com",
          "bcc" => "hidden@example.com",
          "subject" => "Offer",
          "body" => "Hello **there**\nsecond line",
          "body_format" => "markdown",
          "identity_uuid" => ctx.common.uuid,
          "reply_to" => ctx.alice.email
        },
        extra
      ),
      Keyword.get(opts, :send_opts, [])
    )
    |> tap(fn
      {:ok, %Message{external_status: :pending} = message} -> await_external(message.uuid)
      _ -> :ok
    end)
  end

  defp rows(message), do: External.list(message.uuid)

  describe "a mixed send" do
    test "delivers inside, writes the external rows, and sends one email after the commit",
         ctx do
      assert {:ok, %Message{external_status: :pending} = message} = send_mail(ctx, %{})

      # Internal part: bob got his copy as always.
      assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
      assert uuid == message.uuid

      assert [
               %ExternalRecipient{role: "to", address: "client@example.com", status: "sent"},
               %ExternalRecipient{role: "cc", address: "partner@example.com", status: "sent"},
               %ExternalRecipient{role: "bcc", address: "hidden@example.com", status: "sent"}
             ] = rows(message)

      assert Enum.all?(rows(message), &match?(%DateTime{}, &1.attempted_at))

      assert_received {:outbound, email, integration, opts}
      refute_received {:outbound, _, _, _}

      assert integration == ctx.system_smtp
      assert email.from == {"Alice Smith | Company", "noreply@company.test"}
      assert email.to == [{"", "client@example.com"}]
      assert email.cc == [{"", "partner@example.com"}]
      assert email.bcc == [{"", "hidden@example.com"}]
      assert email.reply_to == {"", ctx.alice.email}
      assert email.subject == "Offer"
      assert email.html_body == Phoenix.HTML.safe_to_string(Body.markdown_html(message.body))
      assert email.html_body =~ "<strong>there</strong>"
      assert email.text_body =~ "Hello"
      refute email.text_body =~ "**"

      # The emails queue is bypassed and the log can find the message.
      assert opts[:skip_queue] == true
      assert opts[:queue] == false
      assert opts[:user_uuid] == ctx.alice.uuid
      assert opts[:integration_uuid] == ctx.system_smtp
      assert opts[:message_tags]["inbox_message_uuid"] == message.uuid
      assert opts[:message_tags]["source"] == "inbox"
    end

    test "a message to external addresses only has no internal copy but the sender's", ctx do
      assert {:ok, message} =
               send_mail(ctx, %{"to" => "client@example.com", "cc" => "", "bcc" => ""})

      assert Messages.list_recipients(message.uuid) == []
      assert [%{status: "sent"}] = rows(message)
      assert [_] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    end

    test "the same address twice is one recipient, with the stronger role", ctx do
      assert {:ok, message} =
               send_mail(ctx, %{
                 "to" => "Client@Example.com",
                 "cc" => "client@example.com",
                 "bcc" => ""
               })

      assert [%{role: "to", address: "Client@Example.com"}] = rows(message)
    end

    test "a non-member's email is an external address; a non-member's username is not", ctx do
      assert {:ok, message} = send_mail(ctx, %{"to" => ctx.client.email, "cc" => "", "bcc" => ""})
      assert [%{address: "client@example.com"}] = rows(message)

      assert {:error, {:unknown_recipients, ["@" <> _]}} =
               send_mail(ctx, %{"to" => "@" <> ctx.client.username, "cc" => "", "bcc" => ""})
    end

    test "the activity counts external recipients and attachments, and names nobody", ctx do
      assert {:ok, message} = send_mail(ctx, %{})

      row =
        assert_activity_logged("inbox.message_sent",
          resource_uuid: message.uuid,
          metadata_has: %{
            "internal_recipients" => 1,
            "external_recipients" => 3,
            "attachments" => 0
          }
        )

      refute inspect(row) =~ "example.com"
    end
  end

  describe "who may write externally" do
    test "without the filter (nor :none) the send is refused and nothing is written", ctx do
      outbound_filter(nil)

      assert send_mail(ctx, %{}) == {:error, :external_disabled}
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      assert Messages.list_folder(ctx.bob_mb.uuid, "inbox") == []
      refute_received {:outbound, _, _, _}
    end

    test "with the setting off the send is refused", ctx do
      {:ok, _} = PhoenixKitInbox.set_external_enabled(false)
      assert send_mail(ctx, %{}) == {:error, :external_disabled}
      refute_received {:outbound, _, _, _}
    end

    test "without inbox.send_external an email address is an unknown recipient", ctx do
      assert send_mail(ctx, %{"identity_uuid" => ""}, scope: scope_for(ctx.alice)) ==
               {:error,
                {:unknown_recipients,
                 ["client@example.com", "partner@example.com", "hidden@example.com"]}}

      refute_received {:outbound, _, _, _}
    end

    test "nor can the common sender be used without it", ctx do
      assert send_mail(ctx, %{}, scope: scope_for(ctx.alice)) ==
               {:error, {:identity_unusable, :forbidden}}
    end

    test "a personal sender writes externally without inbox.send_external", ctx do
      own = mail_integration_fixture({:user, ctx.alice.uuid}, username: "alice@own.test")

      {:ok, personal} =
        Identities.create_personal(scope_for(ctx.alice), %{
          "label" => "Mine",
          "integration_uuid" => own
        })

      assert {:ok, message} =
               send_mail(ctx, %{"identity_uuid" => personal.uuid}, scope: scope_for(ctx.alice))

      assert Enum.all?(rows(message), &(&1.status == "sent"))
      assert_received {:outbound, email, ^own, _opts}
      assert email.from == {"Alice Smith", "alice@own.test"}
    end

    test "an external address needs a sending identity", ctx do
      assert send_mail(ctx, %{"identity_uuid" => ""}) == {:error, :external_needs_identity}
    end

    test "another user's personal sender is refused", ctx do
      own = mail_integration_fixture({:user, ctx.bob.uuid})

      {:ok, bobs} =
        Identities.create_personal(scope_for(ctx.bob), %{
          "label" => "Bob",
          "integration_uuid" => own
        })

      assert send_mail(ctx, %{"identity_uuid" => bobs.uuid}) ==
               {:error, {:identity_unusable, :forbidden}}

      refute_received {:outbound, _, _, _}
    end

    test "a sender whose connection broke is refused before anything is written", ctx do
      :ok = Integrations.remove_connection(ctx.system_smtp, nil, owner: :system)

      assert send_mail(ctx, %{}) == {:error, {:identity_unusable, :broken}}
      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      refute_received {:outbound, _, _, _}
    end

    test "the three-argument form sends nothing outside: an address is unknown", ctx do
      assert Messages.send_message(ctx.alice_mb, ctx.alice.uuid, %{
               "to" => "client@example.com",
               "subject" => "Hi"
             }) == {:error, {:unknown_recipients, ["client@example.com"]}}

      refute_received {:outbound, _, _, _}
    end
  end

  describe "attachments for external recipients" do
    setup :storage_setup

    test "travel as real attachments", ctx do
      assert {:ok, message} =
               send_mail(ctx, %{"cc" => "", "bcc" => ""},
                 send_opts: [
                   attachments_data: [
                     %{
                       binary: "PDF BYTES",
                       filename: "offer.pdf",
                       content_type: "application/pdf"
                     }
                   ]
                 ]
               )

      assert [%{status: "sent"}] = rows(message)
      assert_received {:outbound, email, _integration, _opts}

      assert [%Swoosh.Attachment{filename: "offer.pdf", data: "PDF BYTES"} = attachment] =
               email.attachments

      assert attachment.content_type == "application/pdf"
    end

    test "above the limit, counted as base64, the send is refused before anything is stored",
         ctx do
      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module(
          "inbox_external_max_bytes",
          "1000",
          "inbox"
        )

      # 750 bytes are 1000 as base64, plus line breaks: over the limit.
      data = [%{binary: String.duplicate("x", 750), filename: "big.bin", content_type: nil}]

      assert send_mail(ctx, %{}, send_opts: [attachments_data: data]) ==
               {:error, {:external_too_large, 1000}}

      assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
      {:ok, library} = PhoenixKitInbox.Attachments.ensure_library()
      assert files_in_library(library.uuid) == []

      # 600 bytes are 800 as base64: fine.
      small = [%{binary: String.duplicate("x", 600), filename: "ok.bin", content_type: nil}]
      assert {:ok, _message} = send_mail(ctx, %{}, send_opts: [attachments_data: small])
    end

    test "the limit does not apply to an internal-only message", ctx do
      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module("inbox_external_max_bytes", "10", "inbox")

      data = [%{binary: String.duplicate("x", 750), filename: "big.bin", content_type: nil}]

      assert {:ok, %Message{external_status: :none}} =
               send_mail(ctx, %{"to" => "@" <> ctx.bob.username, "cc" => "", "bcc" => ""},
                 send_opts: [attachments_data: data]
               )
    end
  end

  describe "status" do
    test "a refusing filter fails the external part and keeps the internal one", ctx do
      outbound_filter({OutboundFilters, :refuse})

      assert {:ok, message} = send_mail(ctx, %{})
      assert [_] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")

      assert Enum.all?(rows(message), &(&1.status == "failed"))
      assert hd(rows(message)).error =~ "no_test_address"
      refute_received {:outbound, _, _, _}
    end

    test "a filter that raises fails it the same way", ctx do
      outbound_filter({OutboundFilters, :raises})

      assert {:ok, message} = send_mail(ctx, %{})
      assert Enum.all?(rows(message), &(&1.status == "failed" and &1.error =~ "filter_failed"))
    end

    test "a transport error fails it", ctx do
      outbound_result({:error, {:smtp, "550 rejected"}})

      assert {:ok, message} = send_mail(ctx, %{})
      assert [%{status: "failed", error: error, email_log_message_id: nil} | _] = rows(message)
      assert error =~ "550 rejected"
    end

    test "a sent email links the email log row", ctx do
      outbound_result(fn _email, _uuid, opts ->
        email_log_fixture(opts[:message_tags])
        {:ok, %{id: "x"}}
      end)

      assert {:ok, message} = send_mail(ctx, %{})

      [%{message_id: logged}] = PhoenixKitInbox.EmailLog.rows(message.uuid)
      assert Enum.all?(rows(message), &(&1.email_log_message_id == logged))
    end

    test "pending, then unknown after 15 minutes" do
      now = DateTime.utc_now()
      row = %ExternalRecipient{status: "pending", inserted_at: DateTime.add(now, -60)}

      assert External.display_status(row, now) == :pending

      assert External.display_status(%{row | inserted_at: DateTime.add(now, -16 * 60)}, now) ==
               :unknown

      assert External.display_status(%{row | status: "sent"}, now) == :sent
      assert External.display_status(%{row | status: "failed"}, now) == :failed
    end
  end

  describe "Bcc" do
    test "external Bcc recipients are shown to the sending mailbox only", ctx do
      assert {:ok, message} = send_mail(ctx, %{})

      assert ctx.alice_mb.uuid
             |> then(&Messages.list_external_recipients(message.uuid, &1))
             |> Enum.map(& &1.role) == ~w(to cc bcc)

      assert ctx.bob_mb.uuid
             |> then(&Messages.list_external_recipients(message.uuid, &1))
             |> Enum.map(& &1.role) == ~w(to cc)

      assert message.uuid |> Messages.list_external_recipients(nil) |> Enum.map(& &1.role) ==
               ~w(to cc)
    end
  end

  describe "retry" do
    setup ctx do
      outbound_result({:error, :smtp_down})
      {:ok, message} = send_mail(ctx, %{})
      assert_received {:outbound, _, _, _}
      emails_module_enabled!()
      email_log_fixture(%{"inbox_message_uuid" => message.uuid, "source" => "inbox"}, "failed")
      outbound_result({:ok, %{id: "ok"}})
      %{message: message}
    end

    test "re-sends the failed rows once; a second retry has nothing to send", ctx do
      assert Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid) ==
               {:ok, :pending}

      # Taken at once: a retry while the first is under way finds nothing.
      assert Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid) ==
               {:error, :nothing_to_retry}

      await_external(ctx.message.uuid)

      assert Enum.all?(rows(ctx.message), &(&1.status == "sent"))
      assert_received {:outbound, email, integration, opts}
      refute_received {:outbound, _, _, _}

      assert integration == ctx.system_smtp
      assert length(email.to ++ email.cc ++ email.bcc) == 3
      assert opts[:skip_queue] == true and opts[:queue] == false

      assert Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid) ==
               {:error, :nothing_to_retry}
    end

    test "is offered only while every log row failed", ctx do
      assert Messages.retry_available?(ctx.message)

      email_log_fixture(%{"inbox_message_uuid" => ctx.message.uuid}, "delivered")

      refute Messages.retry_available?(ctx.message)

      assert Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid) ==
               {:error, :external_maybe_delivered}

      refute_received {:outbound, _, _, _}
    end

    test "a nudge's log row does not count as the message's send", ctx do
      email_log_fixture(
        %{"inbox_message_uuid" => ctx.message.uuid, "inbox_kind" => "nudge"},
        "sent"
      )

      assert Messages.retry_available?(ctx.message)
    end

    test "needs phoenix_kit_emails", ctx do
      Application.put_env(:phoenix_kit_inbox, :test_emails_enabled, false)

      refute Messages.retry_available?(ctx.message)

      assert Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid) ==
               {:error, :retry_unavailable}
    end

    test "only from the sending mailbox, by someone who may write from it", ctx do
      assert Messages.retry_external(
               scope_for(ctx.bob, @external),
               ctx.alice_mb,
               ctx.message.uuid
             ) ==
               {:error, :mailbox_access_denied}

      assert Messages.retry_external(scope_for(ctx.bob, @external), ctx.bob_mb, ctx.message.uuid) ==
               {:error, :message_not_found}

      refute_received {:outbound, _, _, _}
    end

    test "checks the right to write externally again", ctx do
      assert Messages.retry_external(scope_for(ctx.alice), ctx.alice_mb, ctx.message.uuid) ==
               {:error, {:identity_unusable, :forbidden}}

      assert Enum.all?(rows(ctx.message), &(&1.status == "failed"))
    end

    test "goes through the filter like the first send", ctx do
      outbound_filter({OutboundFilters, :redirect})

      assert {:ok, :pending} =
               Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid)

      await_external(ctx.message.uuid)
      assert_received {:outbound, %{to: [{"", "redirect@test.example"}]}, _, _}
    end

    test "refuses while external sending is closed", ctx do
      outbound_filter(nil)

      assert Messages.retry_external(ctx.scope, ctx.alice_mb, ctx.message.uuid) ==
               {:error, :external_disabled}

      assert Enum.all?(rows(ctx.message), &(&1.status == "failed"))
    end
  end
end
