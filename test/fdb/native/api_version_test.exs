defmodule FDB.Native.ApiVersionTest do
  use ExUnit.Case, async: false
  import FDB.Native

  @current_api_version 730

  describe "API version management" do
    test "get_max_api_version returns a valid version" do
      max_version = get_max_api_version()
      assert is_integer(max_version)
      assert max_version >= @current_api_version
    end

    test "select_api_version_impl with valid matching versions" do
      # When runtime and header versions match, it should succeed
      assert select_api_version_impl(@current_api_version, @current_api_version)
    end

    test "select_api_version_impl with higher runtime version" do
      # When runtime version is higher than header version, it returns an error code
      result = select_api_version_impl(@current_api_version + 100, @current_api_version)
      assert result == 2201  # API version may be set only once
    end

    test "select_api_version_impl with invalid runtime_version type" do
      assert_raise ErlangError, ~r/runtime_version/, fn ->
        select_api_version_impl("hello", @current_api_version)
      end

      assert_raise ErlangError, ~r/runtime_version/, fn ->
        select_api_version_impl(nil, @current_api_version)
      end

      assert_raise ErlangError, ~r/runtime_version/, fn ->
        select_api_version_impl(:atom, @current_api_version)
      end
    end

    test "select_api_version_impl with invalid header_version type" do
      assert_raise ErlangError, ~r/header_version/, fn ->
        select_api_version_impl(@current_api_version, "hello")
      end

      assert_raise ErlangError, ~r/header_version/, fn ->
        select_api_version_impl(@current_api_version, nil)
      end

      assert_raise ErlangError, ~r/header_version/, fn ->
        select_api_version_impl(@current_api_version, :atom)
      end
    end

    test "select_api_version_impl with boundary values" do
      # API version is already set during test setup, so all calls should return error 2201
      # "API version may be set only once"

      # Test with minimum valid version
      min_version = 13  # FDB's minimum supported version
      result = select_api_version_impl(min_version, min_version)
      # Should return error code 2201 (API version already set)
      assert result == 2201

      # Test with very high version numbers
      high_version = 9999
      result = select_api_version_impl(high_version, @current_api_version)
      assert result == 2201
    end
  end

  describe "error code translation" do
    test "get_error with success code" do
      assert get_error(0) == "Success"
    end

    test "get_error with known error codes" do
      # API version errors
      assert get_error(2201) == "API version may be set only once"
      assert get_error(2202) == "API version not valid"

      # Common transaction errors
      assert get_error(1007) == "Transaction is too old to perform reads or be committed"
      assert get_error(1020) == "Transaction not committed due to conflict with another transaction"
      assert get_error(1021) == "Transaction may or may not have committed"
      assert get_error(1031) == "Operation aborted because the transaction timed out"

      # Network errors
      assert get_error(1037) == "Storage process does not have recent mutations"

      # Database errors
      assert get_error(1040) == "External client has already been loaded"
      assert get_error(2002) == "Commit with incomplete read"
      assert get_error(2003) == "Invalid test specification"
    end

    test "get_error with unknown error code" do
      # Unknown error codes should return "UNKNOWN_ERROR"
      assert get_error(42) == "UNKNOWN_ERROR"
      assert get_error(99999) == "An unknown error occurred"
      assert get_error(-1) == "An unknown error occurred"
    end

    test "get_error with boundary values" do
      # Test error codes at boundaries
      assert get_error(1) == "End of stream"  # Very low non-zero
      assert get_error(9999) == "UNKNOWN_ERROR"  # High but not special

      # Test some internal error codes that might exist
      assert is_binary(get_error(1000))
      assert is_binary(get_error(2000))
      assert is_binary(get_error(3000))
      assert is_binary(get_error(4000))
      assert is_binary(get_error(5000))
    end

    test "get_error returns proper error messages" do
      # Ensure all returned values are binary strings
      for code <- [0, 100, 1000, 1020, 1031, 2000, 2201, 2202, 9999] do
        result = get_error(code)
        assert is_binary(result), "get_error(#{code}) should return a binary string"
        assert byte_size(result) > 0, "get_error(#{code}) should not return an empty string"
      end
    end
  end

  describe "error predicates" do
    test "get_error_predicate with retryable errors" do
      retryable_predicate = FDB.Option.error_predicate_retryable()

      # Known retryable errors
      assert get_error_predicate(retryable_predicate, 1007) == :true  # too_old
      assert get_error_predicate(retryable_predicate, 1020) == :true  # not_committed

      # Non-retryable errors
      assert get_error_predicate(retryable_predicate, 0) == :false     # success
      assert get_error_predicate(retryable_predicate, 1031) == :false  # transaction_timed_out
      assert get_error_predicate(retryable_predicate, 2000) == :false  # invalid_option
      assert get_error_predicate(retryable_predicate, 2002) == :false  # invalid_operation
    end

    test "get_error_predicate with maybe_committed errors" do
      maybe_committed_predicate = FDB.Option.error_predicate_maybe_committed()

      # Test various error codes
      assert get_error_predicate(maybe_committed_predicate, 0) in [:true, :false]
      assert get_error_predicate(maybe_committed_predicate, 1020) in [:true, :false]
      assert get_error_predicate(maybe_committed_predicate, 1021) in [:true, :false]
    end

    test "get_error_predicate with retryable_not_committed errors" do
      predicate = FDB.Option.error_predicate_retryable_not_committed()

      # Test various error codes
      assert get_error_predicate(predicate, 1020) in [:true, :false]
      assert get_error_predicate(predicate, 1007) in [:true, :false]
      assert get_error_predicate(predicate, 0) == :false  # success is never retryable
    end

    test "get_error_predicate with invalid inputs" do
      # Invalid predicate type
      assert_raise ErlangError, fn ->
        get_error_predicate("not_a_predicate", 1020)
      end

      # Invalid error code type
      assert_raise ErlangError, fn ->
        get_error_predicate(FDB.Option.error_predicate_retryable(), "not_an_int")
      end
    end
  end
end
