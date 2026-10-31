defmodule PhoenixKitInbox.Text do
  @moduledoc """
  What the database accepts as text — the one place the module asks. Postgres
  refuses, with an exception instead of an error, a NUL byte and bytes that are
  not UTF-8, and counts the length of a `varchar(n)` in code points (not
  graphemes, not bytes).
  """

  @doc "Whether `value` is valid UTF-8 without a NUL byte (an empty text is)."
  @spec storable?(term()) :: boolean()
  def storable?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  def storable?(_value), do: false

  @doc """
  Whether `value` fits a `varchar(max)` column and is something: non-empty,
  `storable?/1`, at most `max` code points long.
  """
  @spec fits?(term(), pos_integer()) :: boolean()
  def fits?(value, max) when is_binary(value),
    do: value != "" and storable?(value) and length(String.to_charlist(value)) <= max

  def fits?(_value, _max), do: false
end
