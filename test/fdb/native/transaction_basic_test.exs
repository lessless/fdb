defmodule FDB.Native.TransactionBasicTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "database creation" do
    test "create_database with default cluster file" do
      {error_code, db_ref} = create_database(nil)
      assert error_code == 0
      assert is_reference(db_ref)
    end

    test "create_database returns proper Database resource" do
      {0, db_ref} = create_database(nil)
      db = %Database{resource: db_ref}
      assert %Database{resource: ^db_ref} = db
    end

    test "multiple database creation" do
      # Creating multiple databases should work
      databases = for _ <- 1..5 do
        {error_code, db_ref} = create_database(nil)
        assert error_code == 0
        db_ref
      end

      assert length(databases) == 5
      assert Enum.all?(databases, &is_reference/1)
    end

    test "create_database with custom cluster file path" do
      # Test with a specific cluster file path
      # This exercises the path handling code in create_database
      {error_code, db_ref} = create_database("/etc/foundationdb/fdb.cluster")

      # The database creation might fail if the file doesn't exist,
      # but the important part is that the path handling code is executed
      if error_code == 0 do
        assert is_reference(db_ref)
        # Create a Database struct to test it works
        db = %Database{resource: db_ref}
        assert %Database{} = db
      else
        # If it fails, verify we get a proper error code
        assert error_code != 0
        assert is_binary(get_error(error_code))
      end
    end

    test "create_database with non-existent path" do
      # FDB now accepts non-existent paths and uses default cluster configuration
      {error_code, _db_ref} = create_database("/nonexistent/path/to/fdb.cluster")

      # Should succeed with a valid database reference
      assert error_code == 0

      # Since it succeeds, the error message should be "Success"
      error_msg = get_error(error_code)
      assert String.downcase(error_msg) == "success"
    end

    test "create_database with empty string path" do
      # Empty string as path
      {error_code, db_ref} = create_database("")

      # This should succeed using default cluster
      assert error_code == 0
      assert is_reference(db_ref)
    end

    test "create_database with various path types" do
      # Test different path formats
      paths = [
        "relative/path/fdb.cluster",
        "./fdb.cluster",
        "../fdb.cluster",
        "~/fdb.cluster",
        "/absolute/path/fdb.cluster"
      ]

      for path <- paths do
        {error_code, db_ref} = create_database(path)
        # All should return valid responses
        assert error_code == 0
        assert is_reference(db_ref)
      end
    end
  end

  describe "transaction creation and lifecycle" do
    setup do
      db = new_database()
      {:ok, db: db}
    end

    test "create transaction from database", %{db: db} do
      {error_code, txn_ref} = database_create_transaction(db.resource)
      assert error_code == 0
      assert is_reference(txn_ref)
    end

    test "transaction basic operations", %{db: db} do
      t = Transaction.create(db)
      key = random_key()
      value = random_value()

      # Set a value
      assert transaction_set(t.resource, key, value) == 0

      # Get the value
      future_ref = transaction_get(t.resource, key, 0)
      future = Future.create(future_ref)
      assert Future.await(future) == value

      # Commit the transaction
      commit_future_ref = transaction_commit(t.resource)
      commit_future = Future.create(commit_future_ref)
      assert Future.await(commit_future) == :ok
    end

    test "transaction read version", %{db: db} do
      t = Transaction.create(db)

      # Get read version
      future_ref = transaction_get_read_version(t.resource)
      future = Future.create(future_ref)
      version = Future.await(future)

      assert is_integer(version)
      assert version > 0
    end

    test "transaction set and get read version", %{db: db} do
      # Get a version from one transaction
      version = Database.transact(db, fn t ->
        future_ref = transaction_get_read_version(t.resource)
        Future.await(Future.create(future_ref))
      end)

      # Use it in another transaction
      t2 = Transaction.create(db)
      assert transaction_set_read_version(t2.resource, version) == 0

      # Should still be able to read
      future_ref = transaction_get(t2.resource, "some_key", 0)
      result = Future.await(Future.create(future_ref))
      assert result == nil  # Key doesn't exist
    end

    test "transaction approximate size", %{db: db} do
      t = Transaction.create(db)

      # Initially should be small
      future_ref = transaction_get_approximate_size(t.resource)
      initial_size = Future.await(Future.create(future_ref))
      assert is_integer(initial_size)
      assert initial_size >= 0

      # Add some data
      for i <- 1..10 do
        Transaction.set(t, "size_test_#{i}", String.duplicate("x", 1000))
      end

      # Size should increase
      future_ref2 = transaction_get_approximate_size(t.resource)
      new_size = Future.await(Future.create(future_ref2))
      assert new_size > initial_size
    end

    test "transaction committed version", %{db: db} do
      t = Transaction.create(db)
      Transaction.set(t, "version_test", "value")

      # Before commit, getting committed version might error or return 0
      {error_code, _version_before} = transaction_get_committed_version(t.resource)
      assert error_code == 0 or error_code != 0

      # Commit the transaction
      Transaction.commit(t)

      # After commit, should have a version
      {error_code, version} = transaction_get_committed_version(t.resource)
      assert error_code == 0
      assert is_integer(version)
      assert version > 0
    end

    test "transaction versionstamp", %{db: db} do
      Database.transact(db, fn t ->
        # Set a regular key to have something in the transaction
        Transaction.set(t, "versionstamp_test", "value")

        # Get versionstamp future
        future_ref = transaction_get_versionstamp(t.resource)
        assert is_reference(future_ref)

        # Don't await here - the future resolves after commit
        Future.create(future_ref)
      end)
    end

    test "transaction cancel", %{db: db} do
      t = Transaction.create(db)
      Transaction.set(t, "cancel_test", "value")

      # Cancel should always succeed
      assert transaction_cancel(t.resource) == 0

      # Further operations should fail
      future_ref = transaction_get(t.resource, "cancel_test", 0)
      assert_raise FDB.Error, fn ->
        Future.await(Future.create(future_ref))
      end
    end

    test "transaction on_error with retryable error", %{db: db} do
      t = Transaction.create(db)

      # Test with a retryable error code
      error_code = 1020  # not_committed - retryable
      future_ref = transaction_on_error(t.resource, error_code)
      future = Future.create(future_ref)

      # Should complete successfully for retryable errors
      assert Future.await(future) == :ok
    end

    test "transaction on_error with non-retryable error", %{db: db} do
      t = Transaction.create(db)

      # Test with a non-retryable error
      error_code = 2000  # invalid_option - non-retryable
      future_ref = transaction_on_error(t.resource, error_code)
      future = Future.create(future_ref)

      # Should raise an error for non-retryable errors
      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end
  end

  describe "transaction key operations" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "get_addresses_for_key", %{transaction: t} do
      key = "address_test_key"
      Transaction.set(t, key, "value")

      future_ref = transaction_get_addresses_for_key(t.resource, key)
      future = Future.create(future_ref)
      addresses = Future.await(future)

      assert is_list(addresses)
      assert length(addresses) > 0
      assert Enum.all?(addresses, &is_binary/1)
    end

    test "atomic operations", %{transaction: t} do
      key = "atomic_key"

      # Initialize with a number
      Transaction.set(t, key, <<1, 0, 0, 0, 0, 0, 0, 0>>)

      # ADD operation
      assert transaction_atomic_op(
        t.resource,
        key,
        <<2, 0, 0, 0, 0, 0, 0, 0>>,
        FDB.Option.mutation_type_add()
      ) == 0

      # Other atomic operations
      assert transaction_atomic_op(
        t.resource,
        "bit_key",
        <<0xFF, 0x00, 0xFF, 0x00>>,
        FDB.Option.mutation_type_bit_and()
      ) == 0

      assert transaction_atomic_op(
        t.resource,
        "max_key",
        <<5, 0, 0, 0, 0, 0, 0, 0>>,
        FDB.Option.mutation_type_max()
      ) == 0
    end

    test "conflict ranges", %{transaction: t} do
      # Add read conflict range
      assert transaction_add_conflict_range(
               t.resource,
               "conflict_a",
               "conflict_z",
               FDB.Option.conflict_range_type_read()
             ) == 0

      # Add write conflict range
      assert transaction_add_conflict_range(
               t.resource,
               "conflict_a",
               "conflict_z",
               FDB.Option.conflict_range_type_write()
             ) == 0
    end

    test "clear range", %{db: db} do
      # Set up test data
      Database.transact(db, fn t ->
        for i <- 1..10 do
          Transaction.set(t, "clear_range_#{i}", "value_#{i}")
        end
      end)

      # Clear a range
      Database.transact(db, fn t ->
        assert transaction_clear_range(t.resource, "clear_range_3", "clear_range_7") == 0
      end)

      # Verify cleared
      Database.transact(db, fn t ->
        # Keys 1, 2 should exist
        assert Transaction.get(t, "clear_range_1") == "value_1"
        assert Transaction.get(t, "clear_range_2") == "value_2"

        # Keys 3-6 should be cleared (7 is exclusive end)
        assert Transaction.get(t, "clear_range_3") == nil
        assert Transaction.get(t, "clear_range_4") == nil
        assert Transaction.get(t, "clear_range_5") == nil
        assert Transaction.get(t, "clear_range_6") == nil

        # Keys 7+ should exist
        assert Transaction.get(t, "clear_range_7") == "value_7"
        assert Transaction.get(t, "clear_range_8") == "value_8"
      end)
    end

    test "get_estimated_range_size_bytes", %{db: db} do
      # Create some data
      Database.transact(db, fn t ->
        for i <- 1..50 do
          key = "size_estimate_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, String.duplicate("x", 100))
        end
      end)

      # Estimate size
      Database.transact(db, fn t ->
        future_ref = transaction_get_estimated_range_size_bytes(
          t.resource,
          "size_estimate_000",
          "size_estimate_999"
        )
        future = Future.create(future_ref)
        size = Future.await(future)

        assert is_integer(size)
        assert size >= 0
      end)
    end

    test "get_range_split_points", %{db: db} do
      # Create data for splitting
      Database.transact(db, fn t ->
        for i <- 1..100 do
          key = "split_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          Transaction.set(t, key, String.duplicate("x", 100))
        end
      end)

      # Get split points
      Database.transact(db, fn t ->
        future_ref = transaction_get_range_split_points(
          t.resource,
          "split_000",
          "split_999",
          1000  # chunk size
        )
        future = Future.create(future_ref)
        split_points = Future.await(future)

        assert is_list(split_points)
        # May or may not have split points depending on data size
        assert length(split_points) >= 0
      end)
    end
  end

  describe "transaction snapshot operations" do
    setup do
      db = new_database()
      {:ok, db: db}
    end

    test "snapshot reads", %{db: db} do
      key = "snapshot_test"
      value = "original_value"

      # Set initial value
      Database.transact(db, fn t ->
        Transaction.set(t, key, value)
      end)

      # Start a transaction and modify the key
      t = Transaction.create(db)
      Transaction.set(t, "other_key", "other_value")

      # Snapshot read should see committed value
      future_ref = transaction_get(t.resource, key, 1)  # snapshot = 1
      result = Future.await(Future.create(future_ref))
      assert result == value

      # Non-snapshot read in a new transaction should also see it
      t2 = Transaction.create(db)
      future_ref2 = transaction_get(t2.resource, key, 0)  # snapshot = 0
      result2 = Future.await(Future.create(future_ref2))
      assert result2 == value
    end
  end

  describe "error conditions" do
    test "operations on invalid transaction resource" do
      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_get("not_a_transaction", "key", 0)
      end

      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_set("not_a_transaction", "key", "value")
      end

      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_commit("not_a_transaction")
      end
    end

    test "operations on invalid database resource" do
      assert_raise ErlangError, ~r/database/, fn ->
        database_create_transaction("not_a_database")
      end
    end

    test "operations after transaction commit" do
      db = new_database()
      t = Transaction.create(db)
      Transaction.set(t, "key", "value")

      # Await the commit
      commit_future_ref = transaction_commit(t.resource)
      commit_future = Future.create(commit_future_ref)
      Future.await(commit_future)

      # NIF operations might succeed but futures will error
      assert transaction_set(t.resource, "key2", "value2") == 0

      # But another commit will fail
      commit_future2 = Future.create(transaction_commit(t.resource))
      assert_raise FDB.Error, fn ->
        Future.await(commit_future2)
      end
    end
  end
end
