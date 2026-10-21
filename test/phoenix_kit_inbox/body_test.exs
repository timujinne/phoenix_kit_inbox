defmodule PhoenixKitInbox.BodyTest do
  use ExUnit.Case, async: true

  alias PhoenixKitInbox.Body
  alias PhoenixKitInbox.Schemas.Message

  defp html(markdown) do
    %Message{body_format: "markdown", body: markdown}
    |> Body.html()
    |> Phoenix.HTML.safe_to_string()
  end

  describe "html/1 — what a Markdown body may not do" do
    test "no script element" do
      out = html("before <script>alert(1)</script> after\n\n<script>alert(2)</script>")

      refute out =~ "<script"
      assert out =~ "before"
    end

    test "no javascript: link — the label stays as text" do
      out = html("[click me](javascript:alert(1)) and [data](data:text/html,x)")

      refute out =~ "javascript:"
      refute out =~ "data:text"
      refute out =~ "<a"
      assert out =~ "click me"
    end

    test "no event handler attributes" do
      out = html(~s|x <img src=x onerror=alert(1)> <b onclick="alert(2)">y</b>|)

      refute out =~ "onerror"
      refute out =~ "onclick"
      refute out =~ "<img"
    end

    test "a remote image is shown as a link, never loaded" do
      out = html("Hi ![pixel](http://tracker.example/p.png?id=1&u=2) there")

      refute out =~ "<img"
      assert out =~ ~s(href="http://tracker.example/p.png?id=1&amp;u=2")
      assert out =~ ">pixel</a>"
    end

    test "an image without alt text is linked by its address" do
      out = html("![](https://example.com/a.png)")

      refute out =~ "<img"
      assert out =~ ~s(>https://example.com/a.png</a>)
    end

    test "links open outside the page, without the opener" do
      out = html("see [the docs](https://example.com/docs) now")

      assert out =~ ~s(href="https://example.com/docs")
      assert out =~ ~s(target="_blank")
      assert out =~ ~s(rel="noopener noreferrer nofollow")
    end
  end

  describe "html/1 — what it keeps" do
    test "{{placeholders}} typed by the writer stay literal" do
      out = html("Dear {{name}},\n\n{{{raw}}}\n\nTotal: {{ total }}")

      assert out =~ "{{name}}"
      assert out =~ "{{{raw}}}"
      assert out =~ "{{ total }}"
    end

    test "Markdown formatting" do
      out = html("**bold** and _it_\n\n- one\n- two")

      assert out =~ "<strong>bold</strong>"
      assert out =~ "<em>it</em>"
      assert out =~ "<li>one</li>"
    end

    test "a line break is a line break, as the writer typed it" do
      out = html("line one\nline two\n> quoted one\n> quoted two")

      assert out =~ ~r/line one<br\s*\/?>/
      assert out =~ ~r/quoted one<br\s*\/?>/
    end

    test "code keeps its lines untouched" do
      out = html("```\ncode line\nnext\n```")

      assert out =~ "code line\nnext"
      refute out =~ "code line  "
    end

    test "the signature block reads as a separator and the signature" do
      out = html("Thanks\n\n-- \nAlice\nAcme")

      assert out =~ ~r/Alice<br\s*\/?>/
    end
  end

  describe "html/1 — other formats" do
    test "text and html bodies are not Markdown" do
      assert Body.html(%Message{body_format: "text", body: "**x**"}) == nil
      assert Body.html(%Message{body_format: "html", body: "<b>x</b>"}) == nil
      assert Body.html(%Message{body_format: "markdown", body: nil}) == nil
    end
  end

  describe "preview/1" do
    test "Markdown is previewed as its text" do
      assert Body.preview(%Message{
               body_format: "markdown",
               body: "**Hello** [there](https://e.x)"
             }) =~
               "Hello there"
    end

    test "text is previewed as is, on one line, capped" do
      long = String.duplicate("word ", 60)
      preview = Body.preview(%Message{body_format: "text", body: "a\n\nb " <> long})

      assert String.starts_with?(preview, "a b word")
      assert String.length(preview) <= 120
      assert Body.preview(%Message{body: nil}) == ""
    end
  end
end
