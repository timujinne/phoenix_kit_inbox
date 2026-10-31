defmodule PhoenixKitInbox.LinkResolver do
  @moduledoc """
  How a host teaches the module to find its own objects in the subject of a
  message.

  A message may be linked to objects of the host — a `kind` (what sort of
  object) and a `ref` (which one) the module neither knows nor checks. Besides
  the links a host gives explicitly when sending, every new message is run
  through the resolvers the host registered:

      config :phoenix_kit_inbox, link_resolvers: [MyApp.OrderLinks]

  For each resolver the module calls `extract/1` with the subject, then
  `exists?/1` with every `ref` that came back, and links the message (source
  `"subject"`) only to the refs for which the host answered `true`. A ref has
  the same form the host passes in the `links:` option of
  `PhoenixKitInbox.Messages.send_message/4`.

  A resolver that raises, throws or exits is logged and skipped: the message
  is stored regardless and the other resolvers still run. Both callbacks run in
  the process that sends the message, after the send has been stored, so keep
  them cheap.

  Return a ref from `extract/1` only when the subject names the object
  unambiguously — a number shared by two objects is better left to a person
  to link by hand.
  """

  @doc "The `kind` of the links this resolver finds, at most 64 characters."
  @callback kind() :: String.t()

  @doc "The refs named in `subject`, at most 255 characters each; `[]` when none."
  @callback extract(subject :: String.t()) :: [String.t()]

  @doc "Whether the host has an object for `ref` of this resolver's kind."
  @callback exists?(ref :: String.t()) :: boolean()
end
