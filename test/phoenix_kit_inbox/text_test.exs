defmodule PhoenixKitInbox.TextTest do
  use ExUnit.Case, async: true

  alias PhoenixKitInbox.Text

  describe "storable?/1" do
    test "valid text is, a NUL byte, broken UTF-8 and non-text are not" do
      assert Text.storable?("Hello, мир")
      assert Text.storable?("")
      refute Text.storable?("a\0b")
      refute Text.storable?(<<0xFF, 0xFE>>)
      refute Text.storable?(nil)
      refute Text.storable?(5)
    end
  end

  describe "fits?/2" do
    test "counts code points, not graphemes or bytes, and wants something there" do
      assert Text.fits?(String.duplicate("é", 32), 64)
      refute Text.fits?(String.duplicate("é", 33), 64)
      assert Text.fits?(String.duplicate("я", 64), 64)
      refute Text.fits?("", 64)
      refute Text.fits?("a\0", 64)
      refute Text.fits?(<<0xFF>>, 64)
      refute Text.fits?(:atom, 64)
    end
  end
end
