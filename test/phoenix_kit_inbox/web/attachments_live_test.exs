defmodule PhoenixKitInbox.Web.AttachmentsLiveTest do
  @moduledoc """
  Attachments in the UI: compose uploads and the "attach existing file"
  picker, chips that come off again, forwards and drafts that carry their
  files, and the download links in the reading pane.
  """

  use PhoenixKitInbox.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKitInbox.Attachments
  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Messages
  alias PhoenixKitInbox.Paths

  setup :storage_setup

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()

    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)
    {:ok, bob_mb} = Mailboxes.ensure_user_mailbox(bob)
    {:ok, carol_mb} = Mailboxes.ensure_user_mailbox(carol)

    %{
      conn: put_test_scope(conn, scope_for(alice)),
      alice: alice,
      bob: bob,
      carol: carol,
      alice_mb: alice_mb,
      bob_mb: bob_mb,
      carol_mb: carol_mb
    }
  end

  defp submit(view, to) do
    view
    |> form("#compose-form", %{
      "to" => to,
      "cc" => "",
      "bcc" => "",
      "subject" => "Files",
      "body" => "See attached."
    })
    |> render_submit()
  end

  defp upload_scan(view) do
    view
    |> file_input("#compose-form", :attachments, [
      %{name: "scan.pdf", content: "%PDF scanned", type: "application/pdf"}
    ])
    |> render_upload("scan.pdf")
  end

  defp inbox_files do
    case Libraries.get_hidden_library_by_slug(Attachments.library_slug()) do
      nil -> []
      library -> files_in_library(library.uuid)
    end
  end

  defp received(mailbox) do
    [%{message: message}] = Messages.list_folder(mailbox.uuid, "inbox")
    Attachments.list_for_message(message.uuid)
  end

  describe "compose" do
    test "an upload stays out of Storage until the send, then is stored once", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert inbox_files() == []

      assert {:error, {:live_redirect, _}} = submit(view, "@#{ctx.bob.username}")

      assert [%{file_uuid: file_uuid, filename: "scan.pdf"}] = received(ctx.bob_mb)
      assert [%{uuid: ^file_uuid}] = inbox_files()
    end

    test "an upload taken off before saving is cancelled; nothing is stored", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      view |> element("#compose-attachments [id^=upload-] button") |> render_click()

      refute has_element?(view, "#compose-attachments [id^=upload-]")
      assert inbox_files() == []
    end

    test "leaving compose after an upload stores nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      assert {:error, {:live_redirect, _}} =
               view |> element("#compose-form a", "Cancel") |> render_click()

      assert inbox_files() == []
    end

    test "saving a draft stores the upload; the chip then names the draft's snapshot", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      view |> element("button[phx-click=save_draft]") |> render_click()

      [%{message: draft}] = Messages.list_folder(ctx.alice_mb.uuid, "drafts")
      [row] = Attachments.list_for_message(draft.uuid)
      assert row.filename == "scan.pdf"
      assert has_element?(view, "#attachment-#{row.file_uuid}", "scan.pdf")
      refute has_element?(view, "#compose-attachments [id^=upload-]")

      view |> element("button[phx-click=save_draft]") |> render_click()
      assert [%{uuid: uuid}] = Attachments.list_for_message(draft.uuid)
      assert uuid == row.uuid
      assert [_] = inbox_files()
    end

    test "a refused send keeps the upload for the next try", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      upload_scan(view)

      submit(view, "nobody@example.com")
      assert has_element?(view, "#compose-attachments [id^=upload-]", "scan.pdf")
      assert inbox_files() == []

      assert {:error, {:live_redirect, _}} = submit(view, "@#{ctx.bob.username}")
      assert [%{filename: "scan.pdf"}] = received(ctx.bob_mb)
    end

    test "an existing file the user may read is attached; another's is refused, unnamed", ctx do
      mine = stored_file_fixture(ctx.alice, "my photo", filename: "mine.jpg")
      theirs = stored_file_fixture(ctx.carol, "her contract", filename: "contract.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid, theirs.uuid]})

      assert has_element?(view, "#attachment-#{mine.uuid}", "mine.jpg")
      refute has_element?(view, "#attachment-#{theirs.uuid}")
      # A forged pick of another user's file must not tell its name.
      assert has_element?(view, "#flash-error", "a file")
      refute render(view) =~ "contract.pdf"

      assert {:error, {:live_redirect, _}} = submit(view, "@#{ctx.bob.username}")
      assert [%{source_file_uuid: source}] = received(ctx.bob_mb)
      assert source == mine.uuid
    end

    test "taking a picked file off leaves the original alone", ctx do
      mine = stored_file_fixture(ctx.alice, "keep me", filename: "keep.txt")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid]})
      view |> element("#attachment-#{mine.uuid} button") |> render_click()

      refute has_element?(view, "#attachment-#{mine.uuid}")
      assert Storage.get_file(mine.uuid)
    end

    test "the media picker lists the user's own files, not another user's", ctx do
      stored_file_fixture(ctx.alice, "my photo", filename: "mine.jpg")
      stored_file_fixture(ctx.carol, "her contract", filename: "contract.pdf")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      html = view |> element("#attach-existing") |> render_click()

      assert html =~ "mine.jpg"
      refute html =~ "contract.pdf"
    end

    test "a system role's media picker lists the whole library", ctx do
      stored_file_fixture(ctx.carol, "her contract", filename: "contract.pdf")
      admin = %{scope_for(ctx.alice) | cached_roles: ["Admin"]}
      conn = put_test_scope(ctx.conn, admin)

      {:ok, view, _html} = live(conn, "/en/admin/inbox/compose")
      html = view |> element("#attach-existing") |> render_click()

      assert html =~ "contract.pdf"
    end

    test "the attach-existing button opens the media picker", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")

      picker = "#media-selector-modal-backdrop-inbox-media-selector"

      refute has_element?(view, picker)
      view |> element("#attach-existing") |> render_click()
      assert has_element?(view, picker)

      send(view.pid, {:media_selector_closed})
      refute has_element?(view, picker)
    end

    test "a forward carries the original's attachments", ctx do
      {:ok, original} =
        Messages.send_message(
          scope_for(ctx.alice),
          ctx.alice_mb,
          %{"to" => "@#{ctx.bob.username}", "subject" => "Plans"},
          attachments_data: [%{binary: "plan", filename: "plan.pdf"}]
        )

      [row] = Attachments.list_for_message(original.uuid)

      conn = put_test_scope(build_conn() |> init_test_session(%{}), scope_for(ctx.bob))

      {:ok, view, _html} =
        live(conn, "/en/admin/inbox/compose?mailbox=#{ctx.bob_mb.uuid}&forward=#{original.uuid}")

      assert has_element?(view, "#attachment-#{row.file_uuid}", "plan.pdf")

      assert {:error, {:live_redirect, _}} = submit(view, "@#{ctx.carol.username}")
      assert [%{file_uuid: file_uuid}] = received(ctx.carol_mb)
      assert file_uuid == row.file_uuid
    end

    test "a reopened draft shows its attachments and keeps them on save", ctx do
      mine = stored_file_fixture(ctx.alice, "draft file", filename: "d.txt")

      {:ok, draft} =
        Messages.save_draft(scope_for(ctx.alice), ctx.alice_mb, %{
          "subject" => "WIP",
          "attachments" => [%{"file_uuid" => mine.uuid}]
        })

      [row] = Attachments.list_for_message(draft.uuid)

      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose?draft=#{draft.uuid}")
      assert has_element?(view, "#attachment-#{row.file_uuid}", "d.txt")

      view |> element("button[phx-click=save_draft]") |> render_click()

      assert [%{uuid: uuid}] = Attachments.list_for_message(draft.uuid)
      assert uuid == row.uuid
    end

    test "a refused send says why and keeps the chips", ctx do
      Application.put_env(:phoenix_kit_inbox, :attachment_policy, {__MODULE__, :refuse})
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :attachment_policy) end)

      mine = stored_file_fixture(ctx.alice, "price list", filename: "prices.pdf")
      {:ok, view, _html} = live(ctx.conn, "/en/admin/inbox/compose")
      send(view.pid, {:media_selected, [mine.uuid]})

      submit(view, "@#{ctx.bob.username}")

      assert has_element?(
               view,
               "#flash-error",
               PhoenixKitInbox.Errors.message({:attachment_refused, :money})
             )

      assert has_element?(view, "#attachment-#{mine.uuid}")
    end
  end

  def refuse(_scope, _users, _rows), do: {:error, :money}

  describe "the reading pane" do
    test "lists the attachments as download links", ctx do
      {:ok, message} =
        Messages.send_message(
          scope_for(ctx.bob),
          ctx.bob_mb,
          %{"to" => "@#{ctx.alice.username}", "subject" => "For you"},
          attachments_data: [%{binary: "data", filename: "report.pdf"}]
        )

      [row] = Attachments.list_for_message(message.uuid)

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/inbox?mailbox=#{ctx.alice_mb.uuid}&message=#{message.uuid}")

      assert has_element?(
               view,
               ~s(#message-attachments a[href="#{Paths.attachment(row.uuid)}"]),
               "report.pdf"
             )
    end

    test "shows no attachment list for a message without any", ctx do
      {:ok, message} =
        Messages.send_message(scope_for(ctx.bob), ctx.bob_mb, %{
          "to" => "@#{ctx.alice.username}",
          "subject" => "Plain"
        })

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/inbox?mailbox=#{ctx.alice_mb.uuid}&message=#{message.uuid}")

      refute has_element?(view, "#message-attachments")
    end
  end
end
