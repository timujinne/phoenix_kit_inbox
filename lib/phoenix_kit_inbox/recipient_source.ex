defmodule PhoenixKitInbox.RecipientSource do
  @moduledoc """
  A place a compose form finds people to suggest. The module brings one
  (`PhoenixKitInbox.RecipientSources.Members`, the people inside the
  application); a host adds its own — a customer's addresses, partners,
  contacts — and hands the list to the form.

  ## The behaviour

    * `c:suggest/3` — what the source offers for `query` (what the person has
      typed; may be empty). Each suggestion is a map (`t:suggestion/0`):

        * `:address` — an address or a handle (`"@alice"`, `"x@example.com"`),
          or `:user` — the uuid of a user, for a person the host knows by
          account; at least one of the two
        * `:label` — how to show them (a name), or `nil` when the source has
          none
        * `:group` — the heading to list them under, already in the viewer's
          language, or `nil`
        * `:route` — `:internal` (delivered inside the application) or
          `:email` (sent out). The source says what it expects; the send
          checks that this is how the address really resolves and refuses the
          message otherwise.

    * `c:remember/4` (optional) — told when a person typed an address
      by hand and sent, so a source may keep it for next time.

  `context` is whatever the host puts into its form's draft (`ComposeDraft`'s
  `:context`): the object the mail is about, say. A source reads the
  viewer from `scope` and must show only what that viewer may address.

  ## Merging

  `suggest_all/4` asks every source and merges the answers into one list
  without doubles. A failing source costs only its own suggestions.
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope

  # What a form can use of the answers: a source that returns thousands is
  # not asked to show them all.
  @max_suggestions 50

  @type route :: :internal | :email

  @type suggestion :: %{
          optional(:address) => String.t(),
          optional(:user) => binary(),
          label: String.t() | nil,
          group: String.t() | nil,
          route: route()
        }

  @callback suggest(Scope.t(), context :: map(), query :: String.t()) :: [map()]
  @callback remember(
              Scope.t(),
              context :: map(),
              address :: String.t(),
              label :: String.t() | nil
            ) ::
              :ok | {:error, term()}

  @optional_callbacks remember: 4

  @doc """
  The suggestions of all `sources` (modules implementing this behaviour) for
  `query`, merged.

  * The query is trimmed; a missing one is asked as `""`.
  * Two entries are the same person when they name the same user, or the same
    address (ignoring case and surrounding spaces). Of two, the one with a
    `:label` wins over one without; otherwise the earlier source's stays.
    A winner takes the place of the first appearance.
  * An entry that is not a map, has neither `:address` nor `:user`, or a
    `:route` other than `:internal` / `:email` is dropped.
  * A source that raises, throws, exits, returns something but a list, or is
    not a module is logged — its module and the kind of failure, never what
    was asked or answered — and skipped.
  * At most 50 suggestions are returned, the first ones in the order of the
    sources.

  The sources are asked one after the other **in the caller's process**: a
  slow source makes the caller wait, so a source answers from an index or a
  small query, not from a remote service.
  """
  @spec suggest_all([module()] | nil, Scope.t(), map(), String.t() | nil) :: [suggestion()]
  def suggest_all(sources, scope, context, query) when is_list(sources) do
    query = if is_binary(query), do: String.trim(query), else: ""

    sources
    |> Enum.flat_map(&ask(&1, scope, context, query))
    |> merge()
    |> Enum.take(@max_suggestions)
  end

  def suggest_all(_sources, _scope, _context, _query), do: []

  # ── asking ──────────────────────────────────────────────────────────────────

  defp ask(source, scope, context, query) when is_atom(source) and not is_nil(source) do
    if Code.ensure_loaded?(source) and function_exported?(source, :suggest, 3) do
      case safely(source, scope, context, query) do
        {:ok, list} when is_list(list) -> Enum.flat_map(list, &normalize/1)
        {:ok, _other} -> skip(source, "did not return a list")
        :error -> []
      end
    else
      skip(source, "is not a recipient source")
    end
  end

  defp ask(_source, _scope, _context, _query) do
    Logger.warning("[Inbox] recipient source skipped: not a module")
    []
  end

  defp safely(source, scope, context, query) do
    {:ok, source.suggest(scope, context, query)}
  rescue
    e ->
      skip(source, "raised #{inspect(e.__struct__)}")
      :error
  catch
    kind, _reason ->
      skip(source, "ended with #{kind}")
      :error
  end

  # Names the source and the kind of failure only: what was typed and what
  # the source knows are people's data.
  defp skip(source, what) do
    Logger.warning("[Inbox] recipient source #{inspect(source)} #{what}")
    []
  end

  # ── entries ─────────────────────────────────────────────────────────────────

  defp normalize(%{route: route} = entry)
       when route in [:internal, :email] and not is_struct(entry) do
    address = text(entry[:address])
    user = uuid(entry[:user])

    case {user, address} do
      {nil, nil} -> []
      {nil, address} -> [%{address: address} |> finish(entry, route)]
      {user, _} -> [%{user: user} |> finish(entry, route)]
    end
  end

  defp normalize(_), do: []

  defp finish(identity, entry, route),
    do:
      Map.merge(identity, %{label: text(entry[:label]), group: text(entry[:group]), route: route})

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_), do: nil

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_), do: nil

  # ── merging ─────────────────────────────────────────────────────────────────

  defp merge(entries) do
    {order, by_key} =
      Enum.reduce(entries, {[], %{}}, fn entry, {order, by_key} ->
        key = key(entry)

        case by_key do
          %{^key => kept} -> {order, Map.put(by_key, key, better(kept, entry))}
          _ -> {[key | order], Map.put(by_key, key, entry)}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_key, &1))
  end

  defp key(%{user: user}), do: {:user, user}
  defp key(%{address: address}), do: {:address, String.downcase(address)}

  defp better(%{label: nil}, %{label: label} = entry) when is_binary(label), do: entry
  defp better(kept, _entry), do: kept
end
