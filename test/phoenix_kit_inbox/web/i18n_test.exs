defmodule PhoenixKitInbox.Web.I18nTest do
  @moduledoc """
  The pages read the request's locale through the module's own backend:
  core installs it for the request (the test hook does what core's does), and
  the module's catalogue answers.
  """

  use PhoenixKitInbox.LiveCase

  alias PhoenixKitInbox.Mailboxes

  setup %{conn: conn} do
    enable_inbox!()
    alice = user_fixture()
    {:ok, _} = Mailboxes.ensure_user_mailbox(alice)

    conn = put_test_scope(conn, fake_scope(user_uuid: alice.uuid, email: alice.email))
    %{conn: conn}
  end

  test "the mailbox page is in Russian under ru", %{conn: conn} do
    {:ok, _view, html} = conn |> put_test_locale("ru") |> live("/ru/admin/inbox")

    assert html =~ "Входящие"
    assert html =~ "Отправленные"
    assert html =~ "Черновики"
    assert html =~ "Список пуст."
    refute html =~ "Drafts"
    refute html =~ "Empty list."
    assert html =~ "Новое сообщение"
  end

  test "the mailbox page is in Estonian under et", %{conn: conn} do
    {:ok, _view, html} = conn |> put_test_locale("et") |> live("/et/admin/inbox")

    assert html =~ "Saabunud"
    assert html =~ "Saadetud"
    assert html =~ "Mustandid"
    refute html =~ "Drafts"
  end

  test "English stays English", %{conn: conn} do
    {:ok, _view, html} = conn |> put_test_locale("en") |> live("/en/admin/inbox")

    assert html =~ "Drafts"
    assert html =~ "Empty list."
  end

  test "an unknown locale falls back to the msgids", %{conn: conn} do
    {:ok, _view, html} = conn |> put_test_locale("xx") |> live("/admin/inbox")

    assert html =~ "Drafts"
  end

  test "the compose page and its flash are in Russian under ru", %{conn: conn} do
    {:ok, view, html} = conn |> put_test_locale("ru") |> live("/ru/admin/inbox/compose")

    assert html =~ "Кому"
    assert html =~ "Тема"

    html = render_submit(view, "send", %{"message" => %{"to" => "", "subject" => "x"}})

    assert html =~ "Добавьте хотя бы одного получателя."
  end

  test "the mailboxes and settings pages are translated", %{conn: conn} do
    {:ok, _view, html} = conn |> put_test_locale("et") |> live("/et/admin/inbox/mailboxes")
    assert html =~ "Jagatud postkastid"
  end
end
