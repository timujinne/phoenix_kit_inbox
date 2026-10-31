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
      by hand and the letter went, so a source may keep it for next time
      (`remember_all/4`, called by the compose form; see there for when and
      how).

  `context` is whatever the host puts into its form's draft (`ComposeDraft`'s
  `:context`): the object the mail is about, say. A source reads the
  viewer from `scope` and must show only what that viewer may address.

  ## Where `c:suggest/3` runs

  The form waits for the sources while the person types: each is asked in a
  process of its own (a task), for at most 1.5 seconds, and one that is not
  done by then is skipped. A task starts with the caller's language (the
  Gettext locale, of the global Gettext and of each backend that was given
  one) and nothing else of the caller's process: any other context the source
  relies on (a host's list of clients kept in the process dictionary, a
  tenant, a database sandbox) it sets itself inside `c:suggest/3`, from
  `scope` and `context`.

  ## Merging

  `suggest_all/4` asks every source and merges the answers into one list
  without doubles. A failing source costs only its own suggestions.
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope

  # What a form can use of the answers: a source that returns thousands is
  # not asked to show them all.
  @max_suggestions 50
  @source_timeout 1_500
  # A host may list many sources; no more than this many ask at once.
  @max_concurrency 8

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

  The sources are asked **at once** (at most eight at a time), each in a task of its own (the caller
  waits for the slowest, but for no longer than 1.5 seconds each: one that has
  not answered by then is skipped and logged, by its module only), and
  their answers are put together in the order of `sources`. A task is another
  process: what a source reads from the caller's process dictionary is not
  there (but for the language, see above) — it takes what it needs from
  `scope` and `context`. A source answers
  from an index or a small query, not from a remote service. Of one source,
  the first 50 entries are taken.
  """
  @spec suggest_all([module()] | nil, Scope.t(), map(), String.t() | nil) :: [suggestion()]
  def suggest_all(sources, scope, context, query) when is_list(sources) do
    query = if is_binary(query), do: String.trim(query), else: ""

    sources
    |> ask_all(scope, context, query)
    |> merge()
    |> Enum.take(@max_suggestions)
  end

  def suggest_all(_sources, _scope, _context, _query), do: []

  @doc """
  Tells the `sources` that can remember (those that export `c:remember/4`)
  each of the `entries` (`%{address: String.t(), label: String.t() | nil}`).
  Always `:ok`: what a source does with it never reaches the send.

  The compose form calls it after a send that **went**, for the addresses the
  person typed by hand and added to the letter (not those picked from a list
  and not those of the host's draft), with the draft's `:context`. It runs in
  the send's worker, after the answer to the page: a send that failed or was
  refused remembers nothing, and a source that is slow or fails delays and
  breaks nothing.

  Each source is called in a process of its own, for all the entries one
  after the other, for at most the same time as `suggest_all/4` allows a source
  (1.5 seconds); one that raises, throws, exits, answers `{:error, _}` or is too
  slow is logged by its module only — never the address, nor what it said —
  and the others go on. Of a source that cannot remember nothing is asked.
  """
  @spec remember_all([module()] | nil, Scope.t(), map(), [
          %{address: String.t(), label: String.t() | nil}
        ]) :: :ok
  def remember_all(sources, scope, context, [_ | _] = entries) when is_list(sources) do
    case Enum.filter(sources, &remembers?/1) do
      [] -> :ok
      able -> run_remember(able, scope, context, entries)
    end
  end

  def remember_all(_sources, _scope, _context, _entries), do: :ok

  defp remembers?(source) when is_atom(source) and not is_nil(source),
    do: Code.ensure_loaded?(source) and function_exported?(source, :remember, 4)

  defp remembers?(_source), do: false

  defp run_remember(sources, scope, context, entries) do
    PhoenixKitInbox.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      sources,
      &remember_entries(&1, scope, context, entries),
      timeout: timeout(),
      on_timeout: :kill_task,
      max_concurrency: min(length(sources), @max_concurrency),
      zip_input_on_exit: true
    )
    |> Enum.each(fn
      {:ok, _} -> :ok
      {:exit, {source, :timeout}} -> skip(source, "was too slow to remember")
      {:exit, {source, _reason}} -> skip(source, "ended without remembering")
    end)
  catch
    # No supervisor to run them under: nothing is remembered.
    :exit, _reason -> :ok
  end

  defp remember_entries(source, scope, context, entries) do
    Enum.each(entries, fn %{address: address} = entry ->
      try do
        case source.remember(scope, context, address, entry[:label]) do
          :ok -> :ok
          _other -> skip(source, "did not remember")
        end
      rescue
        e -> skip(source, "raised #{inspect(e.__struct__)} when asked to remember")
      catch
        kind, _reason -> skip(source, "ended with #{kind} when asked to remember")
      end
    end)
  end

  # ── asking ──────────────────────────────────────────────────────────────────

  # Every source in a task of its own, at most `@source_timeout` each, in the
  # order they were given. A task that is over time is killed, not waited for.
  defp ask_all([], _scope, _context, _query), do: []

  defp ask_all(sources, scope, context, query) do
    timeout = timeout()

    language = language()

    sources
    |> Task.async_stream(&ask_in(language, &1, scope, context, query),
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: min(length(sources), @max_concurrency),
      ordered: true,
      zip_input_on_exit: true
    )
    |> Enum.flat_map(fn
      {:ok, entries} ->
        entries

      {:exit, {source, :timeout}} ->
        skip(source, "was too slow, so its suggestions are left out")

      {:exit, {source, _reason}} ->
        skip(source, "ended without an answer")
    end)
  end

  # The setting is for tests; anything but a positive whole number of
  # milliseconds is the default, never a crash of the search.
  defp timeout do
    case Application.get_env(:phoenix_kit_inbox, :recipient_source_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> @source_timeout
    end
  end

  # The caller's language is a thing of the caller's process (Gettext keeps
  # it in the process dictionary), and a task starts without it: every
  # heading a source translates would come in the default language. What is
  # kept is only that — the locale of the global Gettext and of each Gettext
  # backend that was given one — and the task takes it before it asks.
  defp language do
    for {key, locale} <- Process.get(), is_binary(locale), gettext_key?(key), do: {key, locale}
  end

  defp gettext_key?(Gettext), do: true

  defp gettext_key?(backend) when is_atom(backend),
    do: Code.ensure_loaded?(backend) and function_exported?(backend, :__gettext__, 1)

  defp gettext_key?(_other), do: false

  defp ask_in(language, source, scope, context, query) do
    Enum.each(language, fn {key, locale} -> Process.put(key, locale) end)
    ask(source, scope, context, query)
  end

  defp ask(source, scope, context, query) when is_atom(source) and not is_nil(source) do
    if Code.ensure_loaded?(source) and function_exported?(source, :suggest, 3) do
      case safely(source, scope, context, query) do
        {:ok, list} when is_list(list) ->
          list |> Enum.take(@max_suggestions) |> Enum.flat_map(&normalize/1)

        {:ok, _other} ->
          skip(source, "did not return a list")

        :error ->
          []
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
