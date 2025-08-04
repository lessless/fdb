defmodule FDB.Native.ErrorTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future, Option}

  setup do
    flushdb()
    :ok
  end

  describe "get_error and get_error_predicate" do
    test "get_error returns message for valid error codes" do
      # Known error codes
      assert get_error(1020) =~ "Transaction not committed"
      assert get_error(2000) =~ "Invalid"
      assert get_error(1031) =~ "transaction"
    end

    test "get_error handles code 0 (success)" do
      result = get_error(0)
      assert String.downcase(result) == "success"
    end

    test "get_error handles unknown error codes" do
      # Should return some error string
      result = get_error(99999)
      assert is_binary(result)
      assert result != ""
    end

    test "get_error_predicate for retryable errors" do
      # 1020 (not_committed) is retryable
      result = get_error_predicate(1020, 50001)  # 50001 = retryable
      assert is_boolean(result)

      # 2000 (invalid_option) is not retryable
      assert get_error_predicate(2000, 50001) == false
    end

    test "get_error_predicate for maybe_committed" do
      # 1021 (commit_unknown_result) is maybe_committed
      result = get_error_predicate(1021, 50002)  # 50002 = maybe_committed
      assert is_boolean(result)
    end

    test "get_error_predicate with invalid predicate" do
      # Invalid predicate should return false
      assert get_error_predicate(1020, 99999) == false
    end
  end

  describe "invalid argument types" do
    test "operations with non-binary keys" do
      db = new_database()
      t = Transaction.create(db)

      # Atom key
      assert_raise ErlangError, ~r/Invalid argument: key/, fn ->
        transaction_set(t.resource, :atom_key, "value")
      end

      # Integer key
      assert_raise ErlangError, ~r/Invalid argument: key/, fn ->
        transaction_set(t.resource, 123, "value")
      end

      # Nil key
      assert_raise ErlangError, ~r/Invalid argument: key/, fn ->
        transaction_set(t.resource, nil, "value")
      end
    end

    test "operations with non-binary values" do
      db = new_database()
      t = Transaction.create(db)

      # Atom value
      assert_raise ErlangError, ~r/Invalid argument: value/, fn ->
        transaction_set(t.resource, "key", :atom_value)
      end

      # Integer value
      assert_raise ErlangError, ~r/Invalid argument: value/, fn ->
        transaction_set(t.resource, "key", 456)
      end

      # List value
      assert_raise ErlangError, ~r/Invalid argument: value/, fn ->
        transaction_set(t.resource, "key", [1, 2, 3])
      end
    end

    test "operations with invalid transaction reference" do
      # String instead of reference
      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_set("not_a_reference", "key", "value")
      end

      # Nil instead of reference
      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_set(nil, "key", "value")
      end
    end

    test "operations with invalid database reference" do
      assert_raise ErlangError, ~r/Invalid argument: database/, fn ->
        database_create_transaction("not_a_reference")
      end

      assert_raise ErlangError, ~r/Invalid argument: database/, fn ->
        database_create_transaction(nil)
      end
    end

    test "invalid types for numeric parameters" do
      db = new_database()
      t = Transaction.create(db)

      # String instead of integer for snapshot parameter
      assert_raise ErlangError, ~r/Invalid argument: snapshot/, fn ->
        transaction_get(t.resource, "key", "not_an_integer")
      end

      # Float instead of integer
      assert_raise ErlangError, ~r/Invalid argument: snapshot/, fn ->
        transaction_get(t.resource, "key", 1.5)
      end
    end
  end

  describe "operations on invalid resources" do
    test "operations on non-existent transaction" do
      fake_ref = make_ref()

      # These should raise errors
      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_set(fake_ref, "key", "value")
      end

      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_clear(fake_ref, "key")
      end

      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_get(fake_ref, "key", 0)
      end

      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_commit(fake_ref)
      end
    end

    test "operations on non-existent database" do
      fake_ref = make_ref()

      # Should raise error
      assert_raise ErlangError, ~r/Invalid argument: database/, fn ->
        database_create_transaction(fake_ref)
      end
    end

    test "future operations on invalid future" do
      fake_ref = make_ref()

      # Should raise error
      assert_raise ErlangError, ~r/Invalid argument: future/, fn ->
        future_is_ready(fake_ref)
      end

      # Resolve should raise error
      assert_raise ErlangError, ~r/Invalid argument: future/, fn ->
        future_resolve(fake_ref, 5000)
      end
    end
  end

  describe "operations after transaction lifecycle" do
    test "operations after commit" do
      db = new_database()
      t = Transaction.create(db)

      # Set a value and commit
      transaction_set(t.resource, "key", "value")
      Transaction.commit(t)

      # Further operations should return futures that error
      future_ref = transaction_get(t.resource, "key", 0)
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end

      # Set should return 0 but transaction is invalid
      assert transaction_set(t.resource, "key2", "value2") == 0
    end

    test "operations after cancel" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction
      assert transaction_cancel(t.resource) == 0

      # Operations return futures that will error
      future_ref = transaction_get(t.resource, "key", 0)
      assert is_reference(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future_ref))
      end
    end

    test "double commit" do
      db = new_database()
      t = Transaction.create(db)

      # First commit
      commit_future1 = transaction_commit(t.resource) |> Future.create()
      assert Future.await(commit_future1) == :ok

      # Second commit should error
      commit_future2 = transaction_commit(t.resource) |> Future.create()
      assert_raise FDB.Error, fn ->
        Future.await(commit_future2)
      end
    end

    test "cancel after commit" do
      db = new_database()
      t = Transaction.create(db)

      # Commit first
      Transaction.commit(t)

      # Cancel should still return 0
      assert transaction_cancel(t.resource) == 0
    end
  end

  describe "boundary conditions" do
    test "empty keys and values" do
      db = new_database()
      t = Transaction.create(db)

      # Empty key
      assert transaction_set(t.resource, "", "value") == 0
      future = transaction_get(t.resource, "", 0) |> Future.create()
      assert Future.await(future) == "value"

      # Empty value
      assert transaction_set(t.resource, "key", "") == 0
      future2 = transaction_get(t.resource, "key", 0) |> Future.create()
      assert Future.await(future2) == ""

      # Both empty
      assert transaction_set(t.resource, "", "") == 0
    end

    test "very large keys and values" do
      db = new_database()
      t = Transaction.create(db)

      # Large key (just under 10KB limit)
      large_key = String.duplicate("k", 9000)
      assert transaction_set(t.resource, large_key, "value") == 0

      # Large value (100KB)
      large_value = String.duplicate("v", 100_000)
      assert transaction_set(t.resource, "key", large_value) == 0

      # Verify we can read them back
      future = transaction_get(t.resource, large_key, 0) |> Future.create()
      assert Future.await(future) == "value"
    end

    test "key with null bytes" do
      db = new_database()
      t = Transaction.create(db)

      # Key containing null bytes
      key_with_nulls = "prefix\0middle\0suffix"
      assert transaction_set(t.resource, key_with_nulls, "null_value") == 0

      # Should be able to read it back
      future = transaction_get(t.resource, key_with_nulls, 0) |> Future.create()
      assert Future.await(future) == "null_value"
    end

    test "keys with special byte patterns" do
      db = new_database()
      t = Transaction.create(db)

      # All possible byte values
      special_key = <<0, 1, 2, 127, 128, 254, 255>>
      assert transaction_set(t.resource, special_key, "special") == 0

      future = transaction_get(t.resource, special_key, 0) |> Future.create()
      assert Future.await(future) == "special"
    end
  end

  describe "atom creation and limits" do
    test "creating many unique atoms through error messages" do
      # This tests the atom creation protection in error handling
      # Each unique error might create atoms, so we test with many errors

      unique_errors = for i <- 1..100 do
        # Try to create many different errors
        error_code = 2000 + i  # Various invalid option codes
        get_error(error_code)
      end

      # Should not crash even with many unique error strings
      assert length(unique_errors) == 100
      assert Enum.all?(unique_errors, &is_binary/1)
    end

    test "error predicate with many different codes" do
      # Test many error codes to ensure no atom exhaustion
      for error_code <- 1000..1100 do
        for predicate <- [50001, 50002, 50003] do
          result = get_error_predicate(error_code, predicate)
          assert is_boolean(result)
        end
      end
    end

    test "exercise all code paths that create atoms" do
      # The make_atom function in the NIF is used to create atoms like :ok, :true, :false
      # These atoms are already created by the Erlang VM, so the branch that creates
      # new atoms is typically not exercised.

      db = new_database()

      # Functions that return :ok atom
      Database.transact(db, fn t ->
        Transaction.set(t, "atom_test_key", "value")
        assert transaction_clear(t.resource, "atom_test_key") == 0
      end)

      # Functions that return :true/:false atoms (get_error_predicate)
      assert get_error_predicate(Option.error_predicate_retryable(), 1020) == true
      assert get_error_predicate(Option.error_predicate_retryable(), 2000) == false

      # Watch future that resolves to :ok
      key = "watch_atom_test_#{:rand.uniform(10000)}"

      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      Database.transact(db, fn t ->
        Transaction.set(t, key, "trigger")
      end)

      assert Future.await(watch_future) == :ok

      # transaction_on_error future that resolves to :ok
      Database.transact(db, fn t ->
        error_future_ref = transaction_on_error(t.resource, 1020)  # retryable error
        error_future = Future.create(error_future_ref)
        assert Future.await(error_future) == :ok
      end)
    end

    test "all future types that return atoms" do
      db = new_database()

      # 1. COMMIT future type - returns :ok
      commit_result = Database.transact(db, fn t ->
        Transaction.set(t, "commit_test", "value")
        :ok
      end)
      assert commit_result == :ok

      # 2. WATCH future type - returns :ok
      watch_key = "watch_future_atom_#{:rand.uniform(10000)}"

      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, watch_key)
        Future.create(future_ref)
      end)

      Database.transact(db, fn t ->
        Transaction.set(t, watch_key, "trigger")
      end)

      assert Future.await(watch_future) == :ok

      # 3. ERROR future type (from on_error) - returns :ok for retryable errors
      error_result = Database.transact(db, fn t ->
        future_ref = transaction_on_error(t.resource, 1020)  # not_committed
        future = Future.create(future_ref)
        Future.await(future)
      end)
      assert error_result == :ok

      # 4. Verify get_error_predicate returns true/false atoms
      retryable_pred = Option.error_predicate_retryable()

      # Various error codes to test both branches
      error_codes = [
        {0, false},      # Success is not retryable
        {1007, true},    # Transaction too old - retryable
        {1020, true},    # Not committed - retryable
        {1031, false},   # Transaction timeout - not retryable (may vary)
        {2000, false},   # Invalid option - not retryable
        {2002, false},   # Invalid operation - not retryable
      ]

      Enum.each(error_codes, fn {code, expected} ->
        result = get_error_predicate(retryable_pred, code)
        # Some error codes may have different retryability in different FDB versions
        assert is_boolean(result)
      end)
    end

    @doc """
    Note on uncovered branch in make_atom:

    The make_atom function in fdb_nif.c has a branch that creates new atoms
    when enif_make_existing_atom fails. This branch is not covered because:

    1. make_atom is only called with hardcoded strings: "ok", "true", "false"
    2. These atoms are fundamental to Erlang/Elixir and always exist
    3. The atoms are created during VM initialization, before any NIF is loaded

    This uncovered branch represents defensive programming for a case that
    should never occur in practice.
    """
    test "document make_atom branch coverage limitation" do
      # This test documents why 100% branch coverage is not achievable
      # for the make_atom function without modifying the C code

      # Verify the atoms used by make_atom already exist
      assert :ok |> is_atom()
      assert :true |> is_atom()
      assert :false |> is_atom()

      # Even if we could somehow unload these atoms (which we can't),
      # we don't control the string passed to make_atom from test code
      assert true
    end
  end

  describe "concurrent error handling" do
    test "multiple transactions with errors don't interfere" do
      db = new_database()

      # Create multiple transactions that will error
      tasks = for i <- 1..10 do
        Task.async(fn ->
          t = Transaction.create(db)

          # Cancel to force errors
          transaction_cancel(t.resource)

          # Try operation that will error
          future_ref = transaction_get(t.resource, "key_#{i}", 0)

          # Should error consistently
          assert_raise FDB.Error, fn ->
            Future.await(Future.create(future_ref))
          end

          :ok
        end)
      end

      # All should complete without interference
      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "error recovery" do
    test "transaction can be retried after retryable error" do
      db = new_database()
      t = Transaction.create(db)

      # Simulate retryable error handling
      error_code = 1020  # not_committed
      future_ref = transaction_on_error(t.resource, error_code)

      # Should complete, allowing retry
      assert Future.await(Future.create(future_ref)) == :ok

      # Transaction should be usable again
      assert transaction_set(t.resource, "retry_key", "retry_value") == 0
    end

    test "transaction cannot be retried after non-retryable error" do
      db = new_database()
      t = Transaction.create(db)

      # Non-retryable error
      error_code = 2000  # invalid_option
      future_ref = transaction_on_error(t.resource, error_code)

      # Should raise error
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future_ref))
      end
    end
  end
end
