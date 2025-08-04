defmodule FDB.Native.TransactionAdvancedTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "transaction_clear" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "clears an existing key", %{transaction: t} do
      key = "clear_test_key"
      value = "test_value"

      # Set a value
      assert transaction_set(t.resource, key, value) == 0

      # Clear the key
      assert transaction_clear(t.resource, key) == 0

      # Verify key is gone
      future = transaction_get(t.resource, key, 0) |> Future.create()
      assert Future.await(future) == nil
    end

    test "clearing non-existent key succeeds", %{transaction: t} do
      # Clearing a key that doesn't exist should not error
      assert transaction_clear(t.resource, "non_existent_key") == 0
    end

    test "clears empty key", %{transaction: t} do
      # Set a value with empty key
      assert transaction_set(t.resource, "", "empty_key_value") == 0

      # Clear empty key
      assert transaction_clear(t.resource, "") == 0

      # Verify it's gone
      future = transaction_get(t.resource, "", 0) |> Future.create()
      assert Future.await(future) == nil
    end

    test "clears key with special characters", %{transaction: t} do
      key = <<0, 255, 128, 64, 32, 16, 8, 4, 2, 1>>

      # Set and clear
      assert transaction_set(t.resource, key, "special") == 0
      assert transaction_clear(t.resource, key) == 0

      # Verify
      future = transaction_get(t.resource, key, 0) |> Future.create()
      assert Future.await(future) == nil
    end
  end

  describe "transaction_clear_range" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "clears a range of keys", %{transaction: t} do
      # Set multiple keys
      for i <- 1..5 do
        key = "range_key_#{String.pad_leading(Integer.to_string(i), 2, "0")}"
        assert transaction_set(t.resource, key, "value_#{i}") == 0
      end

      # Clear range from key 2 to 4 (exclusive end)
      assert transaction_clear_range(t.resource, "range_key_02", "range_key_04") == 0

      # Verify keys 2 and 3 are gone, but 1, 4, and 5 remain
      assert Future.await(transaction_get(t.resource, "range_key_01", 0) |> Future.create()) == "value_1"
      assert Future.await(transaction_get(t.resource, "range_key_02", 0) |> Future.create()) == nil
      assert Future.await(transaction_get(t.resource, "range_key_03", 0) |> Future.create()) == nil
      assert Future.await(transaction_get(t.resource, "range_key_04", 0) |> Future.create()) == "value_4"
      assert Future.await(transaction_get(t.resource, "range_key_05", 0) |> Future.create()) == "value_5"
    end

    test "clears empty range", %{transaction: t} do
      # Clearing with begin >= end should be a no-op
      assert transaction_clear_range(t.resource, "z", "a") == 0
    end
  end

  describe "transaction_watch" do
    setup do
      db = new_database()
      {:ok, db: db}
    end

    test "watches a key for changes", %{db: db} do
      key = "watch_key"

      # Create a watch
      t1 = Transaction.create(db)
      watch_future_ref = transaction_watch(t1.resource, key)
      assert is_reference(watch_future_ref)
      watch_future = Future.create(watch_future_ref)

      # Commit the watching transaction
      Transaction.commit(t1)

      # Future should not be ready yet
      assert future_is_ready(watch_future_ref) == false

      # Change the key in another transaction
      Database.transact(db, fn t2 ->
        transaction_set(t2.resource, key, "new_value")
      end)

      # Watch future should now resolve
      assert Future.await(watch_future) == :ok
    end

    test "watch on empty key", %{db: db} do
      t = Transaction.create(db)

      # Watch empty key
      watch_future_ref = transaction_watch(t.resource, "")
      assert is_reference(watch_future_ref)

      # Should be able to commit
      Transaction.commit(t)
    end

    test "multiple watches on same transaction", %{db: db} do
      t = Transaction.create(db)

      # Create multiple watches
      watches = for i <- 1..3 do
        key = "multi_watch_#{i}"
        transaction_watch(t.resource, key)
      end

      assert length(watches) == 3
      assert Enum.all?(watches, &is_reference/1)

      Transaction.commit(t)
    end
  end

  describe "transaction_atomic_op" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "atomic add operation", %{db: db, transaction: t} do
      key = "atomic_add_key"

      # Initialize with 8-byte little-endian integer (value = 5)
      initial_value = <<5, 0, 0, 0, 0, 0, 0, 0>>
      assert transaction_set(t.resource, key, initial_value) == 0

      # Add 3 using atomic operation
      add_value = <<3, 0, 0, 0, 0, 0, 0, 0>>
      assert transaction_atomic_op(t.resource, key, add_value, 2) == 0  # 2 = ADD

      # Commit and verify
      Transaction.commit(t)

      # Read in new transaction
      t2 = Transaction.create(db)
      future = transaction_get(t2.resource, key, 0) |> Future.create()
      result = Future.await(future)

      # Should be 8 (5 + 3)
      assert result == <<8, 0, 0, 0, 0, 0, 0, 0>>
    end

    test "atomic bit operations", %{transaction: t} do
      key = "atomic_bit_key"

      # Initialize with some bits set
      initial_value = <<0xFF, 0x00, 0xFF, 0x00>>
      assert transaction_set(t.resource, key, initial_value) == 0

      # AND with mask
      and_mask = <<0xF0, 0xF0, 0xF0, 0xF0>>
      assert transaction_atomic_op(t.resource, key, and_mask, 6) == 0  # 6 = AND
    end

    test "atomic min/max operations", %{transaction: t} do
      key = "atomic_minmax_key"

      # Set initial value (10 as 8-byte little-endian)
      initial = <<10, 0, 0, 0, 0, 0, 0, 0>>
      assert transaction_set(t.resource, key, initial) == 0

      # Try to set MIN with value 5
      min_value = <<5, 0, 0, 0, 0, 0, 0, 0>>
      assert transaction_atomic_op(t.resource, key, min_value, 13) == 0  # 13 = MIN
    end
  end

  describe "transaction_add_conflict_range" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "adds read conflict range", %{transaction: t} do
      # Add a read conflict range - may fail with certain FDB configurations
      result = transaction_add_conflict_range(t.resource, "conflict_start", "conflict_end", 0)
      assert result == 0 or result == 2005  # 2005 = option_forbidden
    end

    test "adds write conflict range", %{transaction: t} do
      # Add a write conflict range - may fail with certain FDB configurations
      result = transaction_add_conflict_range(t.resource, "conflict_start", "conflict_end", 1)
      assert result == 0 or result == 2005  # 2005 = option_forbidden
    end

    test "conflict ranges with empty keys", %{transaction: t} do
      # Empty begin key - may fail with certain FDB configurations
      result1 = transaction_add_conflict_range(t.resource, "", "end", 0)
      assert result1 == 0 or result1 == 2005

      # Empty end key - may fail with certain FDB configurations
      result2 = transaction_add_conflict_range(t.resource, "start", "", 0)
      assert result2 == 0 or result2 == 2005
    end
  end

  describe "transaction_on_error" do
    setup do
      db = new_database()
      {:ok, db: db}
    end

    test "handles retryable errors", %{db: db} do
      t = Transaction.create(db)

      # Test with retryable error code (not_committed)
      error_code = 1020
      future_ref = transaction_on_error(t.resource, error_code)
      future = Future.create(future_ref)

      # Should complete successfully
      assert Future.await(future) == :ok
    end

    test "handles non-retryable errors", %{db: db} do
      t = Transaction.create(db)

      # Test with non-retryable error (invalid_option)
      error_code = 2000
      future_ref = transaction_on_error(t.resource, error_code)
      future = Future.create(future_ref)

      # Should raise error
      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end
  end

  describe "edge cases and error conditions" do
    test "operations on invalid transaction resource" do
      # Create a fake reference
      invalid_ref = make_ref()

      # Operations with invalid resources should raise errors
      assert_raise ErlangError, fn ->
        transaction_clear(invalid_ref, "key")
      end

      assert_raise ErlangError, fn ->
        transaction_clear_range(invalid_ref, "start", "end")
      end

      assert_raise ErlangError, fn ->
        transaction_watch(invalid_ref, "key")
      end

      assert_raise ErlangError, fn ->
        transaction_atomic_op(invalid_ref, "key", "value", 2)
      end

      assert_raise ErlangError, fn ->
        transaction_add_conflict_range(invalid_ref, "start", "end", 0)
      end
    end

    test "operations after transaction commit" do
      db = new_database()
      t = Transaction.create(db)
      key = "post_commit_key"

      # Set and commit
      transaction_set(t.resource, key, "value")
      Transaction.commit(t)

      # Operations after commit should handle gracefully
      assert transaction_clear(t.resource, key) == 0
      assert is_reference(transaction_watch(t.resource, key))
    end

    test "operations after transaction cancel" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel transaction
      assert transaction_cancel(t.resource) == 0

      # Operations should still return without crashing
      assert transaction_clear(t.resource, "key") == 0
      assert is_reference(transaction_watch(t.resource, "key"))
      assert transaction_atomic_op(t.resource, "key", "value", 2) == 0
    end
  end
end
