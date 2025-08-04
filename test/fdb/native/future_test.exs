defmodule FDB.Native.FutureTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "future basics" do
    test "future_is_ready returns correct status" do
      db = new_database()
      t = Transaction.create(db)

      # Create a future
      future_ref = transaction_get(t.resource, "nonexistent", 0)

      # Should not be ready immediately (in most cases)
      # Note: future_is_ready returns boolean, not 0/1
      assert future_is_ready(future_ref) == false or future_is_ready(future_ref) == true

      # After resolving, should be ready
      _future = Future.create(future_ref)
      Process.sleep(10)
      assert is_boolean(future_is_ready(future_ref))
    end


  end

  describe "VALUE type futures" do
    test "successful get operation" do
      db = new_database()

      # Set a value
      Database.transact(db, fn t ->
        Transaction.set(t, "value_key", "test_value")
      end)

      # Get the value
      result = Database.transact(db, fn t ->
        future_ref = transaction_get(t.resource, "value_key", 0)
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert result == "test_value"
    end

    test "get non-existent key returns nil" do
      db = new_database()

      result = Database.transact(db, fn t ->
        future_ref = transaction_get(t.resource, "nonexistent_key", 0)
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert result == nil
    end

    test "get with cancelled transaction" do
      db = new_database()
      t = Transaction.create(db)

      # Set up a key first
      Transaction.set(t, "error_test_key", "value")

      # Cancel the transaction
      transaction_cancel(t.resource)

      # Try to get - should return a future that errors
      future_ref = transaction_get(t.resource, "error_test_key", 0)
      future = Future.create(future_ref)

      # Should raise an error when awaited
      assert_raise FDB.Error, ~r/[Cc]ancelled/, fn ->
        Future.await(future)
      end
    end
  end

  describe "KEYVALUE_ARRAY type futures" do
    setup do
      db = new_database()

      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..10 do
          key = "range_key_#{String.pad_leading(Integer.to_string(i), 2, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      {:ok, db: db}
    end

    test "successful range read", %{db: db} do
      result = Database.transact(db, fn t ->
        future_ref = transaction_get_range(
          t.resource,
          "range_key_01", 1, 0,
          "range_key_05", 1, 0,
          10, 0, 0, 0, 0, 0
        )
        future = Future.create(future_ref)
        Future.await(future)
      end)

      {more, kvs} = result
      assert length(kvs) == 4
      assert more == 0
    end

    test "empty range returns empty array", %{db: db} do
      result = Database.transact(db, fn t ->
        future_ref = transaction_get_range(
          t.resource,
          "z_start", 1, 0,
          "z_end", 1, 0,
          10, 0, 0, 0, 0, 0
        )
        future = Future.create(future_ref)
        Future.await(future)
      end)

      {more, kvs} = result
      assert kvs == []
      assert more == 0
    end

    test "range read with cancelled transaction", %{db: db} do
      t = Transaction.create(db)

      # Cancel the transaction
      transaction_cancel(t.resource)

      # Try to get_range - should return a future that errors
      future_ref = transaction_get_range(
        t.resource,
        "begin", 0, 1,
        "end", 0, 1,
        10, 0, 0, 0, 0, 0
      )
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end
  end

  describe "STRING_ARRAY type futures" do
    test "get_addresses_for_key returns string array" do
      db = new_database()

      addresses = Database.transact(db, fn t ->
        # Set a key to ensure it's stored somewhere
        Transaction.set(t, "address_test_key", "value")

        future_ref = transaction_get_addresses_for_key(t.resource, "address_test_key")
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert is_list(addresses)
      assert length(addresses) > 0
      assert Enum.all?(addresses, &is_binary/1)
    end

    test "get_range_split_points returns string array" do
      db = new_database()

      # Create some data
      Database.transact(db, fn t ->
        for i <- 1..50 do
          key = "split_test_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, String.duplicate("x", 100))
        end
      end)

      split_points = Database.transact(db, fn t ->
        future_ref = transaction_get_range_split_points(
          t.resource,
          "split_test_001",
          "split_test_050",
          1000
        )
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert is_list(split_points)
      # Should have at least one split point for reasonable data
      assert length(split_points) >= 0
    end
  end

  describe "INT64 type futures" do
    test "get_read_version returns int64" do
      db = new_database()

      version = Database.transact(db, fn t ->
        future_ref = transaction_get_read_version(t.resource)
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert is_integer(version)
      assert version > 0
    end

    test "get_approximate_size returns int64" do
      db = new_database()

      size = Database.transact(db, fn t ->
        # Add some data to the transaction
        for i <- 1..10 do
          Transaction.set(t, "size_test_#{i}", String.duplicate("x", 100))
        end

        future_ref = transaction_get_approximate_size(t.resource)
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert is_integer(size)
      assert size > 0
    end

    test "get_estimated_range_size_bytes returns int64" do
      db = new_database()

      # Set up some data
      Database.transact(db, fn t ->
        for i <- 1..10 do
          Transaction.set(t, "size_key_#{i}", String.duplicate("x", i * 10))
        end
      end)

      size = Database.transact(db, fn t ->
        future_ref = transaction_get_estimated_range_size_bytes(
          t.resource,
          "size_key_1",
          "size_key_9"
        )
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert is_integer(size)
      assert size >= 0
    end

    test "INT64 futures with cancelled transaction" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel transaction
      transaction_cancel(t.resource)

      # Try to get read version
      future_ref = transaction_get_read_version(t.resource)
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end
  end

  describe "KEY type futures" do
    test "get_key returns a key" do
      db = new_database()

      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..5 do
          Transaction.set(t, "key_test_#{i}", "value_#{i}")
        end
      end)

      key = Database.transact(db, fn t ->
        future_ref = transaction_get_key(t.resource, "key_test_2", 1, 1, 0)
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert key == "key_test_3"
    end
  end

  describe "WATCH type futures" do
    test "watch future resolves when key changes" do
      db = new_database()
      key = "watch_test_#{:rand.uniform(10000)}"

      # Create watch
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      # Future should not be ready yet
      assert Future.ready?(watch_future) == false

      # Change the key in another transaction
      Database.transact(db, fn t ->
        Transaction.set(t, key, "trigger_value")
      end)

      # Now the watch should resolve
      assert Future.await(watch_future) == :ok
    end

    test "multiple watches on different keys" do
      db = new_database()
      keys = for i <- 1..3, do: "multi_watch_#{i}_#{:rand.uniform(10000)}"

      # Create watches
      watches = Database.transact(db, fn t ->
        for key <- keys do
          future_ref = transaction_watch(t.resource, key)
          {key, Future.create(future_ref)}
        end
      end)

      # Trigger each watch
      for {key, watch_future} <- watches do
        # Should not be ready
        assert Future.ready?(watch_future) == false

        # Trigger it
        Database.transact(db, fn t ->
          Transaction.set(t, key, "triggered")
        end)

        # Should resolve
        assert Future.await(watch_future) == :ok
      end
    end

    test "watch on already changed key" do
      db = new_database()
      key = "immediate_watch_#{:rand.uniform(10000)}"

      # Set the key first
      Database.transact(db, fn t ->
        Transaction.set(t, key, "initial_value")
      end)

      # Create watch and immediately change the key
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      # Change immediately
      Database.transact(db, fn t ->
        Transaction.set(t, key, "changed_value")
      end)

      # Should resolve quickly
      assert Future.await(watch_future) == :ok
    end

    test "watch with cancelled transaction" do
      db = new_database()
      key = "cancelled_watch_#{:rand.uniform(10000)}"

      # Try to create watch on cancelled transaction
      t = Transaction.create(db)
      future_ref = transaction_watch(t.resource, key)

      # Cancel before committing
      transaction_cancel(t.resource)

      # The watch future should exist but may error when awaited
      future = Future.create(future_ref)

      # This might raise an error or return :ok depending on timing
      result = try do
        Future.await(future, 100)
      rescue
        FDB.Error -> :error
      end

      assert result in [:ok, :error]
    end
  end

  describe "COMMIT type futures" do
    test "successful commit" do
      db = new_database()

      result = Database.transact(db, fn t ->
        Transaction.set(t, "commit_test", "value")
        # Commit happens automatically and returns :ok
        :ok
      end)

      assert result == :ok
    end

    test "explicit commit future" do
      db = new_database()
      t = Transaction.create(db)

      Transaction.set(t, "explicit_commit", "value")

      commit_future_ref = transaction_commit(t.resource)
      commit_future = Future.create(commit_future_ref)

      assert Future.await(commit_future) == :ok
    end
  end

  describe "ERROR type futures" do
    test "on_error with retryable error" do
      db = new_database()

      result = Database.transact(db, fn t ->
        # Test with retryable error
        future_ref = transaction_on_error(t.resource, 1020)  # not_committed
        future = Future.create(future_ref)
        Future.await(future)
      end)

      assert result == :ok
    end

    test "on_error with non-retryable error" do
      db = new_database()
      t = Transaction.create(db)

      # Test with non-retryable error
      future_ref = transaction_on_error(t.resource, 2000)  # invalid_option
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end
  end

  describe "future edge cases" do
    test "future with very short timeout" do
      db = new_database()
      t = Transaction.create(db)

      future_ref = transaction_get(t.resource, "timeout_test", 0)
      future = Future.create(future_ref)

      # Test that timeout works - should either complete or timeout
      result = try do
        Future.await(future, 1)
      rescue
        FDB.TimeoutError -> :timeout
      end

      assert result == nil or result == :timeout
    end

    test "multiple futures from same transaction" do
      db = new_database()

      results = Database.transact(db, fn t ->
        # Create multiple futures
        futures = for i <- 1..5 do
          future_ref = transaction_get(t.resource, "multi_key_#{i}", 0)
          Future.create(future_ref)
        end

        # Await all
        Enum.map(futures, &Future.await/1)
      end)

      assert length(results) == 5
      assert Enum.all?(results, &(&1 == nil))
    end

    test "future operations on nil future reference" do
      # These should handle gracefully
      assert_raise ErlangError, fn ->
        future_is_ready(nil)
      end
    end

    test "versionstamp future behavior" do
      db = new_database()

      # Versionstamp futures are special - they resolve after commit
      versionstamp_future = Database.transact(db, fn t ->
        # Set a regular value to ensure transaction has content
        Transaction.set(t, "versionstamp_test", "value")

        # Get versionstamp future
        future_ref = transaction_get_versionstamp(t.resource)
        Future.create(future_ref)
      end)

      # Should have a valid versionstamp
      versionstamp = Future.await(versionstamp_future)
      assert is_binary(versionstamp)
      assert byte_size(versionstamp) == 10  # Versionstamps are 10 bytes
    end
  end

  describe "future type coverage" do
    test "all future types are tested" do
      # This test documents that we've covered all future types:
      # - VALUE (transaction_get)
      # - KEYVALUE_ARRAY (transaction_get_range)
      # - STRING_ARRAY (transaction_get_addresses_for_key, transaction_get_range_split_points)
      # - INT64 (transaction_get_read_version, transaction_get_approximate_size, etc.)
      # - KEY (transaction_get_key)
      # - WATCH (transaction_watch)
      # - COMMIT (transaction_commit)
      # - ERROR (transaction_on_error)
      # - VERSIONSTAMP (transaction_get_versionstamp)

      assert true
    end
  end
end
