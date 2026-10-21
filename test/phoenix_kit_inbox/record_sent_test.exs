defmodule PhoenixKitInbox.RecordSentTest do
  @moduledoc """
  `Messages.record_sent/4` — the host sent an email itself and records it in
  the sender's Sent folder: no internal delivery, no outbound mail, no files,
  no retry.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Delivery
  alias PhoenixKitInbox.Schemas.Message

  setup :outbound_setup

  setup do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    desk = shared_mailbox_fixture(alice, %{name: "Desk", address: "desk@company.test"})
    %{alice: alice, bob: bob, alice_mb: alice_mb, desk: desk}
  end

  defp attrs(extra) do
    Map.merge(
      %{
        "subject" => "Offer 12",
        "body" => "Please find the offer attached.",
        "external_recipients" => [
          %{"address" => "client@example.com", "name" => "Client", "status" => "sent"},
          %{
            "address" => "boss@example.com",
            "role" => "cc",
            "status" => "failed",
            "error" => "550"
          }
        ],
        "attachments" => [%{"filename" => "offer.pdf", "size_bytes" => 1234}]
      },
      extra
    )
  end

  test "records the email in Sent with its recipients' outcome and no files", ctx do
    assert {:ok, %Message{} = message} =
             Messages.record_sent(scope_for(ctx.alice), ctx.alice_mb, attrs(%{}),
               host_ref: "send-42"
             )

    assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.alice_mb.uuid, "sent")
    assert uuid == message.uuid

    # The sender's copy and nothing else.
    assert [%Delivery{role: "from"}] =
             Repo.all(from(d in Delivery, where: d.message_uuid == ^message.uuid))

    assert [
             %{role: "to", address: "client@example.com", name: "Client", status: "sent"},
             %{role: "cc", address: "boss@example.com", status: "failed", error: "550"}
           ] = External.list(message.uuid)

    assert message.metadata["source"] == "host"
    assert message.metadata["host_ref"] == "send-42"
    assert message.metadata["attachments"] == [%{"filename" => "offer.pdf", "size_bytes" => 1234}]
    assert PhoenixKitInbox.Attachments.list_for_message(message.uuid) == []
    refute_received {:outbound, _, _, _}

    assert_activity_logged("inbox.message_sent",
      resource_uuid: message.uuid,
      metadata_has: %{"internal_recipients" => 0, "external_recipients" => 2, "attachments" => 1}
    )
  end

  test "an internal address is refused and nothing is written", ctx do
    for address <- [ctx.bob.email, "desk@company.test"] do
      recipients = [%{"address" => "client@example.com"}, %{"address" => address}]

      assert Messages.record_sent(
               scope_for(ctx.alice),
               ctx.alice_mb,
               attrs(%{"external_recipients" => recipients})
             ) == {:error, {:internal_recipients, [address]}}
    end

    assert Messages.list_folder(ctx.alice_mb.uuid, "sent") == []
    assert Repo.aggregate(Delivery, :count) == 0
  end

  test "a username or a malformed entry is not an external recipient", ctx do
    assert {:error, {:invalid_external_recipients, ["@" <> _]}} =
             Messages.record_sent(
               scope_for(ctx.alice),
               ctx.alice_mb,
               attrs(%{"external_recipients" => [%{"address" => "@" <> ctx.bob.username}]})
             )

    assert {:error, {:invalid_external_recipients, ["x@example.com"]}} =
             Messages.record_sent(
               scope_for(ctx.alice),
               ctx.alice_mb,
               attrs(%{
                 "external_recipients" => [%{"address" => "x@example.com", "role" => "from"}]
               })
             )

    assert Messages.record_sent(
             scope_for(ctx.alice),
             ctx.alice_mb,
             attrs(%{"external_recipients" => []})
           ) == {:error, :no_recipients}
  end

  test "values longer than their columns: an address or a log id is refused, a name cut", ctx do
    long_address = String.duplicate("a", 250) <> "@example.com"

    assert Messages.record_sent(
             scope_for(ctx.alice),
             ctx.alice_mb,
             attrs(%{"external_recipients" => [%{"address" => long_address}]})
           ) == {:error, {:invalid_external_recipients, [long_address]}}

    long_id = %{
      "address" => "client@example.com",
      "email_log_message_id" => String.duplicate("x", 256)
    }

    assert Messages.record_sent(
             scope_for(ctx.alice),
             ctx.alice_mb,
             attrs(%{"external_recipients" => [long_id]})
           ) == {:error, {:invalid_external_recipients, ["client@example.com"]}}

    long_name = %{"address" => "client@example.com", "name" => String.duplicate("N", 300)}

    assert {:ok, message} =
             Messages.record_sent(
               scope_for(ctx.alice),
               ctx.alice_mb,
               attrs(%{"external_recipients" => [long_name]})
             )

    assert [%{name: name}] = External.list(message.uuid)
    assert String.length(name) == 255
  end

  test "To, Cc and Bcc are not taken — internal mail is send_message's", ctx do
    assert Messages.record_sent(
             scope_for(ctx.alice),
             ctx.alice_mb,
             attrs(%{"to" => "@" <> ctx.bob.username})
           ) == {:error, :use_external_recipients}

    assert Repo.aggregate(Delivery, :count) == 0
  end

  test "needs write on the mailbox and the inbox permission", ctx do
    assert Messages.record_sent(scope_for(ctx.bob), ctx.alice_mb, attrs(%{})) ==
             {:error, :mailbox_access_denied}

    assert Messages.record_sent(scope_for(ctx.alice, []), ctx.alice_mb, attrs(%{})) ==
             {:error, :forbidden}

    grant_fixture(ctx.desk, ctx.bob, "read")

    assert Messages.record_sent(scope_for(ctx.bob), ctx.desk, attrs(%{})) ==
             {:error, :mailbox_access_denied}
  end

  test "a recorded message offers no retry", ctx do
    {:ok, message} = Messages.record_sent(scope_for(ctx.alice), ctx.alice_mb, attrs(%{}))
    emails_module_enabled!()

    refute Messages.retry_available?(message)

    assert Messages.retry_external(
             scope_for(ctx.alice, ["inbox", "inbox.send_external"]),
             ctx.alice_mb,
             message.uuid
           ) == {:error, :retry_unavailable}

    refute_received {:outbound, _, _, _}
  end
end
