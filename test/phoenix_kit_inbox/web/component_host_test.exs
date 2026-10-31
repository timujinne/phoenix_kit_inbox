defmodule PhoenixKitInbox.Web.ComponentHostTest do
  use PhoenixKitInbox.LiveCase

  defmodule PingComponent do
    use Phoenix.LiveComponent

    def render(assigns) do
      ~H"""
      <div id={"ping-#{@id}"}>
        <span>{@label}</span>
        <button phx-click="ping" phx-target={@myself}>Ping</button>
      </div>
      """
    end

    def handle_event("ping", _params, socket) do
      send(self(), {:inbox_ping, socket.assigns.id})
      {:noreply, socket}
    end
  end

  test "host mounts a trivial component and forwards its messages", %{conn: conn} do
    conn =
      Plug.Test.init_test_session(conn, %{
        "component" => PingComponent,
        "assigns" => %{id: "demo", label: "Hello from component"},
        "test_pid" => self()
      })

    {:ok, view, html} = live(conn, "/component-host")

    assert html =~ "Hello from component"

    view |> element("#ping-demo button") |> render_click()

    assert_receive {:inbox_ping, "demo"}
  end
end
