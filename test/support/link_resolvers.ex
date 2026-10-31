defmodule PhoenixKitInbox.Test.OrderResolver do
  @moduledoc """
  A host resolver for tests: finds `#<digits>` in a subject as `order` refs
  and knows only the refs listed under `:test_link_refs` in the application
  environment.
  """

  @behaviour PhoenixKitInbox.LinkResolver

  @impl true
  def kind, do: "order"

  @impl true
  def extract(subject), do: ~r/#(\d+)/ |> Regex.scan(subject) |> Enum.map(&List.last/1)

  @impl true
  def exists?(ref), do: ref in Application.get_env(:phoenix_kit_inbox, :test_link_refs, [])
end

defmodule PhoenixKitInbox.Test.RaisingResolver do
  @moduledoc "A resolver that fails in the way `:test_resolver_failure` says: `:raise`, `:throw` or `:exit`."

  @behaviour PhoenixKitInbox.LinkResolver

  @impl true
  def kind, do: "broken"

  @impl true
  def extract(_subject) do
    case Application.get_env(:phoenix_kit_inbox, :test_resolver_failure, :raise) do
      :raise -> raise "resolver blew up"
      :throw -> throw(:resolver_threw)
      :exit -> exit(:resolver_exited)
    end
  end

  @impl true
  def exists?(_ref), do: true
end

defmodule PhoenixKitInbox.Test.WaitingResolver do
  @moduledoc """
  A resolver whose `exists?/1` waits (up to two seconds) for the test
  transport's `{:outbound, ...}` message and records under `:test_resolver_saw`
  whether it arrived — that is, whether the email went out while it ran.
  """

  @behaviour PhoenixKitInbox.LinkResolver

  @impl true
  def kind, do: "order"

  @impl true
  def extract(_subject), do: ["1"]

  @impl true
  def exists?(_ref) do
    saw =
      receive do
        {:outbound, _, _, _} -> true
      after
        2_000 -> false
      end

    Application.put_env(:phoenix_kit_inbox, :test_resolver_saw, saw)
    true
  end
end
