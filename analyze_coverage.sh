#!/bin/bash

# Script to analyze C code coverage in detail
# Usage: ./analyze_coverage.sh

set -e

echo "FoundationDB NIF C Code Coverage Analysis"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if coverage files exist
if [ ! -f "priv/fdb_nif_coverage.so-fdb_nif.gcda" ]; then
    echo -e "${RED}Error: Coverage data not found. Run 'make -f Makefile.coverage coverage-report' first.${NC}"
    exit 1
fi

# Run gcov with branch coverage
echo "Generating coverage report..."
gcov -b -o priv/fdb_nif_coverage.so-fdb_nif.gcda c_src/fdb_nif.c > coverage_summary.txt 2>&1

# Extract overall statistics
echo -e "\n${GREEN}Overall Coverage Statistics:${NC}"
echo "----------------------------"
grep "Lines executed:" coverage_summary.txt | grep "fdb_nif.c"
grep "Branches executed:" coverage_summary.txt | grep -A1 "fdb_nif.c" | tail -1
echo ""

# Analyze uncovered functions
echo -e "${YELLOW}Uncovered Functions:${NC}"
echo "-------------------"

# Extract function names that are not covered (lines starting with ##### followed by function definition)
awk '
/^#####:.*\(.*\).*{/ {
    # Extract function name
    match($0, /[a-zA-Z_][a-zA-Z0-9_]*\s*\(/)
    if (RSTART > 0) {
        func = substr($0, RSTART, RLENGTH-1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", func)
        print "  • " func
    }
}
' fdb_nif.c.gcov | sort -u

echo ""

# Analyze partially covered functions
echo -e "${YELLOW}Partially Covered Functions (with uncovered lines):${NC}"
echo "--------------------------------------------------"

# Find functions with both covered and uncovered lines
awk '
BEGIN { in_function = 0; current_function = ""; has_covered = 0; has_uncovered = 0 }
/^[[:space:]]*[0-9]+:.*\(.*\).*{/ || /^[[:space:]]*-:.*\(.*\).*{/ {
    if (in_function && has_covered && has_uncovered) {
        print "  • " current_function
    }
    # Extract new function name
    match($0, /[a-zA-Z_][a-zA-Z0-9_]*\s*\(/)
    if (RSTART > 0) {
        current_function = substr($0, RSTART, RLENGTH-1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_function)
    }
    in_function = 1
    has_covered = 0
    has_uncovered = 0
}
/^[[:space:]]*[0-9]+:/ && in_function { has_covered = 1 }
/^[[:space:]]*#####:/ && in_function { has_uncovered = 1 }
/^[[:space:]]*}/ && in_function {
    if (has_covered && has_uncovered) {
        print "  • " current_function
    }
    in_function = 0
}
END {
    if (in_function && has_covered && has_uncovered) {
        print "  • " current_function
    }
}
' fdb_nif.c.gcov | sort -u

echo ""

# Analyze error handling coverage
echo -e "${YELLOW}Error Handling Coverage:${NC}"
echo "-----------------------"

# Look for VERIFY macros and error returns that might not be covered
echo "Uncovered VERIFY calls:"
grep -n "^#####:.*VERIFY" fdb_nif.c.gcov | while read line; do
    line_num=$(echo "$line" | cut -d: -f2)
    code=$(echo "$line" | cut -d: -f3-)
    echo "  Line $line_num: $code"
done | head -10

echo ""
echo "Uncovered error returns:"
grep -n "^#####:.*return.*error" fdb_nif.c.gcov | while read line; do
    line_num=$(echo "$line" | cut -d: -f2)
    code=$(echo "$line" | cut -d: -f3-)
    echo "  Line $line_num: $code"
done | head -10

echo ""

# Summary of coverage gaps
echo -e "${GREEN}Coverage Gap Summary:${NC}"
echo "--------------------"

# Count different types of uncovered code
uncovered_lines=$(grep -c "^#####:" fdb_nif.c.gcov || true)
total_lines=$(grep -c "^[[:space:]]*[0-9#-]*:" fdb_nif.c.gcov || true)
covered_percent=$(awk "BEGIN {printf \"%.2f\", (1 - $uncovered_lines / $total_lines) * 100}")

echo "Total uncovered lines: $uncovered_lines"
echo "Coverage percentage: $covered_percent%"
echo ""

# Identify which NIF functions need more testing
echo -e "${YELLOW}NIF Functions Needing More Test Coverage:${NC}"
echo "----------------------------------------"

# Map function names to their test recommendations
declare -A function_recommendations=(
    ["get_max_api_version"]="Already tested in native_test.exs"
    ["option_inspect"]="Test with invalid option structures"
    ["future_get"]="Test KEYVALUE_ARRAY future type (range queries)"
    ["reference_resource_create"]="Test reference chaining scenarios"
    ["stop_network"]="Test network stop error conditions"
)

for func in $(awk '/^#####:.*\(.*\).*{/ {match($0, /[a-zA-Z_][a-zA-Z0-9_]*\s*\(/); if (RSTART > 0) {func = substr($0, RSTART, RLENGTH-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", func); print func}}' fdb_nif.c.gcov | sort -u); do
    if [[ -n "${function_recommendations[$func]}" ]]; then
        echo "  • $func: ${function_recommendations[$func]}"
    else
        echo "  • $func: Add test coverage"
    fi
done

echo ""
echo -e "${GREEN}Recommendations:${NC}"
echo "----------------"
echo "1. Add tests for range query operations (KEYVALUE_ARRAY futures)"
echo "2. Test error paths in option_inspect function"
echo "3. Add tests for reference chaining in complex scenarios"
echo "4. Test network lifecycle edge cases"
echo "5. Add stress tests for memory management paths"

# Clean up
rm -f coverage_summary.txt

echo ""
echo "Detailed coverage report: fdb_nif.c.gcov"
echo "To view uncovered lines: grep '^#####:' fdb_nif.c.gcov"
