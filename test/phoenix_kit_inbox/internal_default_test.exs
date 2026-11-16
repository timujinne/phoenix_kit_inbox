defmodule PhoenixKitInbox.InternalDefaultTest do
  @moduledoc """
  What the switch for mail inside the application is when nothing was saved:
  the host's `internal_mail_default`, and the text of its error.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitInbox.Errors

  setup do
    saved = Application.fetch_env(:phoenix_kit_inbox, :internal_mail_default)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:phoenix_kit_inbox, :internal_mail_default, value)
        :error -> Application.delete_env(:phoenix_kit_inbox, :internal_mail_default)
      end
    end)

    Application.delete_env(:phoenix_kit_inbox, :internal_mail_default)
    :ok
  end

  defp default(value), do: Application.put_env(:phoenix_kit_inbox, :internal_mail_default, value)

  test "with nothing saved and nothing configured, internal mail is on" do
    assert PhoenixKitInbox.internal_enabled?()
  end

  test "the host's internal_mail_default is what an unsaved setting reads as" do
    default(false)
    refute PhoenixKitInbox.internal_enabled?()

    default(true)
    assert PhoenixKitInbox.internal_enabled?()
  end

  test "an entry that is not a boolean does not switch it off by accident" do
    default(:nonsense)
    assert PhoenixKitInbox.internal_enabled?()
  end

  test "the error has words in the three languages" do
    texts = %{
      "en" => "Mail inside this application is turned off. Write to an email address instead.",
      "ru" => "Почта внутри приложения отключена. Напишите на адрес электронной почты.",
      "et" => "Rakendusesisene post on välja lülitatud. Kirjuta e-posti aadressile."
    }

    for {locale, text} <- texts do
      assert Gettext.with_locale(PhoenixKitInbox.Gettext, locale, fn ->
               Errors.message(:internal_mail_disabled)
             end) == text
    end
  end
end
