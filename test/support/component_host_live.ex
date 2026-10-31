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

  A session cannot carry a function (it is signed as a non-executable term),
  so an attribute that must be one is given as `{:capture, module, name,
  arity}` and turned into the capture here.

  With `session["attach"]` = `{id, filter}` the host does what a real page
  does in `mount/3`: it has the viewer's scope as core's
  `:phoenix_kit_current_scope` (the component's `:scope` attribute) and calls
  `MailExplorer.attach/3`.
  """

  use Phoenix.LiveView

  alias PhoenixKitInbox.Web.Components.MailExplorer

  @impl true
  def mount(_params, session, socket) do
    assigns = session |> Map.get("assigns", %{}) |> captures()

    socket =
      socket
      |> assign(:component, Map.fetch!(session, "component"))
      |> assign(:component_assigns, assigns)
      |> assign(:test_pid, Map.fetch!(session, "test_pid"))
      |> assign(:phoenix_kit_current_scope, assigns[:scope])

    case session do
      %{"attach" => {id, filter}} -> {:ok, MailExplorer.attach(socket, id, filter)}
      _ -> {:ok, socket}
    end
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

  defp captures(assigns) do
    Map.new(assigns, fn
      {key, {:capture, module, name, arity}} -> {key, Function.capture(module, name, arity)}
      pair -> pair
    end)
  end

  defp inbox_message?(message) do
    case elem(message, 0) do
      tag when is_atom(tag) -> tag |> Atom.to_string() |> String.starts_with?("inbox_")
      _ -> false
    end
  end
end
