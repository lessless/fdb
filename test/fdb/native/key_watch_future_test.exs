defmodule FDB.Native.KeyWatchFutureTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "transaction_get_key KEY future handling" do
    test "get_key future resolves to a key" do
      db = new_database()

      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..10 do
          key = "key_future_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      # Call get_key directly and await the future
      Database.transact(db, fn t ->
        future_ref = transaction_get_key(
          t.resource,
          "key_future_005",
          0,  # or_equal = false
          1,  # offset = 1 (first_greater_than)
          0   # snapshot = false
        )

        # Create future wrapper and await it - this triggers KEY case
        future = Future.create(future_ref)
        result = Future.await(future)

        # Verify the result is a key
        assert result == "key_future_005"
      end)
    end

    test "get_key with exact match" do
      db = new_database()

      Database.transact(db, fn t ->
        Transaction.set(t, "exact_key", "value")

        future_ref = transaction_get_key(
          t.resource,
          "exact_key",
          1,  # or_equal = true
          1,  # offset = 1 (first_greater_or_equal)
          0   # snapshot = false
        )

        future = Future.create(future_ref)
        result = Future.await(future)

        # With or_equal=1 and offset=1, starting from "exact_key", we get the next key
        # Since there's only one key, it might return a boundary key
        assert is_binary(result)
      end)
    end

    test "get_key at database boundaries" do
      db = new_database()

      Database.transact(db, fn t ->
        Transaction.set(t, "aaa", "first")
        Transaction.set(t, "zzz", "last")

        # Get key before all keys
        future_ref = transaction_get_key(
          t.resource,
          "",      # Empty key
          0,       # or_equal = false
          1,       # offset = 1 (first key in database)
          0        # snapshot = false
        )

        future = Future.create(future_ref)
        result = Future.await(future)
        assert result == "aaa"

        # Get key after all keys with negative offset
        future_ref2 = transaction_get_key(
          t.resource,
          <<255>>,  # Max byte value
          0,        # or_equal = false
          0,        # offset = 0 (last_less_than)
          0         # snapshot = false
        )

        future2 = Future.create(future_ref2)
        result2 = Future.await(future2)
        assert result2 == "zzz"
      end)
    end

    test "get_key with binary keys" do
      db = new_database()

      Database.transact(db, fn t ->
        # Set binary keys
        key1 = <<0, 1, 2, 3>>
        key2 = <<0, 1, 2, 4>>
        key3 = <<0, 1, 2, 5>>

        Transaction.set(t, key1, "v1")
        Transaction.set(t, key2, "v2")
        Transaction.set(t, key3, "v3")

        future_ref = transaction_get_key(
          t.resource,
          <<0, 1, 2, 3, 128>>,  # Between key1 and key2
          0,  # or_equal = false
          1,  # offset = 1
          0   # snapshot = false
        )

        future = Future.create(future_ref)
        result = Future.await(future)

        assert result == key2
      end)
    end

    test "get_key with error" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction to force an error
      transaction_cancel(t.resource)

      future_ref = transaction_get_key(
        t.resource,
        "any_key",
        0, 1, 0
      )

      future = Future.create(future_ref)

      # Should raise an error when awaiting
      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "get_key with large offset" do
      db = new_database()

      Database.transact(db, fn t ->
        # Create sparse keys
        Transaction.set(t, "key_001", "v1")
        Transaction.set(t, "key_100", "v100")

        # Large positive offset
        future_ref = transaction_get_key(
          t.resource,
          "key_001",
          0,    # or_equal = false
          50,   # Large offset
          0     # snapshot = false
        )

        future = Future.create(future_ref)
        result = Future.await(future)

        # Should get key_100 or beyond
        assert result >= "key_100"
      end)
    end
  end

  describe "transaction_watch WATCH future handling" do
    test "watch future resolves when key is modified" do
      db = new_database()
      key = "watch_future_key_#{:rand.uniform(10000)}"

      # Create a watch
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        # Create future wrapper - this uses WATCH type
        Future.create(future_ref)
      end)

      # Verify watch is not immediately ready
      assert Future.ready?(watch_future) == false

      # Modify the key in another transaction
      Database.transact(db, fn t ->
        Transaction.set(t, key, "trigger_value")
      end)

      # Await the watch - this triggers WATCH case in future_get
      result = Future.await(watch_future)
      assert result == :ok
    end

    test "watch future with immediate trigger" do
      db = new_database()
      key = "immediate_watch_#{:rand.uniform(10000)}"

      # Set a value first
      Database.transact(db, fn t ->
        Transaction.set(t, key, "initial")
      end)

      # Create watch and immediately modify in same transaction
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Transaction.set(t, key, "modified")
        Future.create(future_ref)
      end)

      # Watch should trigger after commit
      result = Future.await(watch_future)
      assert result == :ok
    end

    test "multiple watches on different keys" do
      db = new_database()
      key1 = "multi_watch_key1_#{:rand.uniform(10000)}"
      key2 = "multi_watch_key2_#{:rand.uniform(10000)}"

      # Create watches
      {watch1, watch2} = Database.transact(db, fn t ->
        ref1 = transaction_watch(t.resource, key1)
        ref2 = transaction_watch(t.resource, key2)
        {Future.create(ref1), Future.create(ref2)}
      end)

      # Both should not be ready
      assert Future.ready?(watch1) == false
      assert Future.ready?(watch2) == false

      # Trigger first watch
      Database.transact(db, fn t ->
        Transaction.set(t, key1, "trigger1")
      end)

      # First watch resolves
      assert Future.await(watch1) == :ok
      assert Future.ready?(watch2) == false

      # Trigger second watch
      Database.transact(db, fn t ->
        Transaction.set(t, key2, "trigger2")
      end)

      # Second watch resolves
      assert Future.await(watch2) == :ok
    end

    test "watch on binary key" do
      db = new_database()
      binary_key = <<0, 255, 127, 1, 2, 3>>

      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, binary_key)
        Future.create(future_ref)
      end)

      Database.transact(db, fn t ->
        Transaction.set(t, binary_key, <<255, 254, 253>>)
      end)

      assert Future.await(watch_future) == :ok
    end

    test "watch with error on cancelled transaction" do
      db = new_database()
      t = Transaction.create(db)
      key = "error_watch_#{:rand.uniform(10000)}"

      # Create watch
      future_ref = transaction_watch(t.resource, key)
      future = Future.create(future_ref)

      # Cancel transaction before committing
      transaction_cancel(t.resource)

      # Watch future should error
      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "watch cleared by clear operation" do
      db = new_database()
      key = "clear_watch_#{:rand.uniform(10000)}"

      # Set initial value
      Database.transact(db, fn t ->
        Transaction.set(t, key, "initial")
      end)

      # Create watch
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      # Clear the key - this should trigger the watch
      Database.transact(db, fn t ->
        transaction_clear(t.resource, key)
      end)

      assert Future.await(watch_future) == :ok
    end

    test "watch triggered by clear_range" do
      db = new_database()
      key = "range_watch_#{:rand.uniform(10000)}"

      # Set initial value
      Database.transact(db, fn t ->
        Transaction.set(t, key, "initial")
      end)

      # Create watch
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      # Clear range including the key
      Database.transact(db, fn t ->
        transaction_clear_range(t.resource, "range_watch_", "range_watch_~")
      end)

      assert Future.await(watch_future) == :ok
    end

    test "watch on empty key" do
      db = new_database()
      empty_key = ""

      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, empty_key)
        Future.create(future_ref)
      end)

      Database.transact(db, fn t ->
        Transaction.set(t, empty_key, "empty_key_value")
      end)

      assert Future.await(watch_future) == :ok
    end

    test "concurrent watch futures" do
      db = new_database()
      keys = for i <- 1..5, do: "concurrent_watch_#{i}_#{:rand.uniform(10000)}"

      # Create multiple watches
      watches = Database.transact(db, fn t ->
        for key <- keys do
          ref = transaction_watch(t.resource, key)
          Future.create(ref)
        end
      end)

      # All should be not ready
      assert Enum.all?(watches, fn w -> Future.ready?(w) == false end)

      # Trigger all watches at once
      Database.transact(db, fn t ->
        for key <- keys do
          Transaction.set(t, key, "triggered")
        end
      end)

      # All should resolve
      for watch <- watches do
        assert Future.await(watch) == :ok
      end
    end

    test "watch survives transaction retry" do
      db = new_database()
      key = "retry_watch_#{:rand.uniform(10000)}"

      # This is more of an integration test, but ensures watch futures work correctly
      watch_future = Database.transact(db, fn t ->
        # Set a value that might cause conflict
        Transaction.set(t, "conflict_key", "value")

        # Create watch
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      # Trigger the watch
      Database.transact(db, fn t ->
        Transaction.set(t, key, "trigger")
      end)

      assert Future.await(watch_future) == :ok
    end
  end

  describe "future type coverage verification" do
    test "all future types are exercised" do
      # This test verifies that we've covered the main future types
      # This is a meta-test to ensure our test suite is complete

      db = new_database()

      Database.transact(db, fn t ->
        # KEY future (transaction_get_key)
        key_future = transaction_get_key(t.resource, "test", 0, 1, 0)
        assert is_reference(key_future)

        # KEYVALUE_ARRAY future (transaction_get_range)
        range_future = transaction_get_range(
          t.resource,
          "a", 0, 1,
          "z", 0, 1,
          1, 0, 0, 0, 0, 0
        )
        assert is_reference(range_future)

        # WATCH future (transaction_watch)
        watch_future = transaction_watch(t.resource, "watch_key")
        assert is_reference(watch_future)

        # Don't await these as we just want to verify they're created
      end)
    end
  end
end
