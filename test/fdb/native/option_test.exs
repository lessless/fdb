defmodule FDB.Native.OptionTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Transaction, Future, Option}

  setup do
    flushdb()
    :ok
  end

  describe "network option setting" do
    test "set network option with string value" do
      # TLS verify peers option with a string value
      result = network_set_option(Option.network_option_tls_verify_peers(), "Check.NotEnabled")
      assert result == 0
    end

    test "set network option with binary value" do
      # TLS certificate path with binary value
      result = network_set_option(Option.network_option_tls_cert_path(), "/path/to/cert")
      assert result == 0
    end

    test "set network option without value" do
      # Options that don't require a value
      assert network_set_option(Option.network_option_disable_client_statistics_logging()) == 0
    end

    test "set multiple network options" do
      # Setting multiple options should work
      assert network_set_option(Option.network_option_disable_client_statistics_logging()) == 0
      assert network_set_option(Option.network_option_tls_verify_peers(), "Check.NotEnabled") == 0
    end

    test "network option with invalid code" do
      # Invalid option codes should return error
      invalid_code = 99999
      result = network_set_option(invalid_code, "value")
      assert result != 0
      assert get_error(result) =~ "option" or get_error(result) =~ "valid"
    end
  end

  describe "database option setting" do
    setup do
      {0, db} = create_database(nil)
      {:ok, db: db}
    end

    test "set database option with integer value", %{db: db} do
      # Location cache size expects 8-byte integer
      cache_size = <<100, 0, 0, 0, 0, 0, 0, 0>>  # 100 as little-endian int64
      result = database_set_option(db, Option.database_option_location_cache_size(), cache_size)
      assert result == 0
    end

    test "set database option without value", %{db: db} do
      # Snapshot RYW disable doesn't take a value
      result = database_set_option(db, Option.database_option_snapshot_ryw_disable())
      assert result == 0
    end

    test "set database option with wrong value size", %{db: db} do
      # Location cache size expects 8 bytes, give it 4
      wrong_size_value = <<100, 0, 0, 0>>
      result = database_set_option(db, Option.database_option_location_cache_size(), wrong_size_value)
      # This should succeed as the NIF doesn't validate size
      assert result == 0
    end

    test "set database option with unexpected value", %{db: db} do
      # Snapshot RYW disable shouldn't have a value
      result = database_set_option(db, Option.database_option_snapshot_ryw_disable(), <<1, 2, 3, 4>>)
      # This should succeed as the NIF passes it through
      assert result == 0
    end

    test "database option with invalid code", %{db: db} do
      invalid_code = 88888
      result = database_set_option(db, invalid_code, <<1, 2, 3, 4>>)
      assert result != 0
    end

    test "database options that affect behavior", %{db: db} do
      # Test various database options
      assert database_set_option(db, Option.database_option_snapshot_ryw_enable()) == 0
      assert database_set_option(db, Option.database_option_snapshot_ryw_disable()) == 0
    end
  end

  describe "transaction option setting" do
    setup do
      db = new_database()
      t = Transaction.create(db)
      {:ok, db: db, transaction: t}
    end

    test "set transaction timeout option", %{transaction: t} do
      # Timeout in milliseconds as 8-byte integer
      timeout_ms = <<100, 0, 0, 0, 0, 0, 0, 0>>  # 100ms
      result = transaction_set_option(t.resource, Option.transaction_option_timeout(), timeout_ms)
      assert result == 0
    end

    test "set transaction option without value", %{transaction: t} do
      # Snapshot RYW disable doesn't need a value
      result = transaction_set_option(t.resource, Option.transaction_option_snapshot_ryw_disable())
      assert result == 0
    end

    test "set transaction retry limit", %{transaction: t} do
      # Retry limit as 8-byte integer
      retry_limit = <<5, 0, 0, 0, 0, 0, 0, 0>>  # 5 retries
      result = transaction_set_option(t.resource, Option.transaction_option_retry_limit(), retry_limit)
      assert result == 0
    end

    test "set transaction size limit", %{transaction: t} do
      # Size limit in bytes as 8-byte integer
      size_limit = <<0, 0, 16, 0, 0, 0, 0, 0>>  # 1MB (1048576 bytes)
      result = transaction_set_option(t.resource, Option.transaction_option_size_limit(), size_limit)
      assert result == 0
    end

    test "set causal read risky option", %{transaction: t} do
      # This option takes no parameter
      result = transaction_set_option(t.resource, Option.transaction_option_causal_read_risky())
      assert result == 0
    end

    test "set read your writes disable", %{transaction: t} do
      result = transaction_set_option(t.resource, Option.transaction_option_read_your_writes_disable())
      assert result == 0
    end

    test "transaction option with invalid code", %{transaction: t} do
      invalid_code = 77777
      result = transaction_set_option(t.resource, invalid_code, <<1, 2, 3, 4>>)
      assert result != 0
    end

    test "set multiple transaction options", %{transaction: t} do
      # Should be able to set multiple options
      assert transaction_set_option(t.resource, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>) == 0
      assert transaction_set_option(t.resource, Option.transaction_option_retry_limit(), <<3, 0, 0, 0, 0, 0, 0, 0>>) == 0
      assert transaction_set_option(t.resource, Option.transaction_option_causal_read_risky()) == 0
    end

    test "transaction option affects behavior - timeout", %{db: db} do
      t = Transaction.create(db)

      # Set very short timeout (1ms)
      timeout_ms = <<1, 0, 0, 0, 0, 0, 0, 0>>
      assert transaction_set_option(t.resource, Option.transaction_option_timeout(), timeout_ms) == 0

      # Wait for timeout
      :timer.sleep(5)

      # Operations should fail with timeout
      future = transaction_get(t.resource, "test_key", 0)
      assert_raise FDB.Error, ~r/[Tt]imed out/, fn ->
        Future.await(Future.create(future))
      end
    end

    test "transaction option affects behavior - size limit", %{db: db} do
      t = Transaction.create(db)

      # Set small size limit (1000 bytes)
      size_limit = <<232, 3, 0, 0, 0, 0, 0, 0>>  # 1000 in little-endian
      assert transaction_set_option(t.resource, Option.transaction_option_size_limit(), size_limit) == 0

      # Try to set a large value
      large_value = String.duplicate("x", 2000)
      Transaction.set(t, "large_key", large_value)

      # Commit should fail due to size limit
      assert_raise FDB.Error, ~r/exceeds.*limit/, fn ->
        Transaction.commit(t)
      end
    end
  end

  describe "option validation" do
    test "options with empty binary values" do
      db = new_database()
      t = Transaction.create(db)

      # Empty binary for timeout (expects 8 bytes)
      result = transaction_set_option(t.resource, Option.transaction_option_timeout(), <<>>)
      # Should succeed as validation happens at FDB level
      assert result == 0
    end

    test "options with very large values" do
      db = new_database()
      t = Transaction.create(db)

      # Very large binary (more than 8 bytes for timeout)
      large_value = :binary.copy(<<1>>, 1000)
      result = transaction_set_option(t.resource, Option.transaction_option_timeout(), large_value)
      # Should succeed as NIF doesn't validate size
      assert result == 0
    end

    test "string options with special characters" do
      # Test path options with various characters
      special_paths = [
        "/path/with spaces/cert.pem",
        "/path/with/üñíçødé/cert.pem",
        "relative/path/cert.pem",
        "/path/with\nnewline",
        ""  # empty path
      ]

      Enum.each(special_paths, fn path ->
        result = network_set_option(Option.network_option_tls_cert_path(), path)
        assert result == 0
      end)
    end
  end

  describe "option error handling" do
    test "invalid resource type for database options" do
      t = Transaction.create(new_database())

      # Try to use transaction resource for database option
      assert_raise ErlangError, ~r/database/, fn ->
        database_set_option(t.resource, Option.database_option_location_cache_size(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      end
    end

    test "invalid resource type for transaction options" do
      {0, db} = create_database(nil)

      # Try to use database resource for transaction option
      assert_raise ErlangError, ~r/transaction/, fn ->
        transaction_set_option(db, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      end
    end

    test "nil resource" do
      assert_raise ErlangError, fn ->
        database_set_option(nil, Option.database_option_location_cache_size(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      end

      assert_raise ErlangError, fn ->
        transaction_set_option(nil, Option.transaction_option_timeout(), <<100, 0, 0, 0, 0, 0, 0, 0>>)
      end
    end
  end
end
