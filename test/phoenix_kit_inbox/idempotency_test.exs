defmodule PhoenixKitInbox.IdempotencyTest do
  @moduledoc """
  The send key a host gives `Messages.send_message/4`: repeating a send with
  the same key answers with the message already sent and does nothing else —
  no second row, no second email, no second nudge.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.External
  alias PhoenixKitInbox.Identities
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Message
  alias PhoenixKitInbox.Schemas.SendKey

  @external ["inbox", "inbox.send_external"]

  defmodule RacingPolicy do
    @moduledoc false
    # Asked between the key's early check and the insert: while it runs, a
    # rival send with the same key (the one in the application environment)
    # gets in first.
    def race(_scope, _users, _rows) do
      if Process.get(:racing) do
        :ok
      else
        Process.put(:racing, true)
        {scope, mailbox, attrs, opts} = Application.fetch_env!(:phoenix_kit_inbox, :rival)
        {:ok, winner} = Messages.send_message(scope, mailbox, attrs, opts)
        Application.put_env(:phoenix_kit_inbox, :rival_result, winner)
        :ok
      end
    end
  end

  setup :storage_setup
  setup :outbound_setup

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture(%{email: "bob@company.test"})
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

    on_exit(fn ->
      for key <- [:attachment_policy, :rival, :rival_result],
          do: Application.delete_env(:phoenix_kit_inbox, key)
    end)

    %{
      alice: alice,
      bob: bob,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      common: common,
      manager: manager,
      scope: scope_for(alice, @external, [senders])
    }
  end

  defp attrs(ctx, extra \\ %{}) do
    Map.merge(%{"to" => "@#{ctx.bob.username}", "subject" => "Once"}, extra)
  end

  defp send_keyed(ctx, key, extra \\ %{}, opts \\ []) do
    Messages.send_message(
      ctx.scope,
      ctx.alice_mb,
      attrs(ctx, extra),
      Keyword.put(opts, :idempotency_key, key)
    )
  end

  defp message_count(subject),
    do: Repo.aggregate(from(m in Message, where: m.subject == ^subject), :count)

  defp key_rows, do: Repo.all(from(k in SendKey, order_by: k.inserted_at))

  defp age_keys!(keys, days) do
    Repo.query!(
      "UPDATE phoenix_kit_inbox_send_keys SET inserted_at = now() - make_interval(days => $2) WHERE key = ANY($1)",
      [keys, days]
    )
  end

  test "same key returns the first message, creates no second", ctx do
    assert {:ok, first} = send_keyed(ctx, "form-1")
    assert {:ok, again} = send_keyed(ctx, "form-1")

    assert again.uuid == first.uuid
    assert again.subject == "Once"
    assert message_count("Once") == 1
    assert [%{message: %{uuid: uuid}}] = Messages.list_folder(ctx.bob_mb.uuid, "inbox")
    assert uuid == first.uuid
    assert [%SendKey{key: "form-1", message_uuid: ^uuid}] = key_rows()
  end

  test "another key is another send", ctx do
    {:ok, first} = send_keyed(ctx, "form-1")
    {:ok, second} = send_keyed(ctx, "form-2")

    refute second.uuid == first.uuid
    assert message_count("Once") == 2
  end

  test "a failed send leaves no key, so the retry goes through", ctx do
    assert {:error, {:unknown_recipients, _}} =
             Messages.send_message(
               ctx.scope,
               ctx.alice_mb,
               %{"to" => "@nobody-here", "subject" => "Once"},
               idempotency_key: "form-1"
             )

    assert key_rows() == []
    assert {:ok, _} = send_keyed(ctx, "form-1")
    assert [_] = key_rows()
  end

  test "someone else's key is refused, not answered with their message", ctx do
    {:ok, _} = send_keyed(ctx, "form-1")
    carol = user_fixture()
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    assert {:error, :idempotency_key_taken} =
             Messages.send_message(
               scope_for(carol),
               carol_mb,
               attrs(ctx),
               idempotency_key: "form-1"
             )

    assert message_count("Once") == 1
  end

  test "duplicate triggers no second external delivery or nudge", ctx do
    {:ok, _} = PhoenixKitInbox.set_email_nudges(true)
    {:ok, _} = PhoenixKitInbox.set_nudge_identity(ctx.manager, ctx.common.uuid)
    :ok = External.subscribe(ctx.alice_mb.uuid)

    extra = %{
      "to" => "@#{ctx.bob.username}, client@example.com",
      "identity_uuid" => ctx.common.uuid
    }

    assert {:ok, %Message{external_status: :pending} = first} = send_keyed(ctx, "form-1", extra)
    await_external(first.uuid)

    # The external email and bob's nudge, once each.
    assert_receive {:outbound, %{to: [{"", "client@example.com"}]}, _, _}, 2_000
    assert_receive {:outbound, %{to: [{"", "bob@company.test"}]}, _, _}, 2_000
    activities = length(list_activities())

    assert {:ok, again} = send_keyed(ctx, "form-1", extra)

    assert again.uuid == first.uuid
    refute_receive {:outbound, _, _, _}, 300
    refute_receive {:inbox_external_updated, _}, 100
    assert length(list_activities()) == activities
    assert [_] = External.list(first.uuid)
  end

  test "concurrent sends with one key create one message", ctx do
    results =
      1..2
      |> Task.async_stream(fn _ -> send_keyed(ctx, "form-1") end, timeout: 10_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, a}, {:ok, b}] = results
    assert a.uuid == b.uuid
    assert message_count("Once") == 1
    assert [_] = key_rows()
  end

  test "the loser of a race gets the winner's message and leaves no snapshot", ctx do
    attachment = [attachments_data: [%{binary: "bytes", filename: "a.txt"}]]

    Application.put_env(:phoenix_kit_inbox, :attachment_policy, {RacingPolicy, :race})

    Application.put_env(
      :phoenix_kit_inbox,
      :rival,
      {ctx.scope, ctx.alice_mb, attrs(ctx), attachment ++ [idempotency_key: "form-1"]}
    )

    assert {:ok, loser_result} = send_keyed(ctx, "form-1", %{}, attachment)

    winner = Application.fetch_env!(:phoenix_kit_inbox, :rival_result)
    assert loser_result.uuid == winner.uuid
    assert message_count("Once") == 1
    assert [_] = key_rows()
    assert [_one] = Attachments.list_for_message(winner.uuid)
    assert length(snapshot_files()) == 1
  end

  test "expired keys purged on insert", ctx do
    {:ok, old} = send_keyed(ctx, "old")
    {:ok, recent} = send_keyed(ctx, "recent")
    age_keys!(["old"], 31)
    age_keys!(["recent"], 29)

    {:ok, _} = send_keyed(ctx, "new")

    assert Enum.sort(Enum.map(key_rows(), & &1.key)) == ["new", "recent"]
    # The message of a purged key stays.
    assert message_count("Once") == 3
    assert old.uuid != recent.uuid
  end

  test "no more than 100 expired keys go at once", ctx do
    {:ok, message} = send_keyed(ctx, "seed")

    Repo.query!(
      """
      INSERT INTO phoenix_kit_inbox_send_keys (key, message_uuid, inserted_at)
      SELECT 'old-' || n, $1, now() - interval '40 days' FROM generate_series(1, 101) n
      """,
      [Ecto.UUID.dump!(message.uuid)]
    )

    {:ok, _} = send_keyed(ctx, "new")

    assert Enum.count(key_rows(), &String.starts_with?(&1.key, "old-")) == 1
    assert Enum.any?(key_rows(), &(&1.key == "new"))
  end

  test "key from attrs ignored", ctx do
    extra = %{"idempotency_key" => "from-attrs"}

    {:ok, first} = send_keyed_none(ctx, extra)
    {:ok, second} = send_keyed_none(ctx, extra)

    refute first.uuid == second.uuid
    assert message_count("Once") == 2
    assert key_rows() == []
  end

  test "an empty key is no key", ctx do
    {:ok, first} = send_keyed(ctx, "")
    {:ok, second} = send_keyed(ctx, nil)

    refute first.uuid == second.uuid
    assert key_rows() == []
  end

  defp send_keyed_none(ctx, extra),
    do: Messages.send_message(ctx.scope, ctx.alice_mb, attrs(ctx, extra), [])

  defp snapshot_files do
    alias PhoenixKit.Modules.Storage.Libraries

    case Libraries.get_hidden_library_by_slug(Attachments.library_slug()) do
      nil -> []
      library -> files_in_library(library.uuid)
    end
  end
end
