defmodule FDB.Native.RangeFutureTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "transaction_get_range KEYVALUE_ARRAY future handling" do
    test "get_range future resolves to key-value array" do
      db = new_database()

      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..5 do
          key = "range_future_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      # Call get_range directly and await the future
      Database.transact(db, fn t ->
        future_ref = transaction_get_range(
          t.resource,
          "range_future_001", 1, 1,  # begin: first_greater_than
          "range_future_005", 1, 1,  # end: first_greater_than
          100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
        )

        # Create future wrapper and await it - this triggers KEYVALUE_ARRAY case
        future = Future.create(future_ref)
        result = Future.await(future)

        # Verify the result structure
        assert {more, kvs} = result
        assert more == 0  # No more results
        assert is_list(kvs)
        assert length(kvs) == 4  # Keys 002, 003, 004, 005

        # Verify each key-value pair
        [{k1, v1}, {k2, v2}, {k3, v3}, {k4, v4}] = kvs
        assert k1 == "range_future_002"
        assert v1 == "value_2"
        assert k2 == "range_future_003"
        assert v2 == "value_3"
        assert k3 == "range_future_004"
        assert v3 == "value_4"
        assert k4 == "range_future_005"
        assert v4 == "value_5"
      end)
    end

    test "get_range with empty result set" do
      db = new_database()

      Database.transact(db, fn t ->
        # Query a range with no data
        future_ref = transaction_get_range(
          t.resource,
          "nonexistent_start", 0, 1,
          "nonexistent_end", 0, 1,
          100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
        )

        future = Future.create(future_ref)
        result = Future.await(future)

        # Should return empty array
        assert {more, kvs} = result
        assert more == 0
        assert kvs == []
      end)
    end

    test "get_range with single result" do
      db = new_database()

      Database.transact(db, fn t ->
        Transaction.set(t, "single_key", "single_value")

        future_ref = transaction_get_range(
          t.resource,
          "single_ke", 1, 1,    # Just before "single_key"
          "single_key", 1, 1,   # Just after "single_key"
          100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
        )

        future = Future.create(future_ref)
        {more, kvs} = Future.await(future)

        assert more == 0
        assert length(kvs) == 1
        assert [{key, value}] = kvs
        assert key == "single_key"
        assert value == "single_value"
      end)
    end

    test "get_range with limit returns more flag" do
      db = new_database()

      Database.transact(db, fn t ->
        # Create many keys
        for i <- 1..20 do
          key = "limit_test_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      Database.transact(db, fn t ->
        future_ref = transaction_get_range(
          t.resource,
          "limit_test_001", 0, 1,
          "limit_test_020", 0, 1,
          5,  # Limit to 5 results
          0, 0, 0, 0, 0
        )

        future = Future.create(future_ref)
        {more, kvs} = Future.await(future)

        assert more == 1  # More results available
        assert length(kvs) == 5
      end)
    end

    test "get_range with binary keys containing special bytes" do
      db = new_database()

      Database.transact(db, fn t ->
        # Set keys with null bytes and other special characters
        key1 = <<0, 1, 2, 3>>
        key2 = <<0, 1, 2, 4>>
        key3 = <<0, 1, 2, 5>>

        Transaction.set(t, key1, <<255, 254, 253>>)
        Transaction.set(t, key2, <<252, 251, 250>>)
        Transaction.set(t, key3, <<249, 248, 247>>)

        future_ref = transaction_get_range(
          t.resource,
          <<0, 1, 2, 2>>, 0, 1,  # Start just before first key
          <<0, 1, 2, 6>>, 0, 1,  # End just after last key
          100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
        )

        future = Future.create(future_ref)
        {more, kvs} = Future.await(future)

        assert more == 0
        assert length(kvs) == 3

        # Verify binary data is preserved correctly
        [{k1, v1}, {k2, v2}, {k3, v3}] = kvs
        assert k1 == key1
        assert v1 == <<255, 254, 253>>
        assert k2 == key2
        assert v2 == <<252, 251, 250>>
        assert k3 == key3
        assert v3 == <<249, 248, 247>>
      end)
    end

    test "get_range with large result set" do
      db = new_database()

      # Create a large dataset
      Database.transact(db, fn t ->
        for i <- 1..100 do
          key = "large_set_#{String.pad_leading(Integer.to_string(i), 4, "0")}"
          value = String.duplicate("x", 100)  # 100 byte values
          Transaction.set(t, key, value)
        end
      end)

      Database.transact(db, fn t ->
        future_ref = transaction_get_range(
          t.resource,
          "large_set_0001", 0, 1,
          "large_set_0100", 0, 1,
          0,      # No limit
          5000,   # Target bytes (should return partial results)
          0, 0, 0, 0
        )

        future = Future.create(future_ref)
        {_more, kvs} = Future.await(future)

        # Should have some results but not all due to target_bytes
        assert length(kvs) > 0
        assert length(kvs) < 99  # Less than the full range

        # Verify data integrity
        Enum.each(kvs, fn {_key, value} ->
          assert byte_size(value) == 100
        end)
      end)
    end

    test "get_range future with error" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction to force an error
      transaction_cancel(t.resource)

      future_ref = transaction_get_range(
        t.resource,
        "any_key", 0, 1,
        "any_end", 0, 1,
        100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
      )

      future = Future.create(future_ref)

      # Should raise an error when awaiting
      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "get_range with reverse iteration" do
      db = new_database()

      Database.transact(db, fn t ->
        for i <- 1..5 do
          key = "reverse_#{i}"
          Transaction.set(t, key, "value_#{i}")
        end

        future_ref = transaction_get_range(
          t.resource,
          "reverse_1", 1, 1,
          "reverse_5", 1, 1,
          100, 0, 0, 0, 0,  # limit=100 for EXACT mode
          1  # reverse = true
        )

        future = Future.create(future_ref)
        {more, kvs} = Future.await(future)

        assert more == 0
        assert length(kvs) == 4

        # Keys should be in reverse order
        keys = Enum.map(kvs, fn {k, _v} -> k end)
        assert keys == ["reverse_5", "reverse_4", "reverse_3", "reverse_2"]
      end)
    end

    test "multiple concurrent get_range futures" do
      db = new_database()

      Database.transact(db, fn t ->
        for i <- 1..10 do
          key = "concurrent_#{String.pad_leading(Integer.to_string(i), 2, "0")}"
          Transaction.set(t, key, "value_#{i}")
        end
      end)

      Database.transact(db, fn t ->
        # Create multiple range queries
        future1_ref = transaction_get_range(
          t.resource,
          "concurrent_01", 1, 1,
          "concurrent_05", 1, 1,
          100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
        )

        future2_ref = transaction_get_range(
          t.resource,
          "concurrent_05", 1, 1,
          "concurrent_09", 1, 1,
          100, 0, 0, 0, 0, 0  # limit=100 for EXACT mode
        )

        # Await both futures
        future1 = Future.create(future1_ref)
        future2 = Future.create(future2_ref)

        {more1, kvs1} = Future.await(future1)
        {more2, kvs2} = Future.await(future2)

        assert more1 == 0
        assert more2 == 0
        assert length(kvs1) == 4  # 2, 3, 4, 5
        assert length(kvs2) == 4  # 6, 7, 8, 9
      end)
    end

    test "get_range with extreme key selectors" do
      db = new_database()

      Database.transact(db, fn t ->
        Transaction.set(t, "extreme_test", "value")

        # Test with large offset
        future_ref = transaction_get_range(
          t.resource,
          "extreme_test", 0, -100,  # 100 keys before
          "extreme_test", 0, 100,   # 100 keys after
          10, 0, 0, 0, 0, 0
        )

        future = Future.create(future_ref)
        {_more, kvs} = Future.await(future)

        # Should include our key even with extreme offsets
        assert length(kvs) >= 1
        assert Enum.any?(kvs, fn {k, _v} -> k == "extreme_test" end)
      end)
    end
  end
end
