defmodule PhoenixKitInbox.Web.Components.MailTree do
  @moduledoc """
  The list of `PhoenixKitInbox.Web.Components.MailExplorer`: one block per
  conversation, its replies nested under it with an indent.

  Rows are buttons that send `"select"` to `target` with `phx-value-kind`
  (`"thread"` for the conversation's head row, `"message"` for a nested one)
  and `phx-value-uuid`. Each row says whether the letter came in or went out
  and where its link to the object came from. Pure rendering: it reads
  what `PhoenixKitInbox.ObjectMail.list_threads/3` returned and nothing else.
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitInbox.Gettext

  @sources ~w(host manual thread subject)

  attr(:threads, :list, required: true)
  attr(:selected, :any, default: nil, doc: "`{:thread, uuid}`, `{:message, uuid}` or `nil`")
  attr(:target, :any, required: true, doc: "the `phx-target` of the row buttons")

  @doc "The conversations as selectable rows."
  def tree(assigns) do
    assigns =
      assign(assigns, :blocks, for(%{messages: [_ | _]} = thread <- assigns.threads, do: thread))

    ~H"""
    <div class="flex flex-col gap-2">
      <div
        :for={thread <- @blocks}
        id={"mail-thread-#{thread.thread_uuid}"}
        class="flex flex-col gap-1"
      >
        <.row
          entry={hd(thread.messages)}
          kind="thread"
          selected={@selected == {:thread, thread.thread_uuid}}
          target={@target}
          uuid={thread.thread_uuid}
          count={length(thread.messages)}
          at={thread.last_at}
          indent={0}
        />
        <.row
          :for={entry <- tl(thread.messages)}
          entry={entry}
          kind="message"
          selected={@selected == {:message, entry.message.uuid}}
          target={@target}
          uuid={entry.message.uuid}
          count={1}
          at={entry.message.sent_at}
          indent={max(entry.depth, 1)}
        />
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:kind, :string, required: true)
  attr(:uuid, :string, required: true)
  attr(:selected, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:count, :integer, required: true)
  attr(:at, :any, default: nil)
  attr(:indent, :integer, required: true)

  defp row(assigns) do
    ~H"""
    <button
      type="button"
      id={"mail-row-#{@entry.message.uuid}"}
      class={[
        "flex flex-col gap-1 rounded-lg border px-3 py-2 text-left text-sm",
        "hover:bg-base-200 focus-visible:outline focus-visible:outline-2",
        indent_class(@indent),
        if(@selected, do: "border-primary bg-base-200", else: "border-base-300 bg-base-100")
      ]}
      aria-current={@selected && "true"}
      phx-click="select"
      phx-value-kind={@kind}
      phx-value-uuid={@uuid}
      phx-target={@target}
    >
      <span class="flex items-baseline justify-between gap-2">
        <span class="truncate font-medium">
          <.icon
            :if={@indent > 0}
            name="hero-arrow-uturn-right"
            class="w-3 h-3 inline-block align-baseline opacity-50"
          />
          {@entry.message.subject || gettext("(no subject)")}
        </span>
        <span class="shrink-0 text-xs opacity-60">
          <span :if={@count > 1}>
            {ngettext("%{count} letter", "%{count} letters", @count)} ·
          </span>
          {short_time(@at)}
        </span>
      </span>
      <span class="flex flex-wrap items-center gap-1 text-xs">
        <span class={["badge badge-sm", direction_class(@entry.direction)]}>
          {direction_label(@entry.direction)}
        </span>
        <span class="truncate opacity-70">{people(@entry.message)}</span>
        <span :if={source(@entry)} class="badge badge-ghost badge-sm">
          {source_label(source(@entry))}
        </span>
      </span>
    </button>
    """
  end

  @doc "The strongest source among the links of the entry, `nil` if it has none."
  @spec source(map()) :: String.t() | nil
  def source(%{links: links}) do
    present = MapSet.new(links, & &1.source)
    Enum.find(@sources, &MapSet.member?(present, &1))
  end

  @doc "How a link came about, in words."
  @spec source_label(String.t()) :: String.t()
  def source_label("host"), do: pgettext("mail link source", "host")
  def source_label("manual"), do: pgettext("mail link source", "manual")
  def source_label("thread"), do: pgettext("mail link source", "thread")
  def source_label("subject"), do: pgettext("mail link source", "subject")

  @doc "Whether the letter came in or went out."
  @spec direction_label(:inbox | :sent) :: String.t()
  def direction_label(:inbox), do: gettext("Incoming")
  def direction_label(:sent), do: gettext("Outgoing")

  defp direction_class(:inbox), do: "badge-info badge-outline"
  defp direction_class(:sent), do: "badge-neutral badge-outline"

  defp indent_class(0), do: nil
  defp indent_class(1), do: "ml-4"
  defp indent_class(2), do: "ml-8"
  defp indent_class(_), do: "ml-12"

  @doc "`Sender → recipients`, from the snapshot written when the letter was sent."
  @spec people(map()) :: String.t()
  def people(%{metadata: metadata}) do
    sender = metadata |> Map.get("sender", %{}) |> sender_name()

    recipients =
      metadata
      |> Map.get("recipients", [])
      |> Enum.filter(&(&1["role"] == "to"))
      |> Enum.map(&(&1["name"] || &1["handle"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    Enum.join(Enum.reject([sender, recipients], &(&1 in [nil, ""])), " → ")
  end

  @doc "Who wrote the letter, by the snapshot."
  @spec sender_name(map()) :: String.t() | nil
  def sender_name(sender) when is_map(sender),
    do: sender["name"] || sender["email"] || sender["mailbox"]

  def sender_name(_), do: nil

  defp short_time(nil), do: ""
  defp short_time(at), do: Calendar.strftime(at, "%d.%m")
end
