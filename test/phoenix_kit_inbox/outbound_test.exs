defmodule PhoenixKitInbox.OutboundTest do
  @moduledoc """
  The one way mail leaves the module: closed by default, always through the
  host's filter, always past the emails queue, through the integration it
  was given.
  """

  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Outbound
  alias PhoenixKitInbox.Test.OutboundFilters

  setup :outbound_setup

  @integration "0190f0f0-0000-7000-8000-000000000001"

  defp email do
    Swoosh.Email.new()
    |> Swoosh.Email.from({"Desk", "desk@company.test"})
    |> Swoosh.Email.to({"Client", "client@example.com"})
    |> Swoosh.Email.cc("partner@example.com")
    |> Swoosh.Email.subject("Offer")
    |> Swoosh.Email.text_body("Text")
  end

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        kind: :message,
        integration_uuid: @integration,
        user_uuid: "0190f0f0-0000-7000-8000-0000000000aa",
        message_uuid: "0190f0f0-0000-7000-8000-0000000000bb"
      },
      extra
    )
  end

  describe "closed by default" do
    test "with the setting off nothing is sent" do
      {:ok, _} = PhoenixKitInbox.set_external_enabled(false)

      assert Outbound.deliver(email(), context()) == {:error, :external_disabled}
      refute Outbound.open?()
      refute_received {:outbound, _, _, _}
    end

    test "without an outbound_filter nothing is sent, even with the setting on" do
      outbound_filter(nil)

      assert Outbound.deliver(email(), context()) == {:error, :external_disabled}
      refute Outbound.open?()
      refute_received {:outbound, _, _, _}
    end

    test "a malformed outbound_filter counts as none" do
      outbound_filter("MyApp.filter")

      assert Outbound.deliver(email(), context()) == {:error, :external_disabled}
      refute_received {:outbound, _, _, _}
    end

    test "an explicit :none with the setting on lets mail through" do
      assert Outbound.open?()
      assert {:ok, %{id: "stub"}} = Outbound.deliver(email(), context())
      assert_received {:outbound, %Swoosh.Email{subject: "Offer"}, @integration, _opts}
    end
  end

  describe "the host filter" do
    test "may rewrite To, Cc, Bcc and Reply-To — and nothing else" do
      outbound_filter({OutboundFilters, :redirect})

      assert {:ok, _} = Outbound.deliver(email(), context())
      assert_received {:outbound, sent, @integration, _opts}

      assert sent.to == [{"", "redirect@test.example"}]
      assert sent.cc == []
      assert sent.bcc == [{"", "bcc-redirect@test.example"}]
      assert sent.reply_to == {"", "reply-redirect@test.example"}
      assert sent.from == {"Desk", "desk@company.test"}
      assert sent.subject == "Offer"
    end

    test "gets the email and the context" do
      outbound_filter({OutboundFilters, :record_context})

      assert {:ok, _} = Outbound.deliver(email(), context(%{kind: :nudge}))
      assert_received {:filter_context, %{kind: :nudge, integration_uuid: @integration}}
    end

    test "a refusal stops the send and is named" do
      outbound_filter({OutboundFilters, :refuse})

      assert Outbound.deliver(email(), context()) ==
               {:error, {:filter_refused, :no_test_address}}

      refute_received {:outbound, _, _, _}
    end

    for fun <- [:raises, :throws, :exits, :garbage, :not_an_email] do
      test "a filter that #{fun} refuses the send" do
        outbound_filter({OutboundFilters, unquote(fun)})

        assert Outbound.deliver(email(), context()) == {:error, :filter_failed}
        refute_received {:outbound, _, _, _}
      end
    end

    test "a filter that leaves no recipient sends nothing" do
      outbound_filter({OutboundFilters, :drops_everyone})

      assert Outbound.deliver(email(), context()) == {:error, :no_recipients}
      refute_received {:outbound, _, _, _}
    end
  end

  describe "the call to core" do
    test "skips the emails queue and carries the sender, integration and tags, every time" do
      for kind <- [:message, :nudge, :message] do
        assert {:ok, _} = Outbound.deliver(email(), context(%{kind: kind}))
        assert_received {:outbound, _email, @integration, opts}

        assert opts[:skip_queue] == true
        assert opts[:queue] == false
        assert opts[:integration_uuid] == @integration
        assert opts[:user_uuid] == "0190f0f0-0000-7000-8000-0000000000aa"

        assert opts[:message_tags] == %{
                 "source" => "inbox",
                 "inbox_message_uuid" => "0190f0f0-0000-7000-8000-0000000000bb",
                 "inbox_kind" => Atom.to_string(kind)
               }
      end
    end

    test "a transport error comes back as it is" do
      outbound_result({:error, :not_configured})
      assert Outbound.deliver(email(), context()) == {:error, :not_configured}
    end

    test "a transport that raises is a failed send, not a crash" do
      outbound_result(fn _, _, _ -> raise "smtp exploded" end)
      assert {:error, {:transport_failed, "smtp exploded"}} = Outbound.deliver(email(), context())
    end

    test "without an integration nothing is sent" do
      assert Outbound.deliver(email(), context(%{integration_uuid: nil})) ==
               {:error, :no_integration}

      refute_received {:outbound, _, _, _}
    end

    test "by default the transport is core's mailer, through the given integration" do
      Application.delete_env(:phoenix_kit_inbox, :outbound)

      # An integration that does not exist: core's own answer, and no mail.
      assert Outbound.deliver(email(), context()) in [
               {:error, :not_configured},
               {:error, :deleted}
             ]
    end
  end
end
