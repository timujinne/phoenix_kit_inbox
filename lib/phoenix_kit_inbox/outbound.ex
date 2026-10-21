defmodule PhoenixKitInbox.Outbound do
  @moduledoc """
  The one way mail leaves the module — a message to external addresses, its
  retry, and the new-message email nudge all go through `deliver/2`.

  ## Closed by default

  Nothing is sent unless **both** hold:

    * the `inbox_external_enabled` setting is on (`PhoenixKitInbox.set_external_enabled/1`,
      off by default), and
    * the host configured a filter:

          config :phoenix_kit_inbox, outbound_filter: {MyApp.Inbox, :outbound}

      or said explicitly that it wants none:

          config :phoenix_kit_inbox, outbound_filter: :none

  Otherwise `{:error, :external_disabled}`.

  ## The filter

  Called with the `%Swoosh.Email{}` about to go out and the `t:context/0`;
  returns `{:ok, email}` or `{:error, reason}` (`{:error, {:filter_refused,
  reason}}` to the caller). Of the email it returns only the addressing is
  taken — To, Cc, Bcc and Reply-To — so a staging host can redirect mail to a
  test address; From, subject, body and attachments stay as built. A filter
  that raises, throws, exits or answers anything else refuses the send
  (`{:error, :filter_failed}`): an error must stop mail, not let it through.
  An email left with no recipient is not sent (`{:error, :no_recipients}`).

  ## The call to core

  `PhoenixKit.Mailer.deliver_via_integration/3` with the integration of the
  context, and on every call:

    * `skip_queue: true` — core does not offer the message to an email
      provider's queue at all, and `queue: false` — `phoenix_kit_emails`' own
      per-message opt-out. A queued message is re-sent by that package's
      worker through core's *default* integration, so mail from a chosen
      sender would leave through another connection;
    * `user_uuid:` and `integration_uuid:` of the context, recorded in the
      email log;
    * `message_tags: %{"source" => "inbox", "inbox_message_uuid" => …,
      "inbox_kind" => "message" | "nudge"}` — how a message's log rows are
      found again (`deliver_via_integration/3` does not return the log row).

  The integration is not checked here: `deliver_via_integration/3` reads any
  connection by uuid, so callers resolve it first, with its owner
  (`PhoenixKitInbox.Identities.resolve/3`).

  ## The transport

  The call to core is the behaviour's one callback,
  `c:deliver_via_integration/3`, implemented by
  `PhoenixKitInbox.Outbound.Mailer`. Tests replace the transport — only the
  transport, so the checks and the filter above run as in production:

      config :phoenix_kit_inbox, :outbound, MyApp.TestOutbound
  """

  require Logger

  @typedoc """
  What a send is: `:kind` (`:message` — a message or its retry, `:nudge`),
  `:integration_uuid` (required), `:user_uuid` (who sent the message),
  `:message_uuid` (the Inbox message), `:identity_uuid` (the sending identity).
  """
  @type context :: %{
          required(:kind) => :message | :nudge,
          required(:integration_uuid) => String.t() | nil,
          optional(:user_uuid) => String.t() | nil,
          optional(:message_uuid) => String.t() | nil,
          optional(:identity_uuid) => String.t() | nil
        }

  @doc "Sends `email` through `integration_uuid` — `PhoenixKit.Mailer.deliver_via_integration/3`."
  @callback deliver_via_integration(Swoosh.Email.t(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @addressing [:to, :cc, :bcc, :reply_to]

  @doc "Whether mail may leave at all: the setting is on and a filter is configured."
  @spec open?() :: boolean()
  def open?, do: check_open() == :ok

  @doc "`:ok` when `open?/0`, else `{:error, :external_disabled}`."
  @spec check_open() :: :ok | {:error, :external_disabled}
  def check_open do
    if PhoenixKitInbox.external_enabled?() and filter() != nil,
      do: :ok,
      else: {:error, :external_disabled}
  end

  @doc """
  Sends `email` as the context says, after the checks and the filter above.
  Returns the transport's answer, or why nothing was sent.
  """
  @spec deliver(Swoosh.Email.t(), context()) :: {:ok, term()} | {:error, term()}
  def deliver(%Swoosh.Email{} = email, %{kind: kind} = context) when kind in [:message, :nudge] do
    with :ok <- check_open(),
         {:ok, integration_uuid} <- integration(context),
         {:ok, email} <- run_filter(filter(), email, context),
         :ok <- any_recipient(email) do
      transport_deliver(email, integration_uuid, send_options(context, integration_uuid))
    end
  end

  # ── filter ──────────────────────────────────────────────────────────────────

  defp filter do
    case Application.get_env(:phoenix_kit_inbox, :outbound_filter) do
      :none -> :none
      {mod, fun} when is_atom(mod) and is_atom(fun) -> {mod, fun}
      _ -> nil
    end
  end

  defp run_filter(:none, email, _context), do: {:ok, email}

  defp run_filter({mod, fun}, email, context) do
    case apply(mod, fun, [email, context]) do
      {:ok, %Swoosh.Email{} = filtered} ->
        {:ok, Map.merge(email, Map.take(filtered, @addressing))}

      {:error, reason} ->
        {:error, {:filter_refused, reason}}

      other ->
        filter_failed("answered #{inspect(other, limit: 5)}")
    end
  rescue
    e -> filter_failed("raised #{Exception.message(e)}")
  catch
    kind, reason -> filter_failed("#{kind} #{inspect(reason, limit: 5)}")
  end

  defp filter_failed(what) do
    Logger.warning("[Inbox] outbound_filter #{what}; the email was not sent")
    {:error, :filter_failed}
  end

  defp any_recipient(%Swoosh.Email{to: to, cc: cc, bcc: bcc}) do
    if Enum.all?([to, cc, bcc], &(&1 in [nil, []])), do: {:error, :no_recipients}, else: :ok
  end

  # ── transport ───────────────────────────────────────────────────────────────

  defp integration(%{integration_uuid: uuid}) when is_binary(uuid) and uuid != "", do: {:ok, uuid}
  defp integration(_context), do: {:error, :no_integration}

  defp send_options(context, integration_uuid) do
    tags =
      %{
        "source" => "inbox",
        "inbox_message_uuid" => Map.get(context, :message_uuid),
        "inbox_kind" => Atom.to_string(context.kind)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    [
      skip_queue: true,
      queue: false,
      user_uuid: Map.get(context, :user_uuid),
      integration_uuid: integration_uuid,
      message_tags: tags
    ]
  end

  defp transport_deliver(email, integration_uuid, opts) do
    transport().deliver_via_integration(email, integration_uuid, opts)
  rescue
    e ->
      Logger.warning("[Inbox] external send raised: #{Exception.message(e)}")
      {:error, {:transport_failed, Exception.message(e)}}
  end

  defp transport,
    do: Application.get_env(:phoenix_kit_inbox, :outbound, PhoenixKitInbox.Outbound.Mailer)
end
