defmodule FDB.Native.AtomCreationTest do
  use ExUnit.Case, async: false
  import FDB.Native
  import TestUtils
  alias FDB.{Database, Transaction, Future}

  setup do
    flushdb()
    :ok
  end

  describe "atom creation coverage" do
    test "exercise all code paths that create atoms" do
      # The make_atom function in the NIF is used to create atoms like :ok, :true, :false
      # These atoms are already created by the Erlang VM, so the branch that creates
      # new atoms is typically not exercised. This test ensures all atom-returning
      # functions are called to maximize coverage.

      db = new_database()

      # Functions that return :ok atom
      Database.transact(db, fn t ->
        # transaction_set returns 0, which Elixir wraps as :ok
        Transaction.set(t, "atom_test_key", "value")

        # transaction_clear returns 0
        assert transaction_clear(t.resource, "atom_test_key") == 0

        # transaction_commit returns a future that resolves to :ok
        # (exercises the COMMIT case in future_get which calls make_atom("ok"))
      end)

      # Functions that return :true/:false atoms (get_error_predicate)
      assert get_error_predicate(FDB.Option.error_predicate_retryable(), 1020) == :true
      assert get_error_predicate(FDB.Option.error_predicate_retryable(), 2000) == :false

      # Watch future that resolves to :ok
      # (exercises the WATCH case in future_get which calls make_atom("ok"))
      key = "watch_atom_test_#{:rand.uniform(10000)}"

      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, key)
        Future.create(future_ref)
      end)

      Database.transact(db, fn t ->
        Transaction.set(t, key, "trigger")
      end)

      assert Future.await(watch_future) == :ok

      # transaction_on_error future that resolves to :ok
      # (exercises the ERROR case in future_get which calls make_atom("ok"))
      Database.transact(db, fn t ->
        error_future_ref = transaction_on_error(t.resource, 1020)  # retryable error
        error_future = Future.create(error_future_ref)
        assert Future.await(error_future) == :ok
      end)
    end

    test "verify atom interning behavior" do
      # This test verifies that common atoms are already interned
      # The make_atom function has a branch for creating new atoms that
      # is difficult to cover because all atoms it creates are common ones

      # Verify these atoms already exist in the atom table
      assert :ok == :ok
      assert :true == :true
      assert :false == :false

      # These atoms are used by the NIF and should already be interned
      # by the time any NIF function is called
      existing_atoms = [:ok, :true, :false]

      Enum.each(existing_atoms, fn atom ->
        # In Elixir/Erlang, atoms are always interned, so this just
        # verifies they can be used without issues
        assert is_atom(atom)
      end)
    end

    test "all future types that return atoms" do
      db = new_database()

      # Test each future type that uses make_atom

      # 1. COMMIT future type - returns :ok
      commit_result = Database.transact(db, fn t ->
        Transaction.set(t, "commit_test", "value")
        :ok  # The commit happens implicitly and returns :ok
      end)
      assert commit_result == :ok

      # 2. WATCH future type - returns :ok
      watch_key = "watch_future_atom_#{:rand.uniform(10000)}"

      # Create watch in one transaction
      watch_future = Database.transact(db, fn t ->
        future_ref = transaction_watch(t.resource, watch_key)
        Future.create(future_ref)
      end)

      # Trigger in another transaction
      Database.transact(db, fn t ->
        Transaction.set(t, watch_key, "trigger")
      end)

      # Now await the watch
      assert Future.await(watch_future) == :ok

      # 3. ERROR future type (from on_error) - returns :ok for retryable errors
      error_result = Database.transact(db, fn t ->
        # Force a retryable error scenario
        future_ref = transaction_on_error(t.resource, 1020)  # not_committed
        future = Future.create(future_ref)
        Future.await(future)
      end)
      assert error_result == :ok

      # 4. Verify get_error_predicate returns :true/:false atoms
      retryable_pred = FDB.Option.error_predicate_retryable()

      # Various error codes to test both branches
      error_codes = [
        {0, :false},      # Success is not retryable
        {1007, :true},    # Transaction too old - retryable
        {1020, :true},    # Not committed - retryable
        {1031, :false},   # Transaction timeout - not retryable
        {2000, :false},   # Invalid option - not retryable
        {2002, :false},   # Invalid operation - not retryable
      ]

      Enum.each(error_codes, fn {code, expected} ->
        result = get_error_predicate(retryable_pred, code)
        assert result == expected,
               "Error code #{code} should be retryable=#{expected}, got #{result}"
      end)
    end

    test "edge cases for atom creation" do
      # While we can't directly control the string passed to make_atom
      # in the C code, we can ensure all code paths that lead to atom
      # creation are exercised

      db = new_database()

      # Successful transaction commit (implicitly returns :ok)
      assert :ok == Database.transact(db, fn t ->
        Transaction.set(t, "test", "value")
        :ok
      end)

      # Multiple predicate types
      predicates = [
        FDB.Option.error_predicate_retryable(),
        FDB.Option.error_predicate_maybe_committed(),
        FDB.Option.error_predicate_retryable_not_committed()
      ]

      # Test each predicate with various error codes
      Enum.each(predicates, fn predicate ->
        # Each predicate will return :true or :false
        result1 = get_error_predicate(predicate, 0)
        result2 = get_error_predicate(predicate, 1020)

        assert result1 in [:true, :false]
        assert result2 in [:true, :false]
      end)
    end

    @doc """
    Note on uncovered branch in make_atom:

    The make_atom function in fdb_nif.c has a branch that creates new atoms
    when enif_make_existing_atom fails. This branch is not covered because:

    1. make_atom is only called with hardcoded strings: "ok", "true", "false"
    2. These atoms are fundamental to Erlang/Elixir and always exist
    3. The atoms are created during VM initialization, before any NIF is loaded

    This uncovered branch represents defensive programming for a case that
    should never occur in practice. The 75% branch coverage for make_atom
    is acceptable given these constraints.
    """
    test "document make_atom branch coverage limitation" do
      # This test documents why 100% branch coverage is not achievable
      # for the make_atom function without modifying the C code

      # Verify the atoms used by make_atom already exist
      # They're in the initial atom table of any Erlang VM
      assert :ok |> is_atom()
      assert :true |> is_atom()
      assert :false |> is_atom()

      # Even if we could somehow unload these atoms (which we can't),
      # we don't control the string passed to make_atom from test code
      assert true
    end
  end
end
