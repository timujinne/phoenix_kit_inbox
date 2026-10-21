defmodule PhoenixKitInbox.EmailLog do
  @moduledoc """
  What the email log (`phoenix_kit_email_logs`, written by
  `phoenix_kit_emails` for every send through core's mailer) says about a
  message's external email.

  `phoenix_kit_emails` is optional and not a dependency: `available?/0` asks
  it, through `apply/3`, whether it is installed and enabled. Its log rows
  are found by the tags `PhoenixKitInbox.Outbound` puts on every send —
  `message_tags.inbox_message_uuid`, and `inbox_kind = "message"` so the
  nudges of a message are not counted as its sends.
  """

  import Ecto.Query

  @emails PhoenixKit.Modules.Emails

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Whether `phoenix_kit_emails` is installed and enabled (it then keeps the log)."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@emails) and function_exported?(@emails, :enabled?, 0) and
      emails_enabled?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp emails_enabled?, do: apply(@emails, :enabled?, []) == true

  @doc """
  The log rows of `message_uuid`'s external email, oldest first, as
  `%{message_id, status}`; `:unavailable` when the log can't be read.
  """
  @spec rows(binary()) :: [%{message_id: String.t(), status: String.t()}] | :unavailable
  def rows(message_uuid) when is_binary(message_uuid) do
    from(l in "phoenix_kit_email_logs",
      where: fragment("?->>'inbox_message_uuid' = ?", l.message_tags, ^message_uuid),
      where: fragment("coalesce(?->>'inbox_kind', 'message') = 'message'", l.message_tags),
      order_by: [asc: l.inserted_at],
      select: %{message_id: l.message_id, status: l.status}
    )
    |> put_prefix()
    |> repo().all()
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc "The `message_id` of the newest log row of `message_uuid`, or `nil`."
  @spec latest_message_id(binary()) :: String.t() | nil
  def latest_message_id(message_uuid) do
    case rows(message_uuid) do
      [_ | _] = rows -> List.last(rows).message_id
      _ -> nil
    end
  end

  defp put_prefix(query) do
    case Application.get_env(:phoenix_kit, :prefix) do
      prefix when is_binary(prefix) and prefix not in ["", "public"] ->
        put_query_prefix(query, prefix)

      _ ->
        query
    end
  end
end
