# FDB Native Test Organization

This directory contains comprehensive tests for the FDB NIF (Native Implemented Functions) layer.
The tests are organized by functional area to ensure complete coverage of the C code.

## Test Files

### Core API Tests

#### `api_test.exs`
- **Purpose**: Tests fundamental API version management and error handling
- **Coverage**:
  - `get_max_api_version/0`
  - `select_api_version_impl/2`
  - `get_error/1`
  - `get_error_predicate/2`
- **Key scenarios**: Version validation, error code translation, error predicates

#### `option_test.exs`
- **Purpose**: Tests option setting for network, database, and transactions
- **Coverage**:
  - `network_set_option/1,2`
  - `database_set_option/2,3`
  - `transaction_set_option/2,3`
- **Key scenarios**: Valid options, options with/without values, behavior verification

#### `database_transaction_test.exs`
- **Purpose**: Tests database and transaction lifecycle operations
- **Coverage**:
  - `create_database/1`
  - `database_create_transaction/1`
  - Transaction operations (commit, cancel, on_error)
  - Version management
  - Atomic operations
  - Conflict ranges
- **Key scenarios**: Resource creation, transaction lifecycle, error handling

### Specific Function Coverage

#### `uncovered_test.exs`
- **Purpose**: Tests for functions that were initially uncovered
- **Coverage**:
  - `transaction_clear/2`
  - `transaction_watch/2`
  - `transaction_get_key/5`
  - `transaction_get_range/13`
- **Key scenarios**: Direct NIF testing, edge cases, error conditions

#### `range_future_test.exs`
- **Purpose**: Tests for KEYVALUE_ARRAY future type
- **Coverage**: `transaction_get_range` future handling
- **Key scenarios**: Empty ranges, large result sets, streaming modes, pagination

#### `key_watch_future_test.exs`
- **Purpose**: Tests for KEY and WATCH future types
- **Coverage**:
  - `transaction_get_key` KEY future handling
  - `transaction_watch` WATCH future handling
- **Key scenarios**: Key selectors, watch triggers, concurrent operations

### Edge Cases and Error Paths

#### `option_error_edge_cases_test.exs`
- **Purpose**: Tests error paths and edge cases in option parsing
- **Coverage**: Option parsing failures, invalid values, type mismatches
- **Key scenarios**: Invalid option codes, wrong value sizes, resource type validation

#### `atom_creation_test.exs`
- **Purpose**: Tests atom creation paths in the C code
- **Coverage**: `make_atom` function usage
- **Key scenarios**: All code paths that return atoms (:ok, :true, :false)

#### `database_path_test.exs`
- **Purpose**: Tests database creation with custom cluster file paths
- **Coverage**: Path handling in `create_database`
- **Key scenarios**: Various path formats, special characters, error cases

#### `future_error_test.exs`
- **Purpose**: Tests error handling in future operations
- **Coverage**: Error paths in `future_get` for all future types
- **Key scenarios**: Cancelled transactions, timeouts, conflicts, network errors

## Test Coverage Summary

As of the last run, the native tests achieve:
- **96.25%** line coverage (641/666 lines)
- **100%** function coverage (52/52 functions)
- **100%** branch coverage (218/218 branches executed)
- **63.3%** branches taken both ways

## Running Tests

```bash
# Run all native tests
mix test test/fdb/native

# Run specific test file
mix test test/fdb/native/api_test.exs

# Run with coverage
make nif_coverage

# Generate HTML coverage report
lcov --capture --directory . --output-file cover/coverage.info --rc lcov_branch_coverage=1
genhtml cover/coverage.info --output-directory cover/html --branch-coverage
```

## Uncovered Code

The remaining uncovered lines (25) are primarily:
1. Error return paths when FDB API calls fail
2. The `make_atom` branch for creating new atoms (impossible to trigger)
3. Resource loading failures during initialization
4. Some option parsing error returns

These represent defensive programming and would require:
- Mocking the FDB library
- Injecting failures
- Running under extreme conditions (out of memory, etc.)

## Test Principles

All tests follow:
- **KISS** (Keep It Simple, Stupid) - Simple, focused tests
- **YAGNI** (You Aren't Gonna Need It) - No over-engineering
- **Readability** - Clear test names and assertions
- **Maintainability** - Well-organized, easy to update

## Further work
2. **Stress Testing** - Add long-running stress tests for memory leak detection
3. **Valgrind Integration** - Run tests under Valgrind to detect memory issues
4. **Benchmarking** - Add performance benchmarks for NIF operations
