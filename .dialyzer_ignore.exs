[
  # Ecto.Multi is @opaque. When dialyzer can see the literal
  # `%Ecto.Multi{names: %MapSet{map: %{}}, operations: []}` a bare
  # `Multi.new()` produces, piping it straight into `Multi.run/3` reads as an
  # opaque-subterm mismatch even though the call is correct. Known Ecto +
  # dialyzer false positive — same entry `phoenix_kit_catalogue` carries for
  # `Multi.update_all/3`.
  {"lib/phoenix_kit_inbox/messages.ex", :call_without_opaque},

  # Gettext 1.0 + Expo 1.1: the backend `use Gettext.Backend` generates calls
  # `Gettext.Plural.plural/2` against Expo's opaque `PluralForms` struct (it
  # shows once a plural message exists). Upstream false positive in code we
  # don't author; the same skip phoenix_kit_ai and other packages carry.
  {"lib/phoenix_kit_inbox/gettext.ex", :call_without_opaque}
]
