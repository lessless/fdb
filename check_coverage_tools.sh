#!/bin/bash

echo "Checking for C code coverage tools..."
echo "====================================="
echo ""

# Function to check if a command exists
check_command() {
    local cmd=$1
    local description=$2

    if command -v $cmd >/dev/null 2>&1; then
        echo "✓ $cmd: Found"
        $cmd --version 2>&1 | head -n 1 | sed 's/^/  /'
        return 0
    else
        echo "✗ $cmd: Not found"
        echo "  $description"
        return 1
    fi
    echo ""
}

# Check for GCC and gcov
echo "GCC-based coverage tools:"
echo "------------------------"
check_command gcc "Install GCC: brew install gcc (macOS) or apt-get install gcc (Linux)"
check_command gcov "Usually comes with GCC"
check_command lcov "Install: brew install lcov (macOS) or apt-get install lcov (Linux)"
check_command genhtml "Usually comes with lcov"
echo ""

# Check for Clang and llvm-cov
echo "LLVM-based coverage tools:"
echo "-------------------------"
check_command clang "Install: brew install llvm (macOS) or apt-get install clang (Linux)"
check_command llvm-cov "Usually comes with LLVM/Clang"
check_command llvm-profdata "Usually comes with LLVM/Clang"
echo ""

# Summary and recommendations
echo "Summary:"
echo "--------"

gcov_available=false
llvm_available=false

if command -v gcov >/dev/null 2>&1; then
    gcov_available=true
    echo "• gcov is available - you can use: make -f Makefile.coverage coverage-report"
    if command -v lcov >/dev/null 2>&1; then
        echo "  └─ lcov is also available for HTML reports"
    else
        echo "  └─ Install lcov for better HTML reports"
    fi
fi

if command -v llvm-cov >/dev/null 2>&1 && command -v llvm-profdata >/dev/null 2>&1; then
    llvm_available=true
    echo "• llvm-cov is available - you can use: make -f Makefile.coverage coverage-llvm"
fi

if ! $gcov_available && ! $llvm_available; then
    echo "• No coverage tools found. Install GCC or Clang to enable coverage analysis."
fi

echo ""
echo "For detailed usage, run: make -f Makefile.coverage coverage-help"
