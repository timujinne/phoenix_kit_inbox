defmodule PhoenixKitInbox.GettextCatalogueTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitInbox.Errors
  alias PhoenixKitInbox.Gettext, as: Backend

  @priv Path.expand("../../priv/gettext", __DIR__)

  defp messages(locale) do
    %{messages: messages} =
      Expo.PO.parse_file!(Path.join([@priv, locale, "LC_MESSAGES", "default.po"]))

    messages
  end

  test "the module ships the three catalogues" do
    assert Enum.sort(Gettext.known_locales(Backend)) == ["en", "et", "ru"]
  end

  for locale <- ["et", "ru"] do
    test "every msgid is translated into #{locale}, placeholders intact" do
      for %Expo.Message.Singular{msgid: msgid, msgstr: msgstr} <- messages(unquote(locale)) do
        id = IO.iodata_to_binary(msgid)
        str = IO.iodata_to_binary(msgstr)

        assert str != "", "#{unquote(locale)}: no translation for #{inspect(id)}"

        assert placeholders(id) == placeholders(str),
               "#{unquote(locale)}: placeholders differ in #{inspect(id)}"
      end
    end
  end

  test "Errors speak the process locale of the backend" do
    assert Gettext.with_locale(Backend, "ru", fn -> Errors.message(:message_not_found) end) ==
             "Сообщение не найдено."

    assert Gettext.with_locale(Backend, "et", fn -> Errors.message(:message_not_found) end) ==
             "Sõnumit ei leitud."

    assert Gettext.with_locale(Backend, "en", fn -> Errors.message(:message_not_found) end) ==
             "Message not found."
  end

  test "a backend with no locale of its own reads the process-wide one" do
    # async test: the locale lives in this test's own process, which ends with it
    Gettext.put_locale("ru")

    assert Errors.message({:too_many_attachments, 3}) ==
             "К сообщению можно прикрепить не более 3 файлов."

    assert PhoenixKitInbox.Mailboxes.user_display_name(%{uuid: "abcdef12-0000"}) ==
             "Пользователь abcdef12"
  end

  test "the permission labels are localized by the module's backend" do
    meta = PhoenixKitInbox.permission_metadata()
    assert meta.gettext_backend == Backend

    Gettext.with_locale(Backend, "ru", fn ->
      assert Gettext.gettext(Backend, meta.label) == "Почта"
      [external, shared] = meta.sub_permissions
      assert Gettext.gettext(Backend, external.label) == "Отправка на внешние адреса"
      assert Gettext.gettext(Backend, shared.label) == "Управление общими ящиками"
    end)
  end

  test "the attachment limit takes the plural form of the language" do
    ru = fn max ->
      Gettext.with_locale(Backend, "ru", fn -> Errors.message({:too_many_attachments, max}) end)
    end

    assert ru.(1) =~ "не более 1 файла"
    assert ru.(3) =~ "не более 3 файлов"
    assert ru.(21) =~ "не более 21 файла"
    assert ru.(50) =~ "не более 50 файлов"
  end

  test "the sidebar tabs are localized by the module's backend" do
    for {locale, labels} <- [
          {"ru", {"Почта", "Входящие", "Почта"}},
          {"et", {"Post", "Saabunud", "Post"}},
          {"en", {"Mail", "Inbox", "Mail"}}
        ] do
      Gettext.with_locale(Backend, locale, fn ->
        tabs =
          Map.new(
            PhoenixKitInbox.admin_tabs() ++ PhoenixKitInbox.settings_tabs(),
            &{&1.id, Tab.localized_label(&1)}
          )

        assert {tabs[:admin_inbox], tabs[:admin_inbox_messages], tabs[:admin_settings_inbox]} ==
                 labels
      end)
    end

    for tab <-
          PhoenixKitInbox.admin_tabs() ++
            PhoenixKitInbox.settings_tabs() ++ PhoenixKitInbox.user_dashboard_tabs() do
      assert tab.gettext_backend == Backend
    end
  end

  defp placeholders(string),
    do: ~r/%\{\w+\}/ |> Regex.scan(string) |> List.flatten() |> Enum.sort()
end
