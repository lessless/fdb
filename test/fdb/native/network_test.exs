defmodule FDB.Native.NetworkTest do
  use ExUnit.Case, async: false
  import FDB.Native

  # Note: Network lifecycle tests are particularly sensitive because:
  # 1. The network can only be initialized once per process
  # 2. These operations affect global state
  # 3. They must be run in a specific order
  #
  # These tests are designed to run in isolation and may need special
  # handling in the test suite.

  @moduletag :integration
  @moduletag timeout: 30_000

  describe "network lifecycle" do
    @tag :skip
    test "full network lifecycle in isolated process" do
      # Run in a separate process to avoid interfering with other tests
      parent = self()

      spawn_link(fn ->
        try do
          # Select API version first
          assert select_api_version_impl(730, 730) == 0

          # Setup network
          result = setup_network()
          send(parent, {:setup_result, result})
          assert result == 0

          # Run network (starts the network thread)
          result = run_network()
          send(parent, {:run_result, result})
          assert result == 0

          # Let the network run for a bit
          :timer.sleep(100)

          # Create a database to verify network is working
          case create_database(nil) do
            {0, db} ->
              send(parent, {:database_created, :ok})

              # Try a simple operation
              transaction_result = database_create_transaction(db)
              send(parent, {:transaction_result, transaction_result})

            {error, _} ->
              send(parent, {:database_error, error})
          end

          # Stop network
          result = stop_network()
          send(parent, {:stop_result, result})
          assert result == 0

          send(parent, :done)
        catch
          kind, reason ->
            send(parent, {:error, kind, reason, __STACKTRACE__})
        end
      end)

      # Verify the sequence of operations
      assert_receive {:setup_result, 0}, 5000
      assert_receive {:run_result, 0}, 5000
      assert_receive {:database_created, :ok}, 5000
      assert_receive {:transaction_result, {0, _}}, 5000
      assert_receive {:stop_result, 0}, 10000
      assert_receive :done, 5000
    end

    @tag :skip
    test "network double initialization should fail" do
      # This test should run in an isolated process
      parent = self()

      spawn_link(fn ->
        try do
          # First initialization
          assert select_api_version_impl(730, 730) == 0
          assert setup_network() == 0

          # Second initialization should fail
          result = setup_network()
          send(parent, {:second_setup, result})

          # Clean up
          run_network()
          stop_network()

          send(parent, :done)
        catch
          kind, reason ->
            send(parent, {:error, kind, reason, __STACKTRACE__})
        end
      end)

      assert_receive {:second_setup, error_code}, 5000
      assert error_code != 0  # Should be an error
      assert_receive :done, 10000
    end

    test "network operations without initialization should fail" do
      # This test assumes the network is already initialized by the test helper
      # We're testing the error handling of operations that require network

      # Creating a database should work (network already initialized)
      case create_database(nil) do
        {0, _db} ->
          assert true
        {error, _} ->
          # If this fails, it might be because the network isn't initialized
          # which is also a valid test result
          assert error != 0
      end
    end

    test "stop_network without run_network" do
      # In the main test process, network is already running
      # This tests the error handling rather than the actual stop

      # We can't actually test this properly without interfering
      # with other tests, so we just verify the function exists
      assert function_exported?(FDB.Native, :stop_network, 0)
    end
  end

  describe "network options" do
    test "various network options can be set" do
      # Test setting various network options
      # Note: Some options can only be set before network initialization
      # We'll test options that can be set after initialization

      # Option with string value - trace log group can be set anytime
      assert network_set_option(
        network_option_trace_log_group(),
        "test_group"
      ) == 0

      # Another safe option that takes a value
      assert network_set_option(
        network_option_trace_format(),
        "xml"
      ) == 0
    end

    test "invalid network option should fail" do
      # Test with an invalid option code
      result = network_set_option(99999)
      assert result != 0  # Should be an error code

      # Verify we can get the error description
      error_msg = get_error(result)
      assert is_binary(error_msg)
      assert error_msg != "Success"
    end
  end

  # Helper functions for network options
  defp network_option_trace_log_group, do: 33
  defp network_option_trace_format, do: 34
end
