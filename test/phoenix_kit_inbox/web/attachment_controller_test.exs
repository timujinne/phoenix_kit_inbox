defmodule PhoenixKitInbox.Web.AttachmentControllerTest do
  @moduledoc """
  The download route, through the routes `PhoenixKitInbox.Web.Routes`
  generates (mounted in the test router): the file is streamed as an
  attachment to the people on the message, and a 404 to everyone else.
  """

  use PhoenixKitInbox.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths
  alias PhoenixKitInbox.Test.Repo

  setup :storage_setup

  setup do
    enable_inbox!()

    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()
    {:ok, alice_box} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, _} = Mailboxes.ensure_user_mailbox(bob)

    {:ok, message} =
      Messages.send_message(
        scope_for(alice),
        alice_box,
        %{"to" => "@#{bob.username}", "subject" => "Report"},
        attachments_data: [
          %{binary: "%PDF report", filename: "Отчёт \"Q3\".pdf", content_type: "application/pdf"}
        ]
      )

    [row] = Attachments.list_for_message(message.uuid)
    %{alice: alice, bob: bob, carol: carol, row: row}
  end

  defp download(conn, scope, row) do
    conn
    |> put_test_scope(scope)
    |> get(Paths.attachment(row.uuid))
  end

  test "the path is the module's, under the admin area, without a locale", %{row: row} do
    assert Paths.attachment(row.uuid) == "/admin/inbox/files/#{row.uuid}"
    assert PhoenixKitInbox.route_module() == PhoenixKitInbox.Web.Routes
  end

  test "a recipient gets the bytes as a download", %{conn: conn, bob: bob, row: row} do
    conn = download(conn, scope_for(bob), row)

    assert conn.status == 200
    assert conn.resp_body == "%PDF report"
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/^attachment; filename="[^"]+\.pdf"; filename\*=UTF-8''/
    assert disposition =~ URI.encode("Отчёт", &URI.char_unreserved?/1)
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["sandbox"]
  end

  test "the sender too", %{conn: conn, alice: alice, row: row} do
    assert download(conn, scope_for(alice), row).status == 200
  end

  test "anyone else gets a 404, never a redirect to Storage", %{
    conn: conn,
    carol: carol,
    row: row
  } do
    conn = download(conn, scope_for(carol), row)

    assert conn.status == 404
    assert get_resp_header(conn, "location") == []
    refute conn.resp_body =~ "%PDF"
  end

  test "no scope, no inbox permission: 404", %{conn: conn, bob: bob, row: row} do
    assert conn |> get(Paths.attachment(row.uuid)) |> Map.fetch!(:status) == 404
    assert download(conn, scope_for(bob, []), row).status == 404
  end

  test "a made-up uuid: 404", %{conn: conn, bob: bob} do
    assert conn
           |> put_test_scope(scope_for(bob))
           |> get("/admin/inbox/files/#{Ecto.UUID.generate()}")
           |> Map.fetch!(:status) == 404
  end

  test "a row naming a file outside the Inbox library: 404", ctx do
    media = stored_file_fixture(ctx.carol, "carol's media file")
    forged = ctx.row |> Ecto.Changeset.change(file_uuid: media.uuid) |> Repo.update!()

    conn = download(ctx.conn, scope_for(ctx.bob), forged)
    assert conn.status == 404
    refute conn.resp_body =~ "carol"
  end

  def refuse(_scope, _users, _rows), do: {:error, :money}

  test "the policy is asked at download (404 when it refuses); not for the sender", ctx do
    Application.put_env(:phoenix_kit_inbox, :attachment_policy, {__MODULE__, :refuse})

    on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :attachment_policy) end)

    assert download(ctx.conn, scope_for(ctx.bob), ctx.row).status == 404
    assert download(ctx.conn, scope_for(ctx.alice), ctx.row).status == 200
  end

  test "bytes gone from Storage: 404", %{conn: conn, bob: bob, row: row} do
    {:ok, _} = Storage.delete_file_completely(row.file_uuid)
    assert download(conn, scope_for(bob), row).status == 404
  end
end
