defmodule PhoenixKitInbox.Web.OwnUploadsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitInbox.Web.OwnUploads

  setup do
    path = Path.join(System.tmp_dir!(), "own_uploads_test_#{System.unique_integer([:positive])}")
    File.write!(path, "bytes")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "each upload gets a link of its own that outlives the original", %{path: path} do
    {[%{path: link, name: "a.txt"}], [link_made]} =
      OwnUploads.link([%{path: path, name: "a.txt"}], & &1.path, &%{&1 | path: &2})

    assert link == link_made
    assert link != path
    File.rm!(path)
    assert File.read!(link) == "bytes"
    File.rm!(link)
  end

  test "where no link can be made the upload keeps its own path, and nothing is to delete" do
    missing =
      Path.join(System.tmp_dir!(), "own_uploads_missing_#{System.unique_integer([:positive])}")

    assert {[%{path: ^missing}], []} =
             OwnUploads.link([%{path: missing}], & &1.path, &%{&1 | path: &2})
  end

  test "tuples work too, with their other parts untouched", %{path: path} do
    {[{"ref", link, "a.txt", "text/plain"}], [link]} =
      OwnUploads.link(
        [{"ref", path, "a.txt", "text/plain"}],
        fn {_, p, _, _} -> p end,
        fn {r, _, n, t}, l -> {r, l, n, t} end
      )

    File.rm!(link)
  end
end
