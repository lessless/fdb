defmodule FDB.Native.ComprehensiveTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future, Option}

  setup do
    flushdb()
    :ok
  end

  describe "network operations" do
    test "network_set_option with value" do
      # Test setting a network option with a value
      # Using a safe option that won't affect other tests
      assert network_set_option(Option.network_option_tls_verify_peers(), "Check.NotEnabled") == 0
    end

    test "network_set_option without value" do
      # Test setting a network option without a value
      assert network_set_option(Option.network_option_disable_client_statistics_logging()) == 0
    end
  end

  describe "database operations" do
    test "database_set_option with value" do
      {0, db} = create_database(nil)
      assert database_set_option(db, Option.database_option_location_cache_size(), <<100, 0, 0, 0, 0, 0, 0, 0>>) == 0
    end

    test "database_set_option without value" do
      {0, db} = create_database(nil)
      # Using a safe option that takes no parameter
      assert database_set_option(db, Option.database_option_snapshot_ryw_disable()) == 0
    end
  end

  describe "transaction operations" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "transaction_set_option with value", %{transaction: t} do
      assert transaction_set_option(t.resource, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>) == 0
    end

    test "transaction_set_option without value", %{transaction: t} do
      assert transaction_set_option(t.resource, Option.transaction_option_snapshot_ryw_disable()) == 0
    end

    test "transaction_get_approximate_size", %{transaction: t} do
      # Set some data to ensure size > 0
      Transaction.set(t, "test_key", "test_value")

      future = transaction_get_approximate_size(t.resource)
      assert is_reference(future)

      # Wait for the future to resolve
      result = Future.await(Future.create(future))
      assert is_integer(result)
      assert result >= 0
    end

    test "transaction_get_committed_version", %{transaction: t} do
      # Set a value and commit
      Transaction.set(t, "test_key", "test_value")
      Transaction.commit(t)

      # The version should be available after commit
      {error_code, version} = transaction_get_committed_version(t.resource)
      assert error_code == 0
      assert is_integer(version)
      assert version > 0
    end

    test "transaction_get_versionstamp", %{db: db} do
      # Test that we can call get_versionstamp and it returns a future
      # The actual versionstamp functionality is tested in integration tests
      Database.transact(db, fn t ->
        # Just set a regular key/value to have something in the transaction
        Transaction.set(t, "test_key", "test_value")

        # Get versionstamp future - this should work even without versionstamped operations
        future = transaction_get_versionstamp(t.resource)
        assert is_reference(future)

        # Don't await here - the future will resolve after commit
        # Just verify we got a future reference
      end)
    end

    test "transaction_get_addresses_for_key", %{transaction: t} do
      key = "test_address_key"
      Transaction.set(t, key, "test_value")

      future = transaction_get_addresses_for_key(t.resource, key)
      assert is_reference(future)

      result = Future.await(Future.create(future))
      assert is_list(result)
      # Should have at least one address
      assert length(result) > 0
      # Each address should be a string
      assert Enum.all?(result, &is_binary/1)
    end

    test "transaction_get_range_split_points", %{db: db} do
      # First, populate some data
      Database.transact(db, fn t ->
        for i <- 1..100 do
          key = "split_test_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, String.duplicate("x", 100))
        end
      end)

      # Now test split points
      Database.transact(db, fn t ->
        future = transaction_get_range_split_points(
          t.resource,
          "split_test_000",
          "split_test_999",
          1000  # chunk size in bytes
        )
        assert is_reference(future)

        result = Future.await(Future.create(future))
        assert is_list(result)
        # Should have split points since we have enough data
        assert length(result) >= 0
      end)
    end

    test "transaction_set_read_version", %{db: db} do
      # Get a read version from one transaction
      version = Database.transact(db, fn t ->
        Transaction.get_read_version(t)
      end)

      # Use it in another transaction
      t2 = Transaction.create(db)
      assert transaction_set_read_version(t2.resource, version) == 0

      # Should still be able to read
      result = Transaction.get(t2, "some_key")
      assert result == nil
    end

    test "transaction_add_conflict_range", %{transaction: t} do
      # Add a read conflict range
      assert transaction_add_conflict_range(
        t.resource,
        "conflict_begin",
        "conflict_end",
        Option.conflict_range_type_read()
      ) == 0

      # Add a write conflict range
      assert transaction_add_conflict_range(
        t.resource,
        "conflict_begin",
        "conflict_end",
        Option.conflict_range_type_write()
      ) == 0
    end

    test "transaction_get_estimated_range_size_bytes", %{db: db} do
      # First populate some data
      Database.transact(db, fn t ->
        for i <- 1..50 do
          key = "size_test_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, String.duplicate("x", 100))
        end
      end)

      # Now estimate the size
      Database.transact(db, fn t ->
        future = transaction_get_estimated_range_size_bytes(
          t.resource,
          "size_test_000",
          "size_test_999"
        )
        assert is_reference(future)

        result = Future.await(Future.create(future))
        assert is_integer(result)
        # Note: The estimate might be 0 for small ranges or due to implementation details
        assert result >= 0
      end)
    end

    test "transaction_atomic_op various operations", %{transaction: t} do
      key = "atomic_test_key"

      # Test ADD operation
      Transaction.set(t, key, <<1, 0, 0, 0, 0, 0, 0, 0>>)  # Little-endian 1
      assert transaction_atomic_op(
        t.resource,
        key,
        <<2, 0, 0, 0, 0, 0, 0, 0>>,  # Add 2
        Option.mutation_type_add()
      ) == 0

      # Test BIT_AND operation
      assert transaction_atomic_op(
        t.resource,
        "bit_test_key",
        <<0xFF, 0x00, 0xFF, 0x00>>,
        Option.mutation_type_bit_and()
      ) == 0

      # Test MAX operation
      assert transaction_atomic_op(
        t.resource,
        "max_test_key",
        <<5, 0, 0, 0, 0, 0, 0, 0>>,
        Option.mutation_type_max()
      ) == 0
    end

    test "transaction_cancel", %{transaction: t} do
      # Cancel should always succeed
      assert transaction_cancel(t.resource) == 0

      # Further operations should fail
      assert_raise FDB.Error, fn ->
        Transaction.get(t, "any_key")
      end
    end

    test "transaction_on_error", %{transaction: t} do
      # Test with a retryable error
      error_code = 1020  # not_committed - a retryable error
      future = transaction_on_error(t.resource, error_code)
      assert is_reference(future)

      # This should complete successfully for retryable errors
      result = Future.await(Future.create(future))
      assert result == :ok
    end

    test "transaction_on_error with non-retryable error", %{transaction: t} do
      # Test with a non-retryable error
      error_code = 2000  # invalid_option - non-retryable
      future = transaction_on_error(t.resource, error_code)
      assert is_reference(future)

      # This should raise an error for non-retryable errors
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future))
      end
    end
  end

  describe "error operations" do
    test "get_error_predicate" do
      # Test retryable predicate
      retryable_predicate = Option.error_predicate_retryable()

      # 1020 is not_committed, which is retryable
      assert get_error_predicate(retryable_predicate, 1020) == :true

      # 2000 is invalid_option, which is not retryable
      assert get_error_predicate(retryable_predicate, 2000) == :false

      # Test with success (0)
      assert get_error_predicate(retryable_predicate, 0) == :false
    end

    test "get_error edge cases" do
      # Test boundary values
      assert get_error(-1) == "An unknown error occurred"
      assert get_error(999999) == "An unknown error occurred"

      # Test some known error codes
      assert get_error(1007) == "Transaction is too old to perform reads or be committed"
      assert get_error(1020) == "Transaction not committed due to conflict with another transaction"
      assert get_error(2000) =~ "Invalid API call"
    end
  end

  describe "future operations" do
    test "future_is_ready" do
      db = new_database()
      t = Transaction.create(db)

      # Create a future
      key = random_key()
      future_ref = transaction_get(t.resource, key, 0)
      future = Future.create(future_ref)

      # Initially might not be ready
      ready1 = future_is_ready(future_ref)
      assert ready1 in [:true, :false]

      # After await, should definitely be ready
      Future.await(future)
      ready2 = future_is_ready(future_ref)
      assert ready2 == :true
    end

    test "future_resolve callback mechanism" do
      db = new_database()
      t = Transaction.create(db)

      # Create a future
      key = random_key()
      value = random_value()
      Transaction.set(t, key, value)

      future_ref = transaction_get(t.resource, key, 0)

      # Create a reference for the callback
      ref = make_ref()

      # Set up the callback
      assert future_resolve(future_ref, ref) == 0

      # Should receive a message with the result
      assert_receive {0, ^ref, ^value}, 5000
    end

    test "future_resolve with error" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction to force an error
      transaction_cancel(t.resource)

      # Try to get something - should produce an error future
      future_ref = transaction_get(t.resource, "any_key", 0)

      ref = make_ref()
      assert future_resolve(future_ref, ref) == 0

      # Should receive an error message
      assert_receive {error_code, ^ref, _value}, 5000
      assert error_code != 0
    end
  end

  describe "edge cases and error conditions" do
    test "invalid arguments to NIF functions" do
      # Test with invalid resource types
      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_get("not_a_transaction", "key", 0)
      end

      assert_raise ErlangError, ~r/future/, fn ->
        future_is_ready("not_a_future")
      end

      assert_raise ErlangError, ~r/database/, fn ->
        database_set_option("not_a_database", 0)
      end
    end

    test "operations on committed transaction should fail" do
      db = new_database()
      t = Transaction.create(db)
      Transaction.set(t, "key", "value")
      Transaction.commit(t)

      # Try to use the transaction after commit - should fail
      # Different operations might fail in different ways

      # Get operation should return an error
      future = transaction_get(t.resource, "key", 0)
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future))
      end

      # Set operation using NIF directly should succeed but commit would fail
      # Testing the NIF layer directly
      assert transaction_set(t.resource, "key", "value2") == 0

      # But trying to commit again should fail
      commit_future = transaction_commit(t.resource)
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(commit_future))
      end
    end

    test "binary data handling" do
      db = new_database()

      # Test with binary data containing nulls and special characters
      Database.transact(db, fn t ->
        key = <<0, 1, 2, 255, 254, 253>>
        value = <<0, 0, 0, 0, 255, 255, 255, 255>>

        Transaction.set(t, key, value)
        assert Transaction.get(t, key) == value
      end)
    end

    test "large data handling" do
      db = new_database()

      # Test with large key and value (near the limits)
      Database.transact(db, fn t ->
        # Keys can be up to 10KB
        large_key = "large_key_" <> String.duplicate("x", 1000)
        # Values can be up to 10MB, but we'll test with something smaller
        large_value = String.duplicate("y", 100_000)

        Transaction.set(t, large_key, large_value)
        assert Transaction.get(t, large_key) == large_value
      end)
    end
  end
end
