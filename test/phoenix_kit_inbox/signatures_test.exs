defmodule PhoenixKitInbox.SignaturesTest do
  use PhoenixKitInbox.DataCase, async: false

  alias PhoenixKitInbox.Mailboxes
  alias PhoenixKitInbox.Schemas.Signature
  alias PhoenixKitInbox.Signatures

  @manage ["inbox", "inbox.manage_shared"]

  setup do
    enable_inbox!()
    admin = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    desk = shared_mailbox_fixture(admin, %{name: "Desk"})
    {:ok, alice_mb} = Mailboxes.ensure_user_mailbox(alice)

    %{admin: admin, alice: alice, bob: bob, desk: desk, alice_mb: alice_mb}
  end

  describe "personal mailbox" do
    test "its owner writes the signatures", ctx do
      assert {:ok, %Signature{} = sig} =
               Signatures.create_signature(scope_for(ctx.alice), ctx.alice_mb, %{
                 "label" => "Work",
                 "body" => "**Alice**  \nAcme"
               })

      assert sig.mailbox_uuid == ctx.alice_mb.uuid
      assert [%Signature{uuid: uuid}] = Signatures.list(ctx.alice_mb.uuid)
      assert uuid == sig.uuid

      assert {:ok, %Signature{label: "Home"}} =
               Signatures.update_signature(scope_for(ctx.alice), sig, %{"label" => "Home"})

      assert :ok = Signatures.delete_signature(scope_for(ctx.alice), sig)
      assert Signatures.list(ctx.alice_mb.uuid) == []
    end

    test "nobody else does, whatever their permissions", ctx do
      {:ok, sig} =
        Signatures.create_signature(scope_for(ctx.alice), ctx.alice_mb, %{"label" => "Work"})

      intruder = scope_for(ctx.bob, @manage)

      assert {:error, :mailbox_access_denied} =
               Signatures.create_signature(intruder, ctx.alice_mb, %{"label" => "Forged"})

      assert {:error, :mailbox_access_denied} =
               Signatures.update_signature(intruder, sig, %{"body" => "pwned"})

      assert {:error, :mailbox_access_denied} = Signatures.delete_signature(intruder, sig)
      assert [%Signature{body: ""}] = Signatures.list(ctx.alice_mb.uuid)
    end

    test "a hand-built signature struct can't move the write to another mailbox", ctx do
      {:ok, bobs} =
        Signatures.create_signature(
          scope_for(ctx.bob),
          elem(Mailboxes.ensure_user_mailbox(ctx.bob), 1),
          %{"label" => "Bob"}
        )

      forged = %{bobs | mailbox_uuid: ctx.alice_mb.uuid}

      assert {:error, :mailbox_access_denied} =
               Signatures.update_signature(scope_for(ctx.alice), forged, %{"body" => "x"})

      assert {:error, :mailbox_access_denied} =
               Signatures.delete_signature(scope_for(ctx.alice), forged)
    end

    test "needs the inbox permission", ctx do
      assert {:error, :forbidden} =
               Signatures.create_signature(scope_for(ctx.alice, []), ctx.alice_mb, %{
                 "label" => "Work"
               })
    end
  end

  describe "shared mailbox" do
    test "needs admin on the mailbox and inbox.manage_shared", ctx do
      grant_fixture(ctx.desk, ctx.alice, "admin")
      grant_fixture(ctx.desk, ctx.bob, "write")

      assert {:error, :forbidden} =
               Signatures.create_signature(scope_for(ctx.alice), ctx.desk, %{"label" => "Desk"})

      assert {:error, :mailbox_access_denied} =
               Signatures.create_signature(scope_for(ctx.bob, @manage), ctx.desk, %{
                 "label" => "Desk"
               })

      assert {:ok, sig} =
               Signatures.create_signature(scope_for(ctx.alice, @manage), ctx.desk, %{
                 "label" => "Desk"
               })

      assert {:error, :forbidden} =
               Signatures.update_signature(scope_for(ctx.alice), sig, %{"label" => "Mine"})

      assert {:error, :forbidden} = Signatures.delete_signature(scope_for(ctx.alice), sig)
    end
  end

  describe "defaults" do
    test "making one the default clears the others of that mailbox only", ctx do
      scope = scope_for(ctx.alice)

      {:ok, first} =
        Signatures.create_signature(scope, ctx.alice_mb, %{
          "label" => "First",
          "is_default" => "true"
        })

      {:ok, desk_sig} =
        Signatures.create_signature(scope_for(ctx.admin, @manage), ctx.desk, %{
          "label" => "Desk",
          "is_default" => true
        })

      {:ok, second} =
        Signatures.create_signature(scope, ctx.alice_mb, %{
          "label" => "Second",
          "is_default" => true
        })

      refute Repo.get(Signature, first.uuid).is_default
      assert Repo.get(Signature, second.uuid).is_default
      assert Repo.get(Signature, desk_sig.uuid).is_default
      assert Signatures.default(ctx.alice_mb.uuid).uuid == second.uuid

      {:ok, _} = Signatures.update_signature(scope, first, %{"is_default" => true})
      assert Signatures.default(ctx.alice_mb.uuid).uuid == first.uuid
      assert [%{uuid: default_first} | _] = Signatures.list(ctx.alice_mb.uuid)
      assert default_first == first.uuid
    end

    test "no default is nil", ctx do
      assert Signatures.default(ctx.alice_mb.uuid) == nil
    end
  end

  describe "validation" do
    test "a label is required and the body has a cap", ctx do
      scope = scope_for(ctx.alice)

      assert {:error, %Ecto.Changeset{} = blank} =
               Signatures.create_signature(scope, ctx.alice_mb, %{"label" => " "})

      assert %{label: [_ | _]} = errors_on(blank)

      long = String.duplicate("a", Signature.max_body() + 1)

      assert {:error, %Ecto.Changeset{} = too_long} =
               Signatures.create_signature(scope, ctx.alice_mb, %{"label" => "L", "body" => long})

      assert %{body: [_ | _]} = errors_on(too_long)
    end

    test "the mailbox comes from the argument, never the form", ctx do
      {:ok, sig} =
        Signatures.create_signature(scope_for(ctx.alice), ctx.alice_mb, %{
          "label" => "Work",
          "mailbox_uuid" => ctx.desk.uuid
        })

      assert sig.mailbox_uuid == ctx.alice_mb.uuid
    end
  end

  describe "block/1 and swap_block/3" do
    test "the block is the body after a \"-- \" line, at the end of a message" do
      assert Signatures.block(%Signature{body: "Alice\nAcme"}) == "\n\n-- \nAlice\nAcme"
      assert Signatures.block(nil) == ""
      assert Signatures.block(%Signature{body: ""}) == ""
    end

    test "inserts into a body without one" do
      new = %Signature{body: "Alice"}
      assert Signatures.swap_block("Hello", "", new) == {:ok, "Hello\n\n-- \nAlice"}
    end

    test "replaces the block it inserted when the user left it alone" do
      old = %Signature{body: "Alice"}
      new = %Signature{body: "Bob"}
      body = "Hello" <> Signatures.block(old)

      assert Signatures.swap_block(body, Signatures.block(old), new) ==
               {:ok, "Hello\n\n-- \nBob"}

      assert Signatures.swap_block(body, Signatures.block(old), nil) == {:ok, "Hello"}
    end

    test "leaves an edited block alone" do
      old = %Signature{body: "Alice"}
      body = "Hello\n\n-- \nAlice (edited)"

      assert Signatures.swap_block(body, Signatures.block(old), %Signature{body: "Bob"}) ==
               :edited
    end
  end
end
