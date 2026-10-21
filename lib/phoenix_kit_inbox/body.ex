defmodule PhoenixKitInbox.Body do
  @moduledoc """
  A message body as the reading pane shows it.

  A `"markdown"` body becomes HTML through core's `PhoenixKit.Email.Markdown`
  — the renderer email templates use — with no variables: `{{x}}` typed by
  the writer stays as typed. Its output is already safe: raw HTML is not
  rendered, the result is sanitized (`PhoenixKit.Utils.HtmlSanitizer`), and
  a link survives only with an `http(s)` or `mailto` address. On top of that:

    * every line break the writer typed is a line break (outside code
      blocks), the way it looked in the compose box — Markdown alone would
      join the lines of a paragraph
    * a remote image is **never loaded**: it becomes a link to its address
      (a tracking pixel, or a request to an internal address, fires on load)
    * links open in a new tab, without the opener and the referrer

  `"text"` and `"html"` bodies are not interpreted: `html/1` returns `nil`
  and the caller shows the text escaped.
  """

  alias PhoenixKit.Email.Markdown
  alias PhoenixKitInbox.Schemas.Message

  @preview_length 120
  @fence ~r/\A {0,3}(`{3,}|~{3,})/
  @img ~r/<img\b[^>]*>/
  @link_rel ~s(target="_blank" rel="noopener noreferrer nofollow")

  @doc "A Markdown body as safe HTML; `nil` for any other format or no body."
  @spec html(Message.t()) :: Phoenix.HTML.safe() | nil
  def html(%Message{body_format: "markdown", body: body}) when is_binary(body),
    do: markdown_html(body)

  def html(_message), do: nil

  @doc "Markdown text (a body, a signature) as safe HTML, by the rules above."
  @spec markdown_html(String.t()) :: Phoenix.HTML.safe()
  def markdown_html(markdown) when is_binary(markdown) do
    markdown
    |> hard_breaks()
    |> Markdown.to_html(%{})
    |> images_as_links()
    |> String.replace("<a href=", "<a #{@link_rel} href=")
    |> Phoenix.HTML.raw()
  end

  @doc """
  The body as one line of plain text, at most #{@preview_length} characters —
  the message list's preview.
  """
  @spec preview(Message.t()) :: String.t()
  def preview(%Message{body: nil}), do: ""

  def preview(%Message{body_format: "markdown", body: body}),
    do: body |> Markdown.to_text(%{}) |> one_line()

  def preview(%Message{body: body}), do: one_line(body)

  defp one_line(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @preview_length)
  end

  # Two trailing spaces make a line end a hard break. Not inside fenced code,
  # where they would be part of the code; a blank line stays blank.
  defp hard_breaks(markdown) do
    {lines, _in_fence} =
      markdown
      |> String.split(~r/\r?\n/)
      |> Enum.map_reduce(false, fn line, in_fence ->
        cond do
          Regex.match?(@fence, line) -> {line, not in_fence}
          in_fence or String.trim(line) == "" -> {line, in_fence}
          true -> {String.trim_trailing(line, " ") <> "  ", in_fence}
        end
      end)

    Enum.join(lines, "\n")
  end

  # Core builds every image itself, after sanitizing, as
  # `<img src="…" alt="…" …>` with attribute-escaped values — so the values
  # can be reused as they are. Anything that is not an http(s) image becomes
  # its alt text alone.
  defp images_as_links(html) do
    Regex.replace(@img, html, fn tag ->
      src = attribute(tag, "src")
      alt = attribute(tag, "alt")

      if is_binary(src) and Regex.match?(~r/\Ahttps?:\/\//i, src) do
        label = if alt in [nil, ""], do: src, else: alt
        ~s(<a href="#{src}">#{label}</a>)
      else
        alt || ""
      end
    end)
  end

  defp attribute(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag) do
      [_, value] -> value
      nil -> nil
    end
  end
end
