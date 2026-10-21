defmodule PhoenixKitInbox.Test.OutboundFilters do
  @moduledoc """
  Host `outbound_filter` functions for tests, one per behaviour a host
  filter can have.
  """

  @doc "Redirects every recipient to the test address, as a staging host would."
  def redirect(email, _context) do
    {:ok,
     %{
       email
       | to: [{"", "redirect@test.example"}],
         cc: [],
         bcc: [{"", "bcc-redirect@test.example"}],
         reply_to: {"", "reply-redirect@test.example"},
         # Not addressing — a filter has no say over these.
         from: {"Forged", "forged@test.example"},
         subject: "Rewritten"
     }}
  end

  @doc "Remembers the context it was given, then lets the email through."
  def record_context(email, context) do
    if pid = Application.get_env(:phoenix_kit_inbox, :test_outbound, %{})[:pid],
      do: send(pid, {:filter_context, context})

    {:ok, email}
  end

  def refuse(_email, _context), do: {:error, :no_test_address}
  def raises(_email, _context), do: raise("filter bug")
  def throws(_email, _context), do: throw(:filter_threw)
  def exits(_email, _context), do: exit(:filter_exited)
  def garbage(_email, _context), do: :ok
  def not_an_email(_email, _context), do: {:ok, %{to: "x@test.example"}}
  def drops_everyone(email, _context), do: {:ok, %{email | to: [], cc: [], bcc: []}}
end
