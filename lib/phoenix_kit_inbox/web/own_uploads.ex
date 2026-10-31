defmodule PhoenixKitInbox.Web.OwnUploads do
  @moduledoc """
  An upload's temporary file belongs to its upload channel and goes with the
  page. Work that must outlive the page (a send, a draft save) takes a hard
  link of its own to each file; where none can be made (another file system)
  the upload's own path stays.
  """

  @doc """
  Replaces the path of each of `uploads` (read by `path_of`, put back by
  `with_path`) with a hard link of its own. Returns the uploads and the links
  made, which the work deletes when it ends.
  """
  @spec link([upload], (upload -> Path.t()), (upload, Path.t() -> upload)) ::
          {[upload], [Path.t()]}
        when upload: term()
  def link(uploads, path_of, with_path) do
    Enum.map_reduce(uploads, [], fn upload, links ->
      link = Path.join(System.tmp_dir!(), "phoenix_kit_inbox_upload_#{UUIDv7.generate()}")

      case File.ln(path_of.(upload), link) do
        :ok -> {with_path.(upload, link), [link | links]}
        {:error, _reason} -> {upload, links}
      end
    end)
  end
end
