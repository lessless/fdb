defmodule FDB.Native.FutureErrorTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "future error paths" do
    test "future_get with cancelled transaction - VALUE type" do
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
      assert_raise FDB.Error, ~r/Operation aborted because the transaction was cancelled/, fn ->
        Future.await(future)
      end
    end

    test "future_get with cancelled transaction - KEYVALUE_ARRAY type" do
      db = new_database()
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

    test "future_get with cancelled transaction - KEY type" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction
      transaction_cancel(t.resource)

      # Try to get_key - should return a future that errors
      future_ref = transaction_get_key(t.resource, "key", 0, 1, 0)
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "future_get with cancelled transaction - INT64 type" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction
      transaction_cancel(t.resource)

      # Try to get_read_version - returns INT64 future that requires network
      future_ref = transaction_get_read_version(t.resource)
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "future_get with cancelled transaction - STRING_ARRAY type" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel the transaction
      transaction_cancel(t.resource)

      # Try to get_addresses_for_key - returns STRING_ARRAY future
      future_ref = transaction_get_addresses_for_key(t.resource, "test_key")
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "future_get with committed transaction errors" do
      db = new_database()
      t = Transaction.create(db)

      # Commit the transaction
      Transaction.set(t, "key", "value")
      Transaction.commit(t)

      # Operations after commit should fail
      future_ref = transaction_get(t.resource, "key", 0)
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "future_get_error with various error codes" do
      db = new_database()

      # Test transaction timeout error
      t = Transaction.create(db)
      transaction_set_option(t.resource, FDB.Option.transaction_option_timeout(), <<1, 0, 0, 0, 0, 0, 0, 0>>)
      :timer.sleep(5)

      future_ref = transaction_get(t.resource, "timeout_key", 0)
      future = Future.create(future_ref)

      assert_raise FDB.Error, ~r/[Tt]imed out/, fn ->
        Future.await(future)
      end
    end

    test "future error with transaction conflicts" do
      db = new_database()
      key = "conflict_key_#{:rand.uniform(10000)}"

      # Set initial value
      Database.transact(db, fn t ->
        Transaction.set(t, key, "initial")
      end)

      # Create two transactions
      t1 = Transaction.create(db)
      t2 = Transaction.create(db)

      # Both read the same key
      Future.await(Future.create(transaction_get(t1.resource, key, 0)))
      Future.await(Future.create(transaction_get(t2.resource, key, 0)))

      # Both try to modify
      Transaction.set(t1, key, "value1")
      Transaction.set(t2, key, "value2")

      # Commit first transaction
      Transaction.commit(t1)

      # Second transaction should conflict
      commit_future = Future.create(transaction_commit(t2.resource))

      assert_raise FDB.Error, ~r/[Cc]onflict/, fn ->
        Future.await(commit_future)
      end
    end

    test "future with network errors" do
      # This test is tricky because we can't easily simulate network errors
      # But we can test the error handling path by using invalid operations

      db = new_database()
      t = Transaction.create(db)

      # Try to read a very large range that might trigger errors
      future_ref = transaction_get_range(
        t.resource,
        <<0>>, 0, 1,
        <<255>>, 0, 1,
        1_000_000, 0, 0, 0, 0, 0
      )

      # This might succeed or fail depending on database state
      # The important thing is it exercises the code path
      future = Future.create(future_ref)

      try do
        Future.await(future)
      rescue
        FDB.Error -> :ok
      end
    end

    test "concurrent future errors" do
      db = new_database()

      # Create multiple futures that will error
      tasks = for i <- 1..10 do
        Task.async(fn ->
          t = Transaction.create(db)
          transaction_cancel(t.resource)

          # Create different types of futures
          futures = case rem(i, 4) do
            0 ->
              ref = transaction_get(t.resource, "key", 0)
              Future.create(ref)
            1 ->
              ref = transaction_get_key(t.resource, "key", 0, 1, 0)
              Future.create(ref)
            2 ->
              ref = transaction_get_range(t.resource, "a", 0, 1, "z", 0, 1, 10, 0, 0, 0, 0, 0)
              Future.create(ref)
            3 ->
              ref = transaction_watch(t.resource, "key")
              Future.create(ref)
          end

          # All should error
          assert_raise FDB.Error, fn ->
            Future.await(futures)
          end
        end)
      end

      Task.await_many(tasks)
    end

    test "future error propagation through callbacks" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel to ensure error
      transaction_cancel(t.resource)

      # Create a future that will error
      future_ref = transaction_get(t.resource, "error_key", 0)

      # Use the callback mechanism
      ref = make_ref()
      assert future_resolve(future_ref, ref) == 0

      # Should receive an error message
      assert_receive {error_code, ^ref, _value}, 5000
      assert error_code != 0
    end

    test "edge case: future with empty keyvalue array" do
      db = new_database()

      Database.transact(db, fn t ->
        # Query an empty range
        future_ref = transaction_get_range(
          t.resource,
          "zzz_none_start", 0, 1,
          "zzz_none_end", 0, 1,
          100, 0, 0, 0, 0, 0
        )

        future = Future.create(future_ref)
        {more, kvs} = Future.await(future)

        assert more == 0
        assert kvs == []
      end)
    end

    test "future error with invalid future reference" do
      # This shouldn't happen in normal usage but tests defensive code

      # Try to check if a non-future reference is ready
      assert_raise ErlangError, ~r/future/, fn ->
        future_is_ready("not_a_future")
      end

      # Try to resolve with invalid reference
      assert_raise ErlangError, ~r/future/, fn ->
        future_resolve("not_a_future", make_ref())
      end
    end

    test "future timeout handling" do
      db = new_database()

      # Create a very short timeout transaction
      t = Transaction.create(db)
      # 1 millisecond timeout
      transaction_set_option(t.resource, FDB.Option.transaction_option_timeout(), <<1, 0, 0, 0, 0, 0, 0, 0>>)

      # Wait for timeout
      :timer.sleep(5)

      # All operations should timeout
      operations = [
        fn -> transaction_get(t.resource, "key", 0) end,
        fn -> transaction_get_key(t.resource, "key", 0, 1, 0) end,
        fn -> transaction_get_range(t.resource, "a", 0, 1, "z", 0, 1, 10, 0, 0, 0, 0, 0) end,
        fn -> transaction_commit(t.resource) end
      ]

      Enum.each(operations, fn op ->
        future_ref = op.()
        future = Future.create(future_ref)

        assert_raise FDB.Error, ~r/[Tt]imed out/, fn ->
          Future.await(future)
        end
      end)
    end

    test "future error with transaction reset" do
      db = new_database()
      t = Transaction.create(db)

      # Set and commit
      Transaction.set(t, "key", "value")
      Transaction.commit(t)

      # Try to use transaction after commit
      future_ref = transaction_get(t.resource, "key", 0)
      future = Future.create(future_ref)

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end
  end

  describe "future edge cases" do
    test "multiple futures from same transaction" do
      db = new_database()

      Database.transact(db, fn t ->
        # Create multiple futures of different types
        futures = [
          Future.create(transaction_get(t.resource, "key1", 0)),
          Future.create(transaction_get_key(t.resource, "key", 0, 1, 0)),
          Future.create(transaction_get_approximate_size(t.resource)),
          Future.create(transaction_get_addresses_for_key(t.resource, "key"))
        ]

        # All should resolve (some might be nil/empty)
        results = Enum.map(futures, fn f ->
          try do
            {:ok, Future.await(f)}
          rescue
            e -> {:error, e}
          end
        end)

        # At least some should succeed
        assert Enum.any?(results, fn r -> match?({:ok, _}, r) end)
      end)
    end

    test "future memory management with large results" do
      db = new_database()

      # Create many large values
      Database.transact(db, fn t ->
        for i <- 1..100 do
          key = "large_#{String.pad_leading(Integer.to_string(i), 4, "0")}"
          value = String.duplicate("x", 10_000)  # 10KB values
          Transaction.set(t, key, value)
        end
      end)

      # Read them back
      Database.transact(db, fn t ->
        future_ref = transaction_get_range(
          t.resource,
          "large_0001", 0, 1,
          "large_0100", 0, 1,
          50, 0, 0, 0, 0, 0
        )

        future = Future.create(future_ref)
        {_more, kvs} = Future.await(future)

        # Verify we got results and they're intact
        assert length(kvs) > 0
        Enum.each(kvs, fn {_k, v} ->
          assert byte_size(v) == 10_000
        end)
      end)
    end
  end
end
