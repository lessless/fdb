defmodule FDB.Native.UncoveredTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future, KeySelector}

  setup do
    flushdb()
    :ok
  end

  describe "transaction_clear" do
    test "clear a key using NIF directly" do
      db = new_database()

      Database.transact(db, fn t ->
        # Set a key first
        Transaction.set(t, "clear_test_key", "value_to_clear")
        assert Transaction.get(t, "clear_test_key") == "value_to_clear"

        # Clear using NIF directly
        assert transaction_clear(t.resource, "clear_test_key") == 0

        # Verify it's cleared
        assert Transaction.get(t, "clear_test_key") == nil
      end)
    end

    test "clear non-existent key" do
      db = new_database()

      Database.transact(db, fn t ->
        # Clear a key that doesn't exist - should succeed
        assert transaction_clear(t.resource, "non_existent_key") == 0
      end)
    end

    test "clear with empty key" do
      db = new_database()

      Database.transact(db, fn t ->
        # Empty key is valid in FDB
        Transaction.set(t, "", "empty_key_value")
        assert transaction_clear(t.resource, "") == 0
        assert Transaction.get(t, "") == nil
      end)
    end

    test "clear with binary key containing special characters" do
      db = new_database()

      Database.transact(db, fn t ->
        key = <<0, 255, 127, 1, 2, 3>>
        Transaction.set(t, key, "binary_value")
        assert transaction_clear(t.resource, key) == 0
        assert Transaction.get(t, key) == nil
      end)
    end

    test "clear through high-level API" do
      db = new_database()

      Database.transact(db, fn t ->
        Transaction.set(t, "high_level_clear", "value")
        assert Transaction.clear(t, "high_level_clear") == :ok
        assert Transaction.get(t, "high_level_clear") == nil
      end)
    end
  end

  describe "transaction_watch" do
    test "watch a key using NIF directly" do
      db = new_database()
      key = "watch_test_key_#{:rand.uniform(1000)}"

      # Create a watch
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        assert is_reference(future_ref)
        Future.create(future_ref)
      end)

      # The watch should not be immediately ready (unless the key was already modified)
      assert Future.ready?(watch_future) == false

      # Modify the key in another transaction
      Database.transact(db, fn t ->
        Transaction.set(t, key, "new_value")
      end)

      # The watch should now resolve
      assert Future.await(watch_future) == :ok
    end

    test "watch multiple keys" do
      db = new_database()
      key1 = "multi_watch_1_#{:rand.uniform(1000)}"
      key2 = "multi_watch_2_#{:rand.uniform(1000)}"

      # Create watches for multiple keys
      {watch1, watch2} = Database.transact(db, fn t ->
        future1 = transaction_watch(t.resource, key1)
        future2 = transaction_watch(t.resource, key2)
        {Future.create(future1), Future.create(future2)}
      end)

      # Modify only the first key
      Database.transact(db, fn t ->
        Transaction.set(t, key1, "value1")
      end)

      # First watch should resolve, second should not
      assert Future.await(watch1) == :ok
      assert Future.ready?(watch2) == false

      # Modify second key
      Database.transact(db, fn t ->
        Transaction.set(t, key2, "value2")
      end)

      # Now second watch should resolve
      assert Future.await(watch2) == :ok
    end

    test "watch with empty key" do
      db = new_database()

      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, "")
        Future.create(future_ref)
      end)

      # Modify the empty key
      Database.transact(db, fn t ->
        Transaction.set(t, "", "empty_key_value")
      end)

      assert Future.await(watch_future) == :ok
    end

    test "watch through high-level API" do
      db = new_database()
      key = "high_level_watch_#{:rand.uniform(1000)}"

      watch_future = Database.transact(db, fn t ->
        Transaction.watch_q(t, key)
      end)

      Database.transact(db, fn t ->
        Transaction.set(t, key, "trigger_watch")
      end)

      assert Future.await(watch_future) == :ok
    end
  end

  describe "transaction_get_key" do
    setup do
      db = new_database()

      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..10 do
          key = "get_key_test_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      {:ok, db: db}
    end

    test "get_key with first_greater_than", %{db: db} do
      Database.transact(db, fn t ->
        # Get first key greater than "get_key_test_005"
        future = transaction_get_key(
          t.resource,
          "get_key_test_005",
          0,  # or_equal = false
          1,  # offset = 1 (first_greater_than)
          0   # snapshot = false
        )

        result = Future.await(Future.create(future))
        # Note: with or_equal=0 and offset=1, this returns the key at position 5
        assert result == "get_key_test_005"
      end)
    end

    test "get_key with first_greater_or_equal", %{db: db} do
      Database.transact(db, fn t ->
        # Get first key greater than or equal to "get_key_test_005"
        future = transaction_get_key(
          t.resource,
          "get_key_test_005",
          1,  # or_equal = true
          1,  # offset = 1 (first_greater_or_equal)
          0   # snapshot = false
        )

        result = Future.await(Future.create(future))
        # Note: with or_equal=1 and offset=1, this moves one position forward
        assert result == "get_key_test_006"
      end)
    end

    test "get_key with last_less_than", %{db: db} do
      Database.transact(db, fn t ->
        # Get last key less than "get_key_test_005"
        future = transaction_get_key(
          t.resource,
          "get_key_test_005",
          0,  # or_equal = false
          0,  # offset = 0 (last_less_than)
          0   # snapshot = false
        )

        result = Future.await(Future.create(future))
        assert result == "get_key_test_004"
      end)
    end

    test "get_key with last_less_or_equal", %{db: db} do
      Database.transact(db, fn t ->
        # Get last key less than or equal to "get_key_test_005"
        future = transaction_get_key(
          t.resource,
          "get_key_test_005",
          1,  # or_equal = true
          0,  # offset = 0 (last_less_or_equal)
          0   # snapshot = false
        )

        result = Future.await(Future.create(future))
        assert result == "get_key_test_005"
      end)
    end

    test "get_key with offset", %{db: db} do
      Database.transact(db, fn t ->
        # Get key with offset
        future = transaction_get_key(
          t.resource,
          "get_key_test_005",
          0,  # or_equal = false
          3,  # offset = 3 (skip 2 keys after first_greater_than)
          0   # snapshot = false
        )

        result = Future.await(Future.create(future))
        # With or_equal=0 and offset=3, starting from position 5, we get position 7
        assert result == "get_key_test_007"
      end)
    end

    test "get_key with snapshot", %{db: db} do
      Database.transact(db, fn t ->
        # Get key using snapshot read
        future = transaction_get_key(
          t.resource,
          "get_key_test_005",
          0,  # or_equal = false
          1,  # offset = 1
          1   # snapshot = true
        )

        result = Future.await(Future.create(future))
        assert result == "get_key_test_005"
      end)
    end

    test "get_key at boundary", %{db: db} do
      Database.transact(db, fn t ->
        # Try to get key before all keys
        future = transaction_get_key(
          t.resource,
          "get_key_test_000",  # Before first key
          0,  # or_equal = false
          1,  # offset = 1
          0   # snapshot = false
        )

        result = Future.await(Future.create(future))
        assert result == "get_key_test_001"
      end)
    end

    test "get_key through high-level API", %{db: db} do
      result = Database.transact(db, fn t ->
        key_selector = KeySelector.first_greater_than("get_key_test_005")
        Transaction.get_key(t, key_selector)
      end)

      assert result == "get_key_test_006"
    end
  end

  describe "transaction_get_range" do
    setup do
      db = new_database()

      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..20 do
          key = "range_test_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      {:ok, db: db}
    end

    test "get_range basic usage", %{db: db} do
      Database.transact(db, fn t ->
        future = transaction_get_range(
          t.resource,
          "range_test_001",    # begin_key
          1,                   # begin_or_equal
          1,                   # begin_offset (first_greater_than)
          "range_test_010",    # end_key
          1,                   # end_or_equal
          1,                   # end_offset (first_greater_than)
          100,                 # limit (required for EXACT mode)
          0,                   # target_bytes (0 = no target)
          0,                   # streaming_mode (0 = EXACT)
          0,                   # iteration
          0,                   # snapshot
          0                    # reverse
        )

        result = Future.await(Future.create(future))
        {more, kvs} = result

        # Should have keys 002 through 010
        assert length(kvs) == 9
        assert more == 0  # No more results

        # Verify first and last
        [{first_key, _first_val} | _] = kvs
        {last_key, _last_val} = List.last(kvs)
        assert first_key == "range_test_002"
        assert last_key == "range_test_010"
      end)
    end

    test "get_range with limit", %{db: db} do
      Database.transact(db, fn t ->
        future = transaction_get_range(
          t.resource,
          "range_test_001", 0, 1,
          "range_test_020", 0, 1,
          5,    # limit to 5 results
          0, 0, 0, 0, 0
        )

        result = Future.await(Future.create(future))
        {more, kvs} = result

        assert length(kvs) == 5
        assert more == 1  # More results available
      end)
    end

    test "get_range in reverse", %{db: db} do
      Database.transact(db, fn t ->
        future = transaction_get_range(
          t.resource,
          "range_test_005", 1, 1,
          "range_test_010", 1, 1,
          100, 0, 0, 0, 0,  # Added limit for EXACT mode
          1     # reverse = true
        )

        result = Future.await(Future.create(future))
        {_more, kvs} = result

        # Results should be in reverse order
        keys = Enum.map(kvs, fn {k, _v} -> k end)
        assert keys == ["range_test_010", "range_test_009", "range_test_008",
                       "range_test_007", "range_test_006"]
      end)
    end

    test "get_range with target_bytes", %{db: db} do
      Database.transact(db, fn t ->
        future = transaction_get_range(
          t.resource,
          "range_test_001", 0, 1,
          "range_test_020", 0, 1,
          0,
          100,  # target_bytes - stop after approximately 100 bytes
          0, 0, 0, 0
        )

        result = Future.await(Future.create(future))
        {_more, kvs} = result

        # Should return some results but not all
        assert length(kvs) > 0
        assert length(kvs) < 19  # Less than total possible

        # Calculate approximate size
        total_size = Enum.reduce(kvs, 0, fn {k, v}, acc ->
          acc + byte_size(k) + byte_size(v)
        end)

        # Should be reasonably close to target (allowing for FDB's chunking)
        assert total_size >= 50  # At least some data
      end)
    end

    test "get_range with streaming modes", %{db: db} do
      Database.transact(db, fn t ->
        # Test different streaming modes
        streaming_modes = [
          {0, "EXACT", 100},  # EXACT needs a limit
          {1, "SMALL", 0},
          {2, "MEDIUM", 0},
          {3, "LARGE", 0},
          {4, "SERIAL", 0}
        ]

        for {mode, name, limit} <- streaming_modes do
          future = transaction_get_range(
            t.resource,
            "range_test_001", 0, 1,
            "range_test_010", 0, 1,
            limit, 0,
            mode,  # streaming_mode
            0, 0, 0
          )

          result = Future.await(Future.create(future))
          {_more, kvs} = result

          # All modes should work, though they may return different amounts
          assert is_list(kvs), "Streaming mode #{name} should return a list"
          assert length(kvs) > 0, "Streaming mode #{name} should return results"
        end
      end)
    end

    test "get_range with empty range", %{db: db} do
      Database.transact(db, fn t ->
        future = transaction_get_range(
          t.resource,
          "range_test_999", 0, 1,  # Start after all keys
          "range_test_zzz", 0, 1,  # End even further
          100, 0, 0, 0, 0, 0  # Added limit for EXACT mode
        )

        result = Future.await(Future.create(future))
        {more, kvs} = result

        assert kvs == []
        assert more == 0
      end)
    end

    test "get_range with snapshot", %{db: db} do
      Database.transact(db, fn t ->
        future = transaction_get_range(
          t.resource,
          "range_test_001", 0, 1,
          "range_test_005", 0, 1,
          100, 0, 0, 0,  # Added limit for EXACT mode
          1,    # snapshot = true
          0
        )

        result = Future.await(Future.create(future))
        {_more, kvs} = result

        assert length(kvs) == 4
      end)
    end

    test "get_range through high-level API", %{db: db} do
      results = Database.transact(db, fn t ->
        # Using KeySelectorRange instead of KeyRange
        range = FDB.KeySelectorRange.starts_with("range_test_00")
        Transaction.get_range_stream(t, range)
        |> Enum.take(4)  # Take first 4 results
      end)

      assert length(results) == 4
      [{key, _val} | _] = results
      assert key >= "range_test_001"
    end

    test "get_range with various key selector combinations", %{db: db} do
      Database.transact(db, fn t ->
        # last_less_or_equal to first_greater_than
        future = transaction_get_range(
          t.resource,
          "range_test_005", 1, 0,  # last_less_or_equal
          "range_test_010", 1, 1,  # first_greater_than
          100, 0, 0, 0, 0, 0  # Added limit for EXACT mode
        )

        result = Future.await(Future.create(future))
        {_more, kvs} = result

        keys = Enum.map(kvs, fn {k, _v} -> k end)
        assert keys == ["range_test_005", "range_test_006", "range_test_007",
                       "range_test_008", "range_test_009", "range_test_010"]
      end)
    end
  end

  describe "error conditions and edge cases" do
    test "operations on invalid transaction resource" do
      # These should raise ErlangError about invalid resource type
      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_clear("not_a_transaction", "key")
      end

      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_watch("not_a_transaction", "key")
      end

      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_get_key("not_a_transaction", "key", 0, 1, 0)
      end

      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_get_range(
          "not_a_transaction",
          "begin", 0, 1,
          "end", 0, 1,
          0, 0, 0, 0, 0, 0
        )
      end
    end

    test "operations with invalid argument types" do
      db = new_database()
      t = Transaction.create(db)

      # Invalid key type (not binary)
      assert_raise ErlangError, ~r/key/, fn ->
        transaction_clear(t.resource, :not_a_binary)
      end

      assert_raise ErlangError, ~r/key/, fn ->
        transaction_watch(t.resource, 123)
      end

      # Invalid integer parameters
      assert_raise ErlangError, ~r/or_equal|offset|snapshot/, fn ->
        transaction_get_key(t.resource, "key", "not_int", 1, 0)
      end

      assert_raise ErlangError, ~r/limit|target_bytes|streaming_mode/, fn ->
        transaction_get_range(
          t.resource,
          "begin", 0, 1,
          "end", 0, 1,
          "not_int", 0, 0, 0, 0, 0
        )
      end
    end

    test "clear and watch on committed transaction" do
      db = new_database()
      t = Transaction.create(db)
      Transaction.set(t, "key", "value")
      Transaction.commit(t)

      # Operations should complete but transaction is already committed
      assert transaction_clear(t.resource, "key") == 0

      # Watch will create a future but it will error when resolved
      future_ref = transaction_watch(t.resource, "key")
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future_ref))
      end
    end

    test "get_key and get_range on cancelled transaction" do
      db = new_database()
      t = Transaction.create(db)
      transaction_cancel(t.resource)

      # These will return futures that error when awaited
      key_future = transaction_get_key(t.resource, "key", 0, 1, 0)
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(key_future))
      end

      range_future = transaction_get_range(
        t.resource,
        "begin", 0, 1,
        "end", 0, 1,
        0, 0, 0, 0, 0, 0
      )
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(range_future))
      end
    end

    test "large key handling" do
      db = new_database()

      Database.transact(db, fn t ->
        # Keys can be up to 10KB
        large_key = String.duplicate("x", 5000)
        Transaction.set(t, large_key, "value")

        # Clear large key
        assert transaction_clear(t.resource, large_key) == 0
        assert Transaction.get(t, large_key) == nil
      end)
    end

    test "boundary conditions for get_range" do
      db = new_database()

      Database.transact(db, fn t ->
        # Empty database range
        future = transaction_get_range(
          t.resource,
          "", 0, 1,      # From beginning
          <<0xFF>>, 0, 1, # To end
          1, 0, 0, 0, 0, 0  # Already has limit, keep as is
        )

        result = Future.await(Future.create(future))
        {_more, kvs} = result

        # Should work even if no keys exist
        assert is_list(kvs)
      end)
    end
  end
end
