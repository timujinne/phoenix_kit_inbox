defmodule PhoenixKitInbox.RecipientSourceTest do
  @moduledoc """
  Where a compose form gets the people to suggest: the module's own members
  and whatever sources a host adds, merged into one list without doubles.
  """

  use PhoenixKitInbox.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitInbox.RecipientSource
  alias PhoenixKitInbox.RecipientSources.Members

  defmodule Sourced do
    @moduledoc false
    # Answers what the test put into the context under its own key, and tells
    # the test what it was asked.
    defmacro __using__(key) do
      quote do
        @behaviour PhoenixKitInbox.RecipientSource

        @impl true
        def suggest(_scope, context, query) do
          if pid = context[:pid], do: send(pid, {unquote(key), query})
          Map.get(context, unquote(key), [])
        end
      end
    end
  end

  defmodule SourceA do
    @moduledoc false
    use PhoenixKitInbox.RecipientSourceTest.Sourced, :a
  end

  defmodule SourceB do
    @moduledoc false
    use PhoenixKitInbox.RecipientSourceTest.Sourced, :b
  end

  defmodule Odd do
    @moduledoc false
    defstruct route: :email, address: "odd@example.com"
  end

  defmodule Raises do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource
    @impl true
    def suggest(_scope, _context, query), do: raise("lookup failed for #{query}")
  end

  defmodule Throws do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource
    @impl true
    def suggest(_scope, _context, query), do: throw({:secret, query})
  end

  defmodule Exits do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource
    @impl true
    def suggest(_scope, _context, query), do: exit({:gone, query})
  end

  defmodule Slow do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource
    @impl true
    def suggest(_scope, _context, _query) do
      Process.sleep(5_000)
      [%{address: "late@example.com", route: :email}]
    end
  end

  defmodule NotAList do
    @moduledoc false
    @behaviour PhoenixKitInbox.RecipientSource
    @impl true
    def suggest(_scope, _context, _query), do: :nope
  end

  setup do
    enable_inbox!()
    alice = user_fixture(%{username: "alice_src", first_name: "Alice", last_name: "Source"})
    bob = user_fixture(%{username: "bob_src", first_name: "Bob", last_name: "Member"})
    outsider = user_fixture(%{username: "carol_src", inbox_member: false})
    desk = shared_mailbox_fixture(alice, %{name: "Desk src", address: "desk-src@company.test"})

    %{
      alice: alice,
      bob: bob,
      outsider: outsider,
      desk: desk,
      scope: scope_for(alice)
    }
  end

  describe "RecipientSources.Members" do
    test "members source returns internal users with route internal", ctx do
      suggestions = Members.suggest(ctx.scope, %{}, "src")

      assert %{address: "@bob_src", route: :internal, label: label, group: group} =
               Enum.find(suggestions, &(&1.address == "@bob_src"))

      assert label =~ "Bob"
      assert is_binary(group)
      assert Enum.all?(suggestions, &(&1.route == :internal))

      # Shared mailboxes are inside the application too.
      assert Enum.any?(suggestions, &(&1.address == ctx.desk.slug))

      # Not oneself, not someone outside the circle.
      refute Enum.any?(suggestions, &(&1.address == "@alice_src"))
      refute Enum.any?(suggestions, &(&1.address == "@carol_src"))

      # Narrowed by the query.
      assert [%{address: "@bob_src"}] = Members.suggest(ctx.scope, %{}, "bob_src")
    end

    test "members source is empty without the inbox permission or a scope", ctx do
      assert Members.suggest(scope_for(ctx.alice, []), %{}, "bob") == []
      assert Members.suggest(nil, %{}, "bob") == []
    end
  end

  describe "suggest_all/4" do
    test "an entry that is a struct is dropped, not a crash", ctx do
      context = %{a: [%Odd{}, %{address: "ok@example.com", route: :email}]}

      assert [%{address: "ok@example.com"}] =
               RecipientSource.suggest_all([SourceA], ctx.scope, context, "x")
    end

    test "at most fifty suggestions are kept, the first ones", ctx do
      many = for n <- 1..80, do: %{address: "p#{n}@example.com", route: :email}

      kept = RecipientSource.suggest_all([SourceA], ctx.scope, %{a: many}, "p")

      assert length(kept) == 50
      assert hd(kept).address == "p1@example.com"
      assert List.last(kept).address == "p50@example.com"
    end

    test "a source that is too slow is skipped and the others answer", ctx do
      Application.put_env(:phoenix_kit_inbox, :recipient_source_timeout, 100)
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :recipient_source_timeout) end)
      context = %{a: [%{address: "fast@example.com", route: :email}]}
      started = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          assert [%{address: "fast@example.com"}] =
                   RecipientSource.suggest_all([Slow, SourceA], ctx.scope, context, "zzquery")
        end)

      assert System.monotonic_time(:millisecond) - started < 2_000
      assert log =~ "Slow"
      assert log =~ "too slow"
      refute log =~ "zzquery"
    end

    test "sources are asked at once, not one after the other", ctx do
      Application.put_env(:phoenix_kit_inbox, :recipient_source_timeout, 400)
      on_exit(fn -> Application.delete_env(:phoenix_kit_inbox, :recipient_source_timeout) end)
      started = System.monotonic_time(:millisecond)

      capture_log(fn ->
        RecipientSource.suggest_all([Slow, Slow, Slow, Slow], ctx.scope, %{}, "q")
      end)

      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "merged and deduplicated across sources", ctx do
      user = Ecto.UUID.generate()

      context = %{
        a: [
          %{address: "Client@Example.com", label: nil, route: :email},
          %{user: user, label: "Anna", route: :internal},
          %{address: "only-a@example.com", route: :email}
        ],
        b: [
          # The same address, spelled differently, but with a name: it wins.
          %{address: " client@example.com ", label: "The Client", group: "CRM", route: :email},
          %{user: user, label: "Anna Again", route: :internal},
          %{address: "only-b@example.com", label: "B", route: :email}
        ]
      }

      assert [client, anna, only_a, only_b] =
               RecipientSource.suggest_all([SourceA, SourceB], ctx.scope, context, "x")

      assert client.address == "client@example.com"
      assert client.label == "The Client"
      assert client.group == "CRM"
      # A user is one entry whoever lists them; the first named one stays.
      assert anna == %{user: user, label: "Anna", group: nil, route: :internal}
      assert only_a.address == "only-a@example.com"
      assert only_a.label == nil
      assert only_b.label == "B"
    end

    test "the first source keeps a tie, and order follows first appearance", ctx do
      context = %{
        a: [%{address: "z@example.com", label: "From A", route: :email}],
        b: [
          %{address: "y@example.com", label: "Y", route: :email},
          %{address: "Z@example.com", label: "From B", route: :email}
        ]
      }

      assert [z, y] = RecipientSource.suggest_all([SourceA, SourceB], ctx.scope, context, "")
      assert {z.address, z.label} == {"z@example.com", "From A"}
      assert y.address == "y@example.com"

      assert [y, z] = RecipientSource.suggest_all([SourceB, SourceA], ctx.scope, context, "")
      assert y.address == "y@example.com"
      assert {String.downcase(z.address), z.label} == {"z@example.com", "From B"}
    end

    test "a failing source does not take the others down, nor leak into the log", ctx do
      context = %{a: [%{address: "ok@example.com", label: "Ok", route: :email}]}
      sources = [Raises, SourceA, Throws, Exits, NotAList]

      log =
        capture_log(fn ->
          assert [%{address: "ok@example.com"}] =
                   RecipientSource.suggest_all(sources, ctx.scope, context, "jane@private.test")
        end)

      assert log =~ "recipient source"
      assert log =~ "Raises"
      refute log =~ "jane@private.test"
      refute log =~ "private"
    end

    test "the query is trimmed; an empty or missing query is asked as empty", ctx do
      context = %{pid: self(), a: [], b: []}

      RecipientSource.suggest_all([SourceA, SourceB], ctx.scope, context, "  ann ")
      assert_received {:a, "ann"}
      assert_received {:b, "ann"}

      RecipientSource.suggest_all([SourceA], ctx.scope, context, "")
      assert_received {:a, ""}

      RecipientSource.suggest_all([SourceA], ctx.scope, context, nil)
      assert_received {:a, ""}
    end

    test "entries that are not suggestions are dropped, the rest normalised", ctx do
      context = %{
        a: [
          :junk,
          %{label: "no address or user", route: :email},
          %{address: "x@example.com", route: :carrier_pigeon},
          %{address: "", route: :email},
          %{address: "ok@example.com", label: "  ", group: 5, route: :internal, extra: "ignored"}
        ]
      }

      assert [entry] = RecipientSource.suggest_all([SourceA], ctx.scope, context, "")
      assert entry == %{address: "ok@example.com", label: nil, group: nil, route: :internal}
    end

    test "no sources, or none that is a module, gives nothing", ctx do
      assert RecipientSource.suggest_all([], ctx.scope, %{}, "x") == []
      assert RecipientSource.suggest_all(nil, ctx.scope, %{}, "x") == []

      assert capture_log(fn ->
               assert RecipientSource.suggest_all(["no", 1], ctx.scope, %{}, "x") == []
             end) =~ "recipient source"
    end

    test "Members merges with a host source", ctx do
      unnamed = %{a: [%{address: "@bob_src", route: :internal}]}

      for sources <- [[Members, SourceA], [SourceA, Members]] do
        assert [%{address: "@bob_src", label: "Bob Member", route: :internal}] =
                 RecipientSource.suggest_all(sources, ctx.scope, unnamed, "bob_src")
      end
    end
  end
end
