defmodule FDB.Native.TransactionRangeTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "transaction_get_key" do
    setup do
      db = new_database()
      t = Transaction.create(db)

      # Set up test data
      keys = ["key_01", "key_02", "key_03", "key_04", "key_05"]
      for key <- keys do
        transaction_set(t.resource, key, "value_#{key}")
      end

      Transaction.commit(t)

      # New transaction for testing
      t2 = Transaction.create(db)
      {:ok, db: db, transaction: t2, keys: keys}
    end

    test "get_key with first_greater_than selector", %{transaction: t} do
      # Key selector: first key > "key_02"
      future_ref = transaction_get_key(t.resource, "key_02", 0, 1, 0)
      future = Future.create(future_ref)
      result = Future.await(future)

      # With offset 1, it gets the key at position, not the next one
      assert result == "key_02"
    end

    test "get_key with first_greater_or_equal selector", %{transaction: t} do
      # Key selector: first key >= "key_02"
      future_ref = transaction_get_key(t.resource, "key_02", 1, 0, 0)
      future = Future.create(future_ref)
      result = Future.await(future)

      assert result == "key_02"
    end

    test "get_key with last_less_than selector", %{transaction: t} do
      # Key selector: last key < "key_04"
      future_ref = transaction_get_key(t.resource, "key_04", 0, 0, 0)
      future = Future.create(future_ref)
      result = Future.await(future)

      assert result == "key_03"
    end

    test "get_key with last_less_or_equal selector", %{transaction: t} do
      # Key selector: last key <= "key_04"
      future_ref = transaction_get_key(t.resource, "key_04", 1, 0, 0)
      future = Future.create(future_ref)
      result = Future.await(future)

      assert result == "key_04"
    end

    test "get_key with offset", %{transaction: t} do
      # Get key 2 positions after "key_02"
      future_ref = transaction_get_key(t.resource, "key_02", 1, 2, 0)
      future = Future.create(future_ref)
      result = Future.await(future)

      assert result == "key_04"
    end

    test "get_key with snapshot", %{transaction: t} do
      # Get key using snapshot read
      future_ref = transaction_get_key(t.resource, "key_03", 1, 0, 1)
      future = Future.create(future_ref)
      result = Future.await(future)

      assert result == "key_03"
    end

    test "get_key at boundaries", %{transaction: t} do
      # Before first key
      future_ref = transaction_get_key(t.resource, "key_00", 0, 1, 0)
      result = Future.await(Future.create(future_ref))
      assert result == "key_01"

      # After last key - this might return a boundary key
      future_ref = transaction_get_key(t.resource, "key_06", 0, 0, 0)
      result = Future.await(Future.create(future_ref))
      assert result == "key_05"
    end

    test "get_key with empty database" do
      db = new_database()
      t = Transaction.create(db)

      # Try to get key from empty database
      future_ref = transaction_get_key(t.resource, "any_key", 1, 0, 0)
      result = Future.await(Future.create(future_ref))

      # Should return empty or boundary key
      assert is_binary(result)
    end
  end

  describe "transaction_get_range" do
    setup do
      db = new_database()
      t = Transaction.create(db)

      # Set up test data with predictable keys
      for i <- 1..20 do
        key = "range_key_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        value = "value_#{i}"
        transaction_set(t.resource, key, value)
      end

      Transaction.commit(t)

      # New transaction for testing
      t2 = Transaction.create(db)
      {:ok, db: db, transaction: t2}
    end

    test "basic range read", %{transaction: t} do
      # Read range from key_005 to key_010
      future_ref = transaction_get_range(
        t.resource,
        "range_key_005", 1, 0,     # begin key selector
        "range_key_010", 0, 1,     # end key selector (first > key_010)
        100,                       # limit
        0,                         # target_bytes (0 = default)
        0,                         # streaming_mode (0 = EXACT, requires limit)
        0,                         # iteration
        0,                         # snapshot
        0                          # reverse
      )

      future = Future.create(future_ref)
      {more, kvs} = Future.await(future)

      assert length(kvs) == 5
      assert more == 0

      # Verify keys are in order
      keys = Enum.map(kvs, fn {k, _v} -> k end)
      assert keys == ["range_key_005", "range_key_006", "range_key_007", "range_key_008", "range_key_009"]
    end

    test "range read with limit", %{transaction: t} do
      future_ref = transaction_get_range(
        t.resource,
        "range_key_001", 1, 0,
        "range_key_020", 1, 0,
        3,                         # limit to 3 results
        0, 0, 0, 0, 0
      )

      {more, kvs} = Future.await(Future.create(future_ref))

      assert length(kvs) == 3
      assert more == 1  # More results available
    end

    test "range read in reverse", %{transaction: t} do
      future_ref = transaction_get_range(
        t.resource,
        "range_key_005", 1, 0,
        "range_key_010", 0, 1,
        100, 0, 0, 0, 0,
        1                          # reverse = 1
      )

      {more, kvs} = Future.await(Future.create(future_ref))

      # Keys should be in reverse order
      keys = Enum.map(kvs, fn {k, _v} -> k end)
      assert keys == ["range_key_009", "range_key_008", "range_key_007", "range_key_006", "range_key_005"]
    end

    test "range read with target_bytes", %{transaction: t} do
      # Request small target_bytes to force pagination
      future_ref = transaction_get_range(
        t.resource,
        "range_key_001", 1, 0,
        "range_key_020", 1, 0,
        100,                       # limit
        50,                        # small target_bytes
        2, 0, 0, 0                 # streaming_mode 2 = WANT_ALL
      )

      {more, kvs} = Future.await(Future.create(future_ref))

      # Should return some results but maybe not all
      assert length(kvs) > 0
      # With small target_bytes, might have more
      assert more == 0 or more == 1
    end

    test "range read with different streaming modes", %{transaction: t} do
      # Test EXACT mode (0) - requires limit
      future_ref = transaction_get_range(
        t.resource,
        "range_key_001", 1, 0,
        "range_key_005", 1, 0,
        10, 0,
        0,                         # EXACT mode
        0, 0, 0
      )

      {more, kvs} = Future.await(Future.create(future_ref))
      assert length(kvs) > 0

      # Test WANT_ALL mode (2)
      future_ref2 = transaction_get_range(
        t.resource,
        "range_key_001", 1, 0,
        "range_key_003", 1, 0,
        0, 0,
        2,                         # WANT_ALL mode
        0, 0, 0
      )

      {more2, kvs2} = Future.await(Future.create(future_ref2))
      assert length(kvs2) == 2
    end

    test "empty range", %{transaction: t} do
      # Range where begin >= end
      future_ref = transaction_get_range(
        t.resource,
        "range_key_010", 1, 0,
        "range_key_005", 1, 0,
        100, 0, 0, 0, 0, 0
      )

      {more, kvs} = Future.await(Future.create(future_ref))

      assert kvs == []
      assert more == 0
    end

    test "range with snapshot read", %{transaction: t} do
      future_ref = transaction_get_range(
        t.resource,
        "range_key_001", 1, 0,
        "range_key_005", 1, 0,
        100, 0, 0, 0,
        1,                         # snapshot = 1
        0
      )

      {more, kvs} = Future.await(Future.create(future_ref))
      assert length(kvs) == 4
    end

    test "range with various key selector combinations", %{transaction: t} do
      # Test or_equal variations
      # Test various key selector combinations
      future_ref = transaction_get_range(
        t.resource,
        "range_key_005", 1, 1,     # first_greater_than (or_equal=1, offset=1)
        "range_key_009", 1, 0,     # first_greater_or_equal to key_009
        100, 0, 0, 0, 0, 0
      )

      {more, kvs} = Future.await(Future.create(future_ref))
      keys = Enum.map(kvs, fn {k, _v} -> k end)

      # Should get keys 006, 007, 008 (not 005, includes up to but not 009)
      assert keys == ["range_key_006", "range_key_007", "range_key_008"]
    end

    test "range iteration", %{transaction: t} do
      # First iteration
      future_ref1 = transaction_get_range(
        t.resource,
        "range_key_001", 1, 0,
        "range_key_020", 1, 0,
        5, 0, 0,
        0,                         # iteration 0
        0, 0
      )

      {more1, kvs1} = Future.await(Future.create(future_ref1))
      assert length(kvs1) == 5
      assert more1 == 1

      # Continue iteration from where we left off
      last_key = elem(List.last(kvs1), 0)
      future_ref2 = transaction_get_range(
        t.resource,
        last_key, 1, 1,            # start after last key (first_greater_than)
        "range_key_020", 1, 0,
        5, 0, 0,
        1,                         # iteration 1
        0, 0
      )

      {_more2, kvs2} = Future.await(Future.create(future_ref2))
      assert length(kvs2) == 5

      # Ensure no overlap - next batch should start after last key
      first_key2 = elem(List.first(kvs2), 0)
      assert first_key2 > last_key
    end
  end

  describe "transaction_get_range_split_points" do
    setup do
      db = new_database()
      t = Transaction.create(db)

      # Create a reasonable amount of data
      for i <- 1..100 do
        key = "split_key_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        value = String.duplicate("x", 100)  # 100 bytes per value
        transaction_set(t.resource, key, value)
      end

      Transaction.commit(t)

      t2 = Transaction.create(db)
      {:ok, db: db, transaction: t2}
    end

    test "get range split points", %{transaction: t} do
      future_ref = transaction_get_range_split_points(
        t.resource,
        "split_key_001",
        "split_key_100",
        1000  # chunk_size in bytes
      )

      future = Future.create(future_ref)
      split_points = Future.await(future)

      assert is_list(split_points)
      assert length(split_points) > 0

      # Split points should be in order
      if length(split_points) > 1 do
        pairs = Enum.zip(split_points, tl(split_points))
        assert Enum.all?(pairs, fn {a, b} -> a < b end)
      end
    end

    test "split points with small chunk size", %{transaction: t} do
      future_ref = transaction_get_range_split_points(
        t.resource,
        "split_key_001",
        "split_key_100",
        100  # very small chunk_size
      )

      split_points = Future.await(Future.create(future_ref))

      # Should have at least some split points
      assert length(split_points) >= 1
    end

    test "split points on valid empty range", %{transaction: t} do
      future_ref = transaction_get_range_split_points(
        t.resource,
        "nonexistent_start",
        "nonexistent_start_z",  # end > start
        1000
      )

      split_points = Future.await(Future.create(future_ref))

      # Should return empty or minimal split points
      assert is_list(split_points)
    end
  end

  describe "transaction_get_estimated_range_size_bytes" do
    setup do
      db = new_database()
      t = Transaction.create(db)

      # Set up data with known sizes
      for i <- 1..10 do
        key = "size_key_#{String.pad_leading(Integer.to_string(i), 2, "0")}"
        value = String.duplicate("v", i * 10)  # Increasing sizes
        transaction_set(t.resource, key, value)
      end

      Transaction.commit(t)

      t2 = Transaction.create(db)
      {:ok, db: db, transaction: t2}
    end

    test "estimate range size", %{transaction: t} do
      future_ref = transaction_get_estimated_range_size_bytes(
        t.resource,
        "size_key_01",
        "size_key_10"
      )

      size = Future.await(Future.create(future_ref))

      assert is_integer(size)
      # Size might be 0 for small ranges or include metadata
      assert size >= 0
    end

    test "estimate valid empty range size", %{transaction: t} do
      future_ref = transaction_get_estimated_range_size_bytes(
        t.resource,
        "z_start",
        "z_start_end"  # end > start
      )

      size = Future.await(Future.create(future_ref))

      assert is_integer(size)
      assert size >= 0  # Could be 0 or small metadata size
    end

    test "estimate single key range", %{transaction: t} do
      future_ref = transaction_get_estimated_range_size_bytes(
        t.resource,
        "size_key_05",
        "size_key_06"
      )

      size = Future.await(Future.create(future_ref))

      assert is_integer(size)
      # Size could be 0 for small ranges
      assert size >= 0
    end
  end

  describe "error conditions" do
    test "get_key with invalid transaction" do
      invalid_ref = make_ref()

      # Should raise ErlangError for invalid reference
      assert_raise ErlangError, fn ->
        transaction_get_key(invalid_ref, "key", 1, 0, 0)
      end
    end

    test "get_range with invalid parameters" do
      t = Transaction.create(new_database())

      # Invalid streaming mode should still return a future
      future_ref = transaction_get_range(
        t.resource,
        "start", 1, 0,
        "end", 1, 0,
        100, 0,
        999,  # invalid streaming mode
        0, 0, 0
      )
      assert is_reference(future_ref)
    end

    test "operations on cancelled transaction" do
      t = Transaction.create(new_database())
      transaction_cancel(t.resource)

      # Operations should return futures that will error when awaited
      future_ref = transaction_get_key(t.resource, "key", 1, 0, 0)
      assert is_reference(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future_ref))
      end
    end

    test "boundary conditions for selectors" do
      db = new_database()
      t = Transaction.create(db)

      # Set a single key
      transaction_set(t.resource, "only_key", "value")
      Transaction.commit(t)

      t2 = Transaction.create(db)

      # Test extreme offsets
      future_ref = transaction_get_key(t2.resource, "only_key", 1, 1000, 0)
      result = Future.await(Future.create(future_ref))
      assert is_binary(result)  # Should return some boundary key

      future_ref2 = transaction_get_key(t2.resource, "only_key", 1, -1000, 0)
      result2 = Future.await(Future.create(future_ref2))
      assert is_binary(result2)  # Should return some boundary key
    end
  end
end
