defmodule PhoenixKitInbox.AttachmentsTest do
  @moduledoc """
  Attachments end to end against real Storage (a local-disk bucket): every
  way a file gets into a message, the snapshot it becomes in the module's
  hidden library, who may forward and download it, the host's policy, and
  what happens to snapshots when a send fails or a draft is discarded.
  """

  use PhoenixKitInbox.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Schemas.Attachment
  alias PhoenixKitInbox.Schemas.Message

  defmodule Policy do
    @moduledoc false
    def record(scope, users, rows) do
      send(
        Application.get_env(:phoenix_kit_inbox, :policy_test_pid),
        {:policy, scope, users, rows}
      )

      :ok
    end

    def refuse(_scope, _users, _rows), do: {:error, :money}

    # Refuses whenever the user registered by the test is among the users.
    def refuse_user(_scope, users, _rows) do
      refused = Application.get_env(:phoenix_kit_inbox, :policy_refused_user)
      if Enum.any?(users, &(&1.uuid == refused)), do: {:error, :money}, else: :ok
    end

    def explode(_scope, _users, _rows), do: raise("policy bug")
    def odd(_scope, _users, _rows), do: :maybe
  end

  setup :storage_setup

  setup do
    enable_inbox!()

    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()

    {:ok, alice_box} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_box} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, carol_box} = Mailboxes.ensure_user_mailbox(carol)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_inbox, :attachment_policy)
      Application.delete_env(:phoenix_kit_inbox, :policy_test_pid)
      Application.delete_env(:phoenix_kit_inbox, :policy_refused_user)
    end)

    %{
      alice: alice,
      bob: bob,
      carol: carol,
      alice_box: alice_box,
      bob_box: bob_box,
      carol_box: carol_box,
      scope: scope_for(alice)
    }
  end

  defp send_to(scope, mailbox, recipient, extra \\ %{}, opts \\ []) do
    attrs = Map.merge(%{"to" => "@#{recipient.username}", "subject" => "Files"}, extra)
    Messages.send_message(scope, mailbox, attrs, opts)
  end

  defp attach(uuids), do: %{"attachments" => Enum.map(List.wrap(uuids), &%{"file_uuid" => &1})}

  defp library_uuid do
    {:ok, library} = Attachments.ensure_library()
    library.uuid
  end

  defp inbox_files do
    case Libraries.get_hidden_library_by_slug(Attachments.library_slug()) do
      nil -> []
      library -> files_in_library(library.uuid)
    end
  end

  defp bytes(file_uuid) do
    {:ok, path, _file} = Storage.retrieve_file(file_uuid)
    content = File.read!(path)
    File.rm(path)
    content
  end

  defp trash!(file) do
    file
    |> Ecto.Changeset.change(
      status: "trashed",
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  defp refuse_user!(user) do
    put_policy(:refuse_user)
    Application.put_env(:phoenix_kit_inbox, :policy_refused_user, user.uuid)
  end

  defp put_policy(fun) do
    Application.put_env(:phoenix_kit_inbox, :attachment_policy, {Policy, fun})
    Application.put_env(:phoenix_kit_inbox, :policy_test_pid, self())
  end

  describe "the module's library" do
    test "is a hidden system library, made once and found again by its slug" do
      assert Libraries.get_hidden_library_by_slug("phoenix-kit-inbox") == nil

      {:ok, library} = Attachments.ensure_library()
      {:ok, again} = Attachments.ensure_library()

      assert again.uuid == library.uuid
      assert library.slug == "phoenix-kit-inbox"
      assert Libraries.hidden?(library)
      refute Enum.any?(Libraries.list_system_libraries(), &(&1.uuid == library.uuid))
    end

    test "callers racing to make it all get the same one" do
      uuids =
        1..4
        |> Task.async_stream(fn _ -> Attachments.ensure_library() end, timeout: 30_000)
        |> Enum.map(fn {:ok, {:ok, library}} -> library.uuid end)
        |> Enum.uniq()

      assert length(uuids) == 1
    end
  end

  describe "a file from Storage (the form's attachments)" do
    test "one's own Media file becomes a snapshot in the Inbox library; the original is untouched",
         ctx do
      original = stored_file_fixture(ctx.alice, "quarterly numbers", filename: "q3.txt")

      {:ok, message} = send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(original.uuid))

      [row] = Attachments.list_for_message(message.uuid)
      assert row.source_file_uuid == original.uuid
      assert row.file_uuid != original.uuid
      assert row.filename == "q3.txt"
      assert row.size_bytes == byte_size("quarterly numbers")
      assert row.flags == %{}

      snapshot = Storage.get_file(row.file_uuid)
      assert snapshot.library_uuid == library_uuid()
      assert bytes(row.file_uuid) == "quarterly numbers"

      after_send = Storage.get_file(original.uuid)
      assert after_send.library_uuid == Libraries.media_uuid()
      assert after_send.status == original.status
      assert after_send.updated_at == original.updated_at
      assert bytes(original.uuid) == "quarterly numbers"
    end

    test "a colleague's file is refused, and nothing is sent or stored", ctx do
      theirs = stored_file_fixture(ctx.carol, "carol's private notes")

      assert {:error, {:attachment_forbidden, uuid}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(theirs.uuid))

      assert uuid == theirs.uuid
      assert inbox_files() == []
      assert Repo.aggregate(Message, :count) == 0
    end

    test "a made-up uuid is refused", ctx do
      forged = Ecto.UUID.generate()

      assert {:error, {:attachment_forbidden, ^forged}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(forged))
    end

    test "a file in the trash is refused", ctx do
      mine = ctx.alice |> stored_file_fixture("old draft") |> trash!()

      assert {:error, {:attachment_unavailable, uuid}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(mine.uuid))

      assert uuid == mine.uuid
    end

    test "an attachment named twice is attached once", ctx do
      mine = stored_file_fixture(ctx.alice, "once")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, attach([mine.uuid, mine.uuid]))

      assert [_one] = Attachments.list_for_message(message.uuid)
    end

    test "the same file attached twice gives two snapshots of their own", ctx do
      mine = stored_file_fixture(ctx.alice, "attached twice")

      {:ok, first} = send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(mine.uuid))
      {:ok, draft} = Messages.save_draft(ctx.scope, ctx.alice_box, attach(mine.uuid))

      [%{file_uuid: one}] = Attachments.list_for_message(first.uuid)
      [%{file_uuid: two}] = Attachments.list_for_message(draft.uuid)
      assert one != two
      assert Enum.map(inbox_files(), &to_string(&1.uuid)) |> Enum.sort() == Enum.sort([one, two])

      :ok = Messages.delete_draft(ctx.scope, ctx.alice_box, draft.uuid)
      assert Storage.get_file(two) == nil
      assert bytes(one) == "attached twice"
    end

    test "a file of another module's hidden library is refused, even to its uploader", ctx do
      {:ok, other} =
        Libraries.create_system_library(%{"name" => "Other Module", "slug" => "other-module"},
          hidden: true
        )

      private = stored_file_fixture(ctx.alice, "other module's", library_uuid: other.uuid)

      assert {:error, {:attachment_forbidden, uuid}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(private.uuid))

      assert uuid == private.uuid
    end

    test "rows keep the order they were given in", ctx do
      first = stored_file_fixture(ctx.alice, "first", filename: "a.txt")
      second = stored_file_fixture(ctx.alice, "second", filename: "b.txt")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, attach([second.uuid, first.uuid]))

      assert ["b.txt", "a.txt"] ==
               message.uuid |> Attachments.list_for_message() |> Enum.map(& &1.filename)
    end
  end

  describe "attachments_authorized (the host vouched for the file)" do
    test "admits a colleague's file as a snapshot", ctx do
      theirs = stored_file_fixture(ctx.carol, "signed contract", filename: "contract.txt")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{}, attachments_authorized: [theirs.uuid])

      [row] = Attachments.list_for_message(message.uuid)
      assert row.source_file_uuid == theirs.uuid
      assert Storage.get_file(row.file_uuid).library_uuid == library_uuid()
      assert bytes(row.file_uuid) == "signed contract"
    end

    test "is never read from the form's attributes", ctx do
      theirs = stored_file_fixture(ctx.carol, "not yours")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{"attachments_authorized" => [theirs.uuid]})

      assert Attachments.list_for_message(message.uuid) == []
    end

    test "still refuses a trashed file", ctx do
      theirs = ctx.carol |> stored_file_fixture("binned") |> trash!()

      assert {:error, {:attachment_unavailable, _}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
                 attachments_authorized: [theirs.uuid]
               )
    end

    test "still refuses a system-managed file", ctx do
      hidden =
        ctx.carol
        |> stored_file_fixture("tile chunk")
        |> Ecto.Changeset.change(system_managed: true)
        |> Repo.update!()

      assert {:error, {:attachment_unavailable, _}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
                 attachments_authorized: [hidden.uuid]
               )
    end

    test "still refuses a file that does not exist", ctx do
      forged = Ecto.UUID.generate()

      assert {:error, {:attachment_forbidden, ^forged}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, %{}, attachments_authorized: [forged])
    end
  end

  describe "attachments_data (bytes the host made)" do
    test "stores a binary and a file path as snapshots, with their flags", ctx do
      path = Path.join(System.tmp_dir!(), "inbox_host_#{System.unique_integer([:positive])}")
      File.write!(path, "%PDF from disk")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [
            %{
              binary: "%PDF in memory",
              filename: "offer.pdf",
              content_type: "application/pdf",
              flags: %{"money_free" => false}
            },
            %{
              path: path,
              filename: "worksheet.pdf",
              content_type: "application/pdf",
              flags: %{"money_free" => true}
            }
          ]
        )

      [offer, worksheet] = Attachments.list_for_message(message.uuid)

      assert offer.filename == "offer.pdf"
      assert offer.content_type == "application/pdf"
      assert offer.flags == %{"money_free" => false}
      assert offer.source_file_uuid == nil
      assert bytes(offer.file_uuid) == "%PDF in memory"

      assert worksheet.flags == %{"money_free" => true}
      assert bytes(worksheet.file_uuid) == "%PDF from disk"

      assert Enum.all?(inbox_files(), &(&1.user_uuid == ctx.alice.uuid))
      # The host's own file is the host's to delete.
      assert File.exists?(path)
      File.rm(path)
    end
  end

  describe "content types" do
    test "only a plain type/subtype is stored; anything else is octet-stream", ctx do
      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [
            %{binary: "a", filename: "a.pdf", content_type: "application/pdf"},
            %{binary: "b", filename: "b.bin", content_type: "text/html; charset=\"x\""},
            %{binary: "c", filename: "c.bin", content_type: "<script>"}
          ]
        )

      assert ["application/pdf", "application/octet-stream", "application/octet-stream"] ==
               message.uuid |> Attachments.list_for_message() |> Enum.map(& &1.content_type)
    end
  end

  describe "flags" do
    test "are never taken from the form", ctx do
      mine = stored_file_fixture(ctx.alice, "a photo")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{
          "attachments" => [%{"file_uuid" => mine.uuid, "flags" => %{"money_free" => true}}]
        })

      assert [%{flags: flags}] = Attachments.list_for_message(message.uuid)
      assert flags == %{}
    end

    test "the schema's changeset does not cast them" do
      changeset =
        Attachment.changeset(%Attachment{}, %{
          "flags" => %{"money_free" => true}
        })

      assert Ecto.Changeset.get_change(changeset, :flags) == nil
    end

    test "come from attachment_flags, keyed by the file named", ctx do
      mine = stored_file_fixture(ctx.alice, "a drawing")
      theirs = stored_file_fixture(ctx.carol, "a worksheet")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(mine.uuid),
          attachments_authorized: [theirs.uuid],
          attachment_flags: %{theirs.uuid => %{"money_free" => true}}
        )

      flags =
        message.uuid
        |> Attachments.list_for_message()
        |> Map.new(&{&1.source_file_uuid, &1.flags})

      assert flags == %{mine.uuid => %{}, theirs.uuid => %{"money_free" => true}}
    end
  end

  describe "a file already in the Inbox library" do
    test "one's own (a saved draft's snapshot) is attached as it is, not copied again", ctx do
      {:ok, draft} =
        Messages.save_draft(ctx.scope, ctx.alice_box, %{"subject" => "WIP"},
          attachments_data: [%{binary: "scanned page", filename: "scan.pdf"}]
        )

      [draft_row] = Attachments.list_for_message(draft.uuid)

      {:ok, message} = send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(draft_row.file_uuid))

      [row] = Attachments.list_for_message(message.uuid)
      assert row.file_uuid == draft_row.file_uuid
      assert row.filename == "scan.pdf"
      assert [_] = inbox_files()
    end

    test "one's own draft snapshot keeps its flags when attached again", ctx do
      {:ok, draft} =
        Messages.save_draft(ctx.scope, ctx.alice_box, %{"subject" => "WIP"},
          attachments_data: [
            %{binary: "sheet", filename: "w.pdf", flags: %{"money_free" => true}}
          ]
        )

      [draft_row] = Attachments.list_for_message(draft.uuid)
      {:ok, message} = send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(draft_row.file_uuid))

      assert [%{flags: %{"money_free" => true}}] = Attachments.list_for_message(message.uuid)
    end

    test "someone else's is refused", ctx do
      {:ok, draft} =
        Messages.save_draft(scope_for(ctx.carol), ctx.carol_box, %{"subject" => "mine"},
          attachments_data: [%{binary: "carol's", filename: "c.txt"}]
        )

      [row] = Attachments.list_for_message(draft.uuid)

      assert {:error, {:attachment_forbidden, _}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(row.file_uuid))
    end
  end

  describe "forwarding" do
    setup ctx do
      {:ok, original} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [
            %{binary: "worksheet", filename: "w.pdf", flags: %{"money_free" => true}}
          ]
        )

      [row] = Attachments.list_for_message(original.uuid)
      %{original: original, row: row}
    end

    test "a recipient forwards the file: the same snapshot, the flags kept", ctx do
      {:ok, forward} =
        send_to(scope_for(ctx.bob), ctx.bob_box, ctx.carol, attach(ctx.row.file_uuid))

      [copy] = Attachments.list_for_message(forward.uuid)
      assert copy.file_uuid == ctx.row.file_uuid
      assert copy.flags == %{"money_free" => true}
      assert copy.filename == "w.pdf"
      assert length(inbox_files()) == 1
    end

    test "the sender may forward it too", ctx do
      assert {:ok, _} =
               send_to(ctx.scope, ctx.alice_box, ctx.carol, attach(ctx.row.file_uuid))
    end

    test "someone who never had the message cannot", ctx do
      assert {:error, {:attachment_forbidden, _}} =
               send_to(scope_for(ctx.carol), ctx.carol_box, ctx.bob, attach(ctx.row.file_uuid))
    end

    test "a deleted copy no longer lets the recipient forward", ctx do
      :ok = Messages.purge(scope_for(ctx.bob), ctx.bob_box, ctx.original.uuid)

      assert {:error, {:attachment_forbidden, _}} =
               send_to(scope_for(ctx.bob), ctx.bob_box, ctx.carol, attach(ctx.row.file_uuid))
    end
  end

  describe "limits" do
    test "more than 50 files are refused before anything is stored", ctx do
      data = for n <- 1..51, do: %{binary: "f#{n}", filename: "f#{n}.txt"}

      assert {:error, {:too_many_attachments, 50}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, %{}, attachments_data: data)

      assert inbox_files() == []
    end

    test "a file over inbox_max_upload_bytes is refused", ctx do
      PhoenixKit.Settings.update_setting("inbox_max_upload_bytes", "10")
      assert Attachments.max_upload_bytes() == 10

      assert {:error, {:attachment_too_large, "big.bin"}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
                 attachments_data: [%{binary: String.duplicate("x", 11), filename: "big.bin"}]
               )

      mine = stored_file_fixture(ctx.alice, String.duplicate("y", 11), filename: "big.txt")

      assert {:error, {:attachment_too_large, "big.txt"}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(mine.uuid))

      assert inbox_files() == []
    end

    test "the default limit is 200 MB" do
      assert Attachments.max_upload_bytes() == 200_000_000
    end
  end

  describe "a send that fails" do
    test "deletes the snapshots it made and leaves the originals", ctx do
      mine = stored_file_fixture(ctx.alice, "keep me")

      assert {:error, %Ecto.Changeset{}} =
               send_to(
                 ctx.scope,
                 ctx.alice_box,
                 ctx.bob,
                 Map.merge(attach(mine.uuid), %{"subject" => String.duplicate("s", 501)}),
                 attachments_data: [%{binary: "host pdf", filename: "h.pdf"}]
               )

      assert inbox_files() == []
      assert Repo.aggregate(Message, :count) == 0
      assert bytes(mine.uuid) == "keep me"
    end

    test "through the old three-argument form refuses attachments", ctx do
      mine = stored_file_fixture(ctx.alice, "x")

      assert {:error, :attachments_need_scope} =
               Messages.send_message(ctx.alice_box, ctx.alice.uuid, %{
                 "to" => "@#{ctx.bob.username}",
                 "subject" => "hi",
                 "attachments" => [%{"file_uuid" => mine.uuid}]
               })

      assert {:ok, _} =
               Messages.send_message(ctx.alice_box, ctx.alice.uuid, %{
                 "to" => "@#{ctx.bob.username}",
                 "subject" => "hi",
                 "attachments" => []
               })
    end
  end

  describe "the attachment_policy hook" do
    test "gets the scope, every recipient user (To/Cc/Bcc, shared-mailbox readers) and the rows",
         ctx do
      put_policy(:record)
      dave = user_fixture()
      erin = user_fixture()
      desk = shared_mailbox_fixture(ctx.carol, %{slug: "desk"})
      grant_fixture(desk, dave, "read")

      mine = stored_file_fixture(ctx.alice, "mine")

      {:ok, _} =
        send_to(
          ctx.scope,
          ctx.alice_box,
          ctx.bob,
          Map.merge(attach(mine.uuid), %{"cc" => "desk", "bcc" => "@#{erin.username}"}),
          attachments_data: [%{binary: "pdf", filename: "p.pdf", flags: %{"money_free" => true}}]
        )

      assert_received {:policy, scope, users, rows}
      assert scope == ctx.scope

      assert users |> Enum.map(& &1.uuid) |> Enum.sort() ==
               Enum.sort([ctx.bob.uuid, ctx.carol.uuid, dave.uuid, erin.uuid])

      assert [%{flags: %{}, filename: name}, %{flags: %{"money_free" => true}}] = rows
      assert name == mine.original_file_name
    end

    test "a refusal stops the send and stores nothing", ctx do
      put_policy(:refuse)

      assert {:error, {:attachment_refused, :money}} =
               send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
                 attachments_data: [%{binary: "pdf", filename: "p.pdf"}]
               )

      assert inbox_files() == []
      assert Repo.aggregate(Message, :count) == 0
    end

    test "a policy that raises, or answers anything else, refuses", ctx do
      for fun <- [:explode, :odd] do
        put_policy(fun)

        assert {:error, {:attachment_refused, _}} =
                 send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
                   attachments_data: [%{binary: "pdf", filename: "p.pdf"}]
                 )
      end
    end

    test "is asked on a forward, with the forwarded flags", ctx do
      {:ok, original} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "money", filename: "offer.pdf"}]
        )

      [row] = Attachments.list_for_message(original.uuid)
      put_policy(:refuse)

      assert {:error, {:attachment_refused, :money}} =
               send_to(scope_for(ctx.bob), ctx.bob_box, ctx.carol, attach(row.file_uuid))
    end

    test "is not asked about a message without attachments", ctx do
      put_policy(:refuse)
      assert {:ok, _} = send_to(ctx.scope, ctx.alice_box, ctx.bob)
    end
  end

  describe "the policy and everyone who can read the files" do
    setup ctx do
      dave = user_fixture()
      desk = shared_mailbox_fixture(ctx.carol, %{slug: "desk"})
      grant_fixture(desk, ctx.alice, "write")
      grant_fixture(desk, dave, "read")
      %{dave: dave, desk: desk}
    end

    test "a send from a shared mailbox asks about its readers too (not the sender)", ctx do
      put_policy(:record)

      {:ok, _} =
        send_to(ctx.scope, ctx.desk, ctx.bob, %{},
          attachments_data: [%{binary: "pdf", filename: "p.pdf"}]
        )

      assert_received {:policy, _scope, users, _rows}

      assert users |> Enum.map(& &1.uuid) |> Enum.sort() ==
               Enum.sort([ctx.bob.uuid, ctx.carol.uuid, ctx.dave.uuid])

      refuse_user!(ctx.dave)

      assert {:error, {:attachment_refused, :money}} =
               send_to(ctx.scope, ctx.desk, ctx.bob, %{},
                 attachments_data: [%{binary: "pdf", filename: "p.pdf"}]
               )
    end

    test "a draft in a shared mailbox asks about its readers; a personal one asks no one", ctx do
      refuse_user!(ctx.dave)

      assert {:error, {:attachment_refused, :money}} =
               Messages.save_draft(ctx.scope, ctx.desk, %{"subject" => "WIP"},
                 attachments_data: [%{binary: "pdf", filename: "p.pdf"}]
               )

      assert inbox_files() == []

      put_policy(:refuse)

      assert {:ok, _} =
               Messages.save_draft(ctx.scope, ctx.alice_box, %{"subject" => "WIP"},
                 attachments_data: [%{binary: "pdf", filename: "p.pdf"}]
               )
    end

    test "a reader granted after the send is asked at download", ctx do
      {:ok, message} =
        Messages.send_message(ctx.scope, ctx.alice_box, %{"to" => "desk", "subject" => "x"},
          attachments_data: [%{binary: "priced", filename: "offer.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      erin = user_fixture()
      grant_fixture(ctx.desk, erin, "read")
      refuse_user!(erin)

      assert {:error, :not_found} = Attachments.fetch_for_download(scope_for(erin), row.uuid)
      assert {:ok, _} = Attachments.fetch_for_download(scope_for(ctx.dave), row.uuid)
    end

    test "a reader granted later cannot launder the file through a forward", ctx do
      {:ok, message} =
        Messages.send_message(ctx.scope, ctx.alice_box, %{"to" => "desk", "subject" => "x"},
          attachments_data: [%{binary: "priced", filename: "offer.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      erin = user_fixture()
      {:ok, erin_box} = Mailboxes.ensure_user_mailbox(erin)
      grant_fixture(ctx.desk, erin, "read")
      refuse_user!(erin)

      assert {:error, {:attachment_refused, :money}} =
               send_to(scope_for(erin), erin_box, ctx.alice, attach(row.file_uuid))
    end

    test "a forwarder is asked at download about a file they did not create", ctx do
      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "priced", filename: "offer.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      {:ok, forward} = send_to(scope_for(ctx.bob), ctx.bob_box, ctx.carol, attach(row.file_uuid))
      [copy] = Attachments.list_for_message(forward.uuid)

      refuse_user!(ctx.bob)
      assert {:error, :not_found} = Attachments.fetch_for_download(scope_for(ctx.bob), copy.uuid)
    end

    test "a reader granted later cannot launder the file into a personal draft", ctx do
      {:ok, message} =
        Messages.send_message(ctx.scope, ctx.alice_box, %{"to" => "desk", "subject" => "x"},
          attachments_data: [%{binary: "priced", filename: "offer.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      erin = user_fixture()
      {:ok, erin_box} = Mailboxes.ensure_user_mailbox(erin)
      grant_fixture(ctx.desk, erin, "read")
      refuse_user!(erin)

      assert {:error, {:attachment_refused, :money}} =
               Messages.save_draft(scope_for(erin), erin_box, attach(row.file_uuid))
    end

    test "a grantee added later cannot send a colleague's shared draft with its files", ctx do
      {:ok, draft} =
        Messages.save_draft(ctx.scope, ctx.desk, %{"subject" => "WIP"},
          attachments_data: [%{binary: "priced", filename: "offer.pdf"}]
        )

      erin = user_fixture()
      grant_fixture(ctx.desk, erin, "write")
      refuse_user!(erin)

      assert {:error, {:attachment_refused, :money}} =
               send_to(scope_for(erin), ctx.desk, ctx.bob, %{"uuid" => draft.uuid})
    end

    test "one's own upload is never asked about its creator, at send or at download", ctx do
      refuse_user!(ctx.alice)

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "my own scan", filename: "scan.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      assert {:ok, _} = Attachments.fetch_for_download(ctx.scope, row.uuid)
    end

    test "the sender downloads their own attachment without asking the policy", ctx do
      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "mine", filename: "m.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      put_policy(:refuse)

      assert {:ok, _} = Attachments.fetch_for_download(ctx.scope, row.uuid)
      assert {:error, :not_found} = Attachments.fetch_for_download(scope_for(ctx.bob), row.uuid)
    end
  end

  describe "drafts" do
    test "snapshot at save; a save without the key keeps them; a smaller list drops the rest",
         ctx do
      a = stored_file_fixture(ctx.alice, "a")
      b = stored_file_fixture(ctx.alice, "b")

      {:ok, draft} =
        Messages.save_draft(
          ctx.scope,
          ctx.alice_box,
          Map.merge(%{"subject" => "WIP"}, attach([a.uuid, b.uuid]))
        )

      [row_a, row_b] = Attachments.list_for_message(draft.uuid)
      assert length(inbox_files()) == 2

      {:ok, _} =
        Messages.save_draft(ctx.scope, ctx.alice_box, %{"uuid" => draft.uuid, "body" => "more"})

      assert length(Attachments.list_for_message(draft.uuid)) == 2

      {:ok, _} =
        Messages.save_draft(
          ctx.scope,
          ctx.alice_box,
          Map.merge(%{"uuid" => draft.uuid}, attach(row_a.file_uuid))
        )

      assert [kept] = Attachments.list_for_message(draft.uuid)
      assert kept.file_uuid == row_a.file_uuid
      assert Storage.get_file(row_b.file_uuid) == nil
    end

    test "sending a draft keeps its attachments and asks the policy", ctx do
      a = stored_file_fixture(ctx.alice, "a")
      {:ok, draft} = Messages.save_draft(ctx.scope, ctx.alice_box, attach(a.uuid))
      [row] = Attachments.list_for_message(draft.uuid)

      put_policy(:record)

      {:ok, sent} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{"uuid" => draft.uuid})

      assert sent.uuid == draft.uuid
      assert [%{file_uuid: file_uuid}] = Attachments.list_for_message(sent.uuid)
      assert file_uuid == row.file_uuid
      assert_received {:policy, _, [_bob], [_row]}
    end

    test "discarding a draft deletes its own snapshots", ctx do
      a = stored_file_fixture(ctx.alice, "a")
      {:ok, draft} = Messages.save_draft(ctx.scope, ctx.alice_box, attach(a.uuid))
      [row] = Attachments.list_for_message(draft.uuid)

      :ok = Messages.delete_draft(ctx.scope, ctx.alice_box, draft.uuid)

      assert Storage.get_file(row.file_uuid) == nil
      assert Storage.get_file(a.uuid)
    end

    test "discarding a draft leaves a snapshot it shares with a sent message", ctx do
      {:ok, original} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "shared", filename: "s.pdf"}]
        )

      [row] = Attachments.list_for_message(original.uuid)

      {:ok, draft} = Messages.save_draft(scope_for(ctx.bob), ctx.bob_box, attach(row.file_uuid))
      :ok = Messages.delete_draft(scope_for(ctx.bob), ctx.bob_box, draft.uuid)

      assert Storage.get_file(row.file_uuid)
      assert bytes(row.file_uuid) == "shared"
      assert [_] = Attachments.list_for_message(original.uuid)
    end
  end

  describe "who may download" do
    setup ctx do
      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "report", filename: "r.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      %{message: message, row: row}
    end

    test "the sender and a recipient; nobody else", ctx do
      assert {:ok, %{uuid: uuid}} = Attachments.fetch_for_download(ctx.scope, ctx.row.uuid)
      assert uuid == ctx.row.uuid
      assert {:ok, _} = Attachments.fetch_for_download(scope_for(ctx.bob), ctx.row.uuid)

      assert {:error, :not_found} =
               Attachments.fetch_for_download(scope_for(ctx.carol), ctx.row.uuid)
    end

    test "a reader of a shared mailbox that received it", ctx do
      desk = shared_mailbox_fixture(ctx.carol, %{slug: "desk"})
      dave = user_fixture()
      grant_fixture(desk, dave, "read")

      {:ok, message} =
        Messages.send_message(
          ctx.scope,
          ctx.alice_box,
          %{"to" => "desk", "subject" => "to the desk"},
          attachments_data: [%{binary: "for the desk", filename: "d.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      assert {:ok, _} = Attachments.fetch_for_download(scope_for(dave), row.uuid)
    end

    test "not after the recipient deleted their copy", ctx do
      :ok = Messages.purge(scope_for(ctx.bob), ctx.bob_box, ctx.message.uuid)

      assert {:error, :not_found} =
               Attachments.fetch_for_download(scope_for(ctx.bob), ctx.row.uuid)
    end

    test "not without the inbox permission, nor with the module off", ctx do
      assert {:error, :not_found} =
               Attachments.fetch_for_download(scope_for(ctx.bob, []), ctx.row.uuid)

      PhoenixKitInbox.disable_system()

      assert {:error, :not_found} =
               Attachments.fetch_for_download(scope_for(ctx.bob), ctx.row.uuid)
    end

    test "not for a made-up uuid", ctx do
      assert {:error, :not_found} =
               Attachments.fetch_for_download(ctx.scope, Ecto.UUID.generate())

      assert {:error, :not_found} = Attachments.fetch_for_download(ctx.scope, "nope")
    end
  end

  describe "read_file/1" do
    test "refuses a row naming a file outside the Inbox library", ctx do
      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, %{},
          attachments_data: [%{binary: "real", filename: "r.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)
      assert {:ok, path} = Attachments.read_file(row)
      File.rm(path)

      media = stored_file_fixture(ctx.carol, "carol's media file")
      forged = row |> Ecto.Changeset.change(file_uuid: media.uuid) |> Repo.update!()

      assert {:error, :not_found} = Attachments.read_file(forged)
    end
  end

  describe "error messages" do
    test "every refusal reads as a sentence, not an inspected term" do
      reasons = [
        :attachments_need_scope,
        :invalid_attachments,
        {:attachment_forbidden, Ecto.UUID.generate()},
        {:attachment_unavailable, Ecto.UUID.generate()},
        {:too_many_attachments, 50},
        {:attachment_too_large, "big.bin"},
        {:attachment_refused, :money},
        {:attachment_store_failed, :timeout},
        {:library_unavailable, :boom},
        :storage_unsupported
      ]

      for reason <- reasons do
        message = PhoenixKitInbox.Errors.message(reason)
        refute message =~ "Unexpected error", inspect(reason)
      end

      assert PhoenixKitInbox.Errors.message({:attachment_too_large, "big.bin"}) =~ "big.bin"
      assert PhoenixKitInbox.Errors.message({:too_many_attachments, 50}) =~ "50"
    end
  end

  describe "a snapshot outside the module" do
    test "is not listed in Media, and the file route refuses its permanent link", ctx do
      original = stored_file_fixture(ctx.alice, "visible")

      {:ok, message} =
        send_to(ctx.scope, ctx.alice_box, ctx.bob, attach(original.uuid))

      [row] = Attachments.list_for_message(message.uuid)

      for opts <- [[per_page: 500], [per_page: 500, library_uuid: Libraries.media_uuid()]] do
        {files, _total} = Storage.list_files_in_scope(nil, opts)
        uuids = Enum.map(files, & &1.uuid)
        assert original.uuid in uuids
        refute row.file_uuid in uuids
      end

      conn =
        PhoenixKitWeb.FileController.show(conn(:get, "/"), %{
          "file_uuid" => row.file_uuid,
          "variant" => "original",
          "token" => URLSigner.generate_token(row.file_uuid, "original")
        })

      assert conn.status == 401
    end
  end
end
