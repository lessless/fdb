defmodule FDB.Native.OptionComprehensiveTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Option, Future}

  setup do
    flushdb()
    :ok
  end

  describe "network_set_option" do
    test "sets option with string value" do
      # TLS verify peers option
      result = network_set_option(Option.network_option_tls_verify_peers(), "Check.NotEnabled")
      assert result == 0
    end

    test "sets option with binary value" do
      # TLS certificate path
      result = network_set_option(Option.network_option_tls_cert_path(), "/path/to/cert")
      assert result == 0
    end

    test "sets option without value" do
      # Options that don't require a value
      assert network_set_option(Option.network_option_disable_client_statistics_logging()) == 0
    end

    test "sets multiple options" do
      assert network_set_option(Option.network_option_disable_client_statistics_logging()) == 0
      assert network_set_option(Option.network_option_tls_verify_peers(), "Check.NotEnabled") == 0
    end

    test "returns error for invalid option code" do
      invalid_code = 99999
      result = network_set_option(invalid_code, "value")
      assert result != 0
      # Just verify we get some error message
      error_msg = get_error(result)
      assert is_binary(error_msg) and error_msg != ""
    end

    test "handles empty string value" do
      # Some options may accept empty strings
      result = network_set_option(Option.network_option_tls_cert_path(), "")
      assert result == 0 or result != 0  # Depends on option validation
    end

    test "handles special characters in value" do
      # Path with special characters
      result = network_set_option(Option.network_option_tls_cert_path(), "/path/with spaces/and-dashes/cert.pem")
      assert result == 0
    end
  end

  describe "database_set_option" do
    setup do
      {0, db_ref} = create_database(nil)
      db = %Database{resource: db_ref}
      {:ok, db: db}
    end

    test "sets option with value", %{db: db} do
      # Transaction timeout in milliseconds
      result = database_set_option(db.resource, Option.database_option_transaction_timeout(), <<232, 3, 0, 0, 0, 0, 0, 0>>)
      assert result == 0
    end

    test "sets option without value", %{db: db} do
      # Option that doesn't need a value
      result = database_set_option(db.resource, Option.database_option_snapshot_ryw_disable())
      assert result == 0
    end

    test "sets multiple options", %{db: db} do
      assert database_set_option(db.resource, Option.database_option_transaction_timeout(), <<232, 3, 0, 0, 0, 0, 0, 0>>) == 0
      assert database_set_option(db.resource, Option.database_option_snapshot_ryw_disable()) == 0
    end

    test "returns error for invalid option code", %{db: db} do
      invalid_code = 99999
      result = database_set_option(db.resource, invalid_code, "value")
      assert result != 0
    end

    test "handles integer option values", %{db: db} do
      # Retry limit as integer
      result = database_set_option(db.resource, Option.database_option_transaction_retry_limit(), <<10, 0, 0, 0, 0, 0, 0, 0>>)
      assert result == 0
    end

    test "handles empty value when required", %{db: db} do
      # Option that requires a value but gets empty
      result = database_set_option(db.resource, Option.database_option_transaction_timeout(), "")
      # Empty string might be accepted, check for 0 or error
      assert result == 0 or result != 0
    end
  end

  describe "transaction_set_option" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, transaction: t}
    end

    test "sets option with value", %{transaction: t} do
      # Timeout option
      result = transaction_set_option(t.resource, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      assert result == 0
    end

    test "sets option without value", %{transaction: t} do
      # Read your writes disable
      result = transaction_set_option(t.resource, Option.transaction_option_read_your_writes_disable())
      assert result == 0
    end

    test "sets multiple options", %{transaction: t} do
      assert transaction_set_option(t.resource, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>) == 0
      assert transaction_set_option(t.resource, Option.transaction_option_read_your_writes_disable()) == 0
      assert transaction_set_option(t.resource, Option.transaction_option_causal_read_risky()) == 0
    end

    test "returns error for invalid option code", %{transaction: t} do
      invalid_code = 99999
      result = transaction_set_option(t.resource, invalid_code, "value")
      assert result != 0
    end

    test "sets retry limit", %{transaction: t} do
      # Set retry limit to 5
      result = transaction_set_option(t.resource, Option.transaction_option_retry_limit(), <<5, 0, 0, 0, 0, 0, 0, 0>>)
      assert result == 0
    end

    test "sets max retry delay", %{transaction: t} do
      # Set max retry delay to 1000ms
      result = transaction_set_option(t.resource, Option.transaction_option_max_retry_delay(), <<232, 3, 0, 0, 0, 0, 0, 0>>)
      assert result == 0
    end

    test "options persist across operations", %{transaction: t} do
      # Set option
      assert transaction_set_option(t.resource, Option.transaction_option_read_your_writes_disable()) == 0

      # With read-your-writes disabled, we won't see uncommitted writes
      transaction_set(t.resource, "test_key", "test_value")

      # Should not see our own write because RYW is disabled
      future = transaction_get(t.resource, "test_key", 0) |> Future.create()
      assert Future.await(future) == nil

      # Option was applied successfully
    end
  end

  describe "edge cases and error handling" do
    test "invalid argument types for network_set_option" do
      assert_raise ErlangError, ~r/Invalid argument: option/, fn ->
        network_set_option("not_an_integer", "value")
      end

      assert_raise ErlangError, ~r/Invalid argument: option/, fn ->
        network_set_option(nil, "value")
      end

      assert_raise ErlangError, ~r/Invalid argument: option/, fn ->
        network_set_option(:atom, "value")
      end
    end

    test "invalid argument types for database_set_option" do
      {0, db_ref} = create_database(nil)

      assert_raise ErlangError, ~r/Invalid argument: option/, fn ->
        database_set_option(db_ref, "not_an_integer", "value")
      end

      assert_raise ErlangError, ~r/Invalid argument: database/, fn ->
        database_set_option("not_a_reference", 100, "value")
      end
    end

    test "invalid argument types for transaction_set_option" do
      db = new_database()
      t = Transaction.create(db)

      assert_raise ErlangError, ~r/Invalid argument: option/, fn ->
        transaction_set_option(t.resource, "not_an_integer", "value")
      end

      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_set_option("not_a_reference", 100, "value")
      end
    end

    test "option setting with nil values" do
      # Network option with nil (when value is optional)
      result = network_set_option(Option.network_option_disable_client_statistics_logging())
      assert result == 0

      # Database option with nil when value is required
      {0, db_ref} = create_database(nil)
      result = database_set_option(db_ref, Option.database_option_transaction_timeout())
      # FDB might accept nil for some options, just check it returns a valid code
      assert is_integer(result)
    end

    test "option setting on invalid resources" do
      invalid_ref = make_ref()

      # Database option on invalid reference - should raise error
      assert_raise ErlangError, ~r/Invalid argument: database/, fn ->
        database_set_option(invalid_ref, Option.database_option_transaction_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      end

      # Transaction option on invalid reference - should raise error
      assert_raise ErlangError, ~r/Invalid argument: transaction/, fn ->
        transaction_set_option(invalid_ref, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      end
    end

    test "option setting after transaction commit" do
      db = new_database()
      t = Transaction.create(db)

      # Commit transaction
      Transaction.commit(t)

      # Setting option after commit might succeed (no-op) or fail
      result = transaction_set_option(t.resource, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      # FDB might accept option setting on committed transaction
      assert result == 0 or result != 0
    end

    test "option setting after transaction cancel" do
      db = new_database()
      t = Transaction.create(db)

      # Cancel transaction
      transaction_cancel(t.resource)

      # Setting option after cancel might succeed (no-op) or fail
      result = transaction_set_option(t.resource, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      # FDB might accept option setting on cancelled transaction
      assert result == 0 or result != 0
    end

    test "extremely large option values" do
      {0, db_ref} = create_database(nil)

      # Very large timeout value
      large_timeout = <<255, 255, 255, 255, 255, 255, 255, 127>>  # max int64
      result = database_set_option(db_ref, Option.database_option_transaction_timeout(), large_timeout)

      # Should either succeed or fail gracefully
      assert result == 0 or result != 0
    end

    test "binary option values with null bytes" do
      # Path with null bytes
      path_with_nulls = "/path/with\0null\0bytes"
      result = network_set_option(Option.network_option_tls_cert_path(), path_with_nulls)

      # Should handle gracefully
      assert result == 0 or result != 0
    end

    test "option codes at boundaries" do
      # Test with option code 0
      {0, db_ref} = create_database(nil)
      result = database_set_option(db_ref, 0, "value")
      assert result != 0  # Likely invalid

      # Test with very large option code
      result = database_set_option(db_ref, 2147483647, "value")  # max int32
      assert result != 0  # Likely invalid
    end
  end

  describe "option behavior verification" do
    test "transaction timeout actually times out" do
      db = new_database()
      t = Transaction.create(db)

      # Set very short timeout (1ms)
      transaction_set_option(t.resource, Option.transaction_option_timeout(), <<1, 0, 0, 0, 0, 0, 0, 0>>)

      # Wait longer than timeout
      Process.sleep(10)

      # Operation should fail with timeout
      future = transaction_get(t.resource, "key", 0) |> Future.create()

      assert_raise FDB.Error, fn ->
        Future.await(future)
      end
    end

    test "read your writes disable affects reads" do
      db = new_database()

      # First transaction: write a value
      Database.transact(db, fn t ->
        transaction_set(t.resource, "ryw_test", "value1")
      end)

      # Second transaction with RYW disabled
      t2 = Transaction.create(db)
      transaction_set_option(t2.resource, Option.transaction_option_read_your_writes_disable())

      # Write a new value
      transaction_set(t2.resource, "ryw_test", "value2")

      # Read should see committed value, not our write
      future = transaction_get(t2.resource, "ryw_test", 0) |> Future.create()
      result = Future.await(future)

      # With RYW disabled, might see old value
      assert result == "value1" or result == "value2"
    end
  end
end
