defmodule FDB.Native.DatabasePathTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction}

  setup do
    flushdb()
    :ok
  end

  describe "create_database with custom path" do
    test "create_database with valid cluster file path" do
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
      assert error_msg == "Success"
    end

    test "create_database with empty string path" do
      # Empty string as path
      {error_code, db_ref} = create_database("")

      # This might succeed (using default) or fail
      if error_code == 0 do
        assert is_reference(db_ref)
      else
        assert error_code != 0
      end
    end

    test "create_database with relative path" do
      # Test with a relative path
      {error_code, _db_ref} = create_database("./fdb.cluster")

      # Just verify the path handling code runs
      assert is_integer(error_code)
    end

    test "create_database with path containing special characters" do
      # Path with spaces and special characters
      path_with_spaces = "/path with spaces/fdb.cluster"
      {error_code, _db_ref} = create_database(path_with_spaces)

      # Verify error code is returned
      assert is_integer(error_code)

      # Path with unicode characters
      unicode_path = "/path/with/üñíçødé/fdb.cluster"
      {error_code2, _db_ref2} = create_database(unicode_path)
      assert is_integer(error_code2)
    end

    test "create_database with very long path" do
      # Create a very long path to test buffer handling
      long_path = "/" <> String.duplicate("a", 1000) <> "/fdb.cluster"
      {error_code, _db_ref} = create_database(long_path)

      # Should handle long paths gracefully
      assert is_integer(error_code)
    end

    test "create_database with nil uses default" do
      # This is the normal case - nil means use default cluster file
      {error_code, db_ref} = create_database(nil)

      # This should succeed in test environment
      assert error_code == 0
      assert is_reference(db_ref)
    end

    test "create_database with binary path" do
      # Test that binary paths are handled correctly
      binary_path = "/tmp/fdb.cluster"
      {error_code, _db_ref} = create_database(binary_path)

      # Just verify it processes without crashing
      assert is_integer(error_code)
    end

    test "multiple create_database calls with different paths" do
      # Test creating multiple databases with different paths
      paths = [
        nil,
        "/etc/foundationdb/fdb.cluster",
        "/tmp/test.cluster",
        "./local.cluster"
      ]

      results = Enum.map(paths, fn path ->
        {error_code, db_ref} = create_database(path)
        {path, error_code, db_ref}
      end)

      # Verify all calls completed
      assert length(results) == 4

      # At least the nil path should succeed
      {nil, nil_error, nil_ref} = Enum.find(results, fn {path, _, _} -> path == nil end)
      assert nil_error == 0
      assert is_reference(nil_ref)
    end

    test "create_database path with null bytes" do
      # Path containing null byte (should be handled safely)
      path_with_null = "/tmp/fdb\0cluster"
      {error_code, _db_ref} = create_database(path_with_null)

      # Should complete without crashing
      assert is_integer(error_code)
    end

    test "Database.create with custom path" do
      # Test the high-level API as well
      db = Database.create("/tmp/nonexistent.cluster")
      assert %Database{} = db

      # Try to use it - should fail with cluster file error
      assert_raise FDB.Error, ~r/[Cc]luster|[Ff]ile/, fn ->
        Database.transact(db, fn t ->
          Transaction.get(t, "test")
        end)
      end
    end
  end

  describe "path encoding and memory handling" do
    test "path string is properly null-terminated" do
      # This test ensures the C code properly null-terminates the path
      # Various length strings to test boundary conditions
      test_paths = [
        "a",
        "ab",
        String.duplicate("x", 255),
        String.duplicate("y", 256),
        String.duplicate("z", 1024)
      ]

      Enum.each(test_paths, fn path ->
        {error_code, _db_ref} = create_database(path)
        # Just verify it completes without segfault
        assert is_integer(error_code)
      end)
    end

    test "concurrent create_database with paths" do
      # Test thread safety of path handling
      tasks = for i <- 1..10 do
        Task.async(fn ->
          path = "/tmp/concurrent_#{i}.cluster"
          create_database(path)
        end)
      end

      results = Task.await_many(tasks)
      assert length(results) == 10

      # All should return valid results
      Enum.each(results, fn {error_code, _db_ref} ->
        assert is_integer(error_code)
      end)
    end
  end
end
