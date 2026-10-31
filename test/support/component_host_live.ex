defmodule PhoenixKitInbox.Test.ComponentHostLive do
  @moduledoc """
  LiveView that hosts one LiveComponent under test.

  The component module comes from `session["component"]`, its attributes
  (including the required `:id`) from `session["assigns"]`. Messages a
  component sends to its parent, `{:inbox_*, ...}`, are forwarded to
  `session["test_pid"]`, so a test asserts on what the host would receive
  with `assert_receive`.

  Mounted at `/component-host`; tests put the three keys into the session
  with `Plug.Test.init_test_session/2`.
  """

  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:component, Map.fetch!(session, "component"))
     |> assign(:component_assigns, Map.get(session, "assigns", %{}))
     |> assign(:test_pid, Map.fetch!(session, "test_pid"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={@component} {@component_assigns} />
    """
  end

  @impl true
  def handle_info(message, socket) when is_tuple(message) and tuple_size(message) > 0 do
    if inbox_message?(message), do: send(socket.assigns.test_pid, message)

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp inbox_message?(message) do
    case elem(message, 0) do
      tag when is_atom(tag) -> tag |> Atom.to_string() |> String.starts_with?("inbox_")
      _ -> false
    end
  end
end
