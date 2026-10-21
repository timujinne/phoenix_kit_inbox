defmodule PhoenixKitInbox.Web.AttachmentController do
  @moduledoc """
  Downloads a message attachment: `GET <prefix>/admin/inbox/files/:attachment_uuid`.

  The only way an attachment leaves the module. The file sits in the
  module's hidden Storage library, which has no permanent URL, so the bytes
  are read here (`Storage.retrieve_file/1`) and streamed back with
  `Content-Disposition: attachment`, `nosniff` and `Content-Security-Policy:
  sandbox` — never a redirect to a Storage URL.

  Allowed when the module is on, the viewer holds `"inbox"`, and they sent
  the message or hold a non-deleted copy of it in a mailbox they can read
  (`PhoenixKitInbox.Attachments.fetch_for_download/2`). Everything else —
  someone else's attachment, a made-up uuid, bytes gone from Storage — is
  the same 404.
  """

  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitInbox.Gettext

  alias PhoenixKitInbox.Attachments

  @doc false
  def show(conn, %{"attachment_uuid" => attachment_uuid}) do
    scope = conn.assigns[:phoenix_kit_current_scope]

    with {:ok, attachment} <- Attachments.fetch_for_download(scope, attachment_uuid),
         {:ok, path} <- Attachments.read_file(attachment) do
      try do
        conn
        |> put_resp_content_type(Attachments.safe_content_type(attachment.content_type), nil)
        |> put_resp_header("content-disposition", disposition(attachment.filename))
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox")
        |> send_file(200, path)
      after
        File.rm(path)
      end
    else
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: not_found(conn)

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(404, gettext("Not found"))
  end

  # An ASCII fallback for old clients plus the exact name (RFC 6266 / 5987).
  defp disposition(filename) do
    fallback =
      filename
      |> String.replace(~r/[^\x20-\x7E]|["\\]/u, "_")

    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end
end
