defmodule PhoenixKitInbox.ErrorsTest do
  @moduledoc """
  What a person is told when a send does not go: the application's own
  messages, a host's refusal in the host's words — and nothing else a host's
  code might answer with.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitInbox.Errors

  @general "The message could not be sent."

  describe "user_message/1" do
    test "a refusal of the host is shown in its own words" do
      assert Errors.user_message({:refused, "Fill in the name before sending."}) ==
               "Fill in the name before sending."

      assert Errors.message({:refused, "The offer is out of date."}) ==
               "The offer is out of date."
    end

    test "a long refusal is cut to 300 characters" do
      text = Errors.user_message({:refused, String.duplicate("a", 500)})

      assert String.length(text) == 300
      assert String.ends_with?(text, "…")
    end

    test "control characters and invalid UTF-8 do not get through" do
      text = Errors.user_message({:refused, "one\u0000 two\nthree\t\xFF four"})

      assert text == "one two three four"
    end

    test "a refusal that is not text, or has none, is the general message" do
      for bad <- [nil, "", "   \n", :atom, 12, %{a: 1}, ["x"], <<255, 254>>] do
        assert Errors.user_message({:refused, bad}) == @general
        assert Errors.message({:refused, bad}) == @general
      end
    end

    test "raw strings and reasons nobody wrote a message for stay hidden" do
      for reason <- [
            "SQL timeout at db-7",
            {:db_down, "10.0.0.7"},
            :nobody_knows,
            %RuntimeError{}
          ] do
        assert Errors.user_message(reason) == @general
      end
    end

    test "the application's own reasons keep their messages" do
      assert Errors.user_message(:no_recipients) == Errors.message(:no_recipients)
    end
  end
end
