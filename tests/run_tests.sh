#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "==================================="
echo "PureStorage Plugin Test Suite"
echo "==================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Test::More is available
if ! perl -MTest::More -e 'print "OK\n"' 2>/dev/null | grep -q OK; then
    echo -e "${RED}Error: Test::More module not found${NC}"
    echo "Please install it with: cpan Test::More"
    exit 1
fi

# Check if JSON is available
if ! perl -MJSON -e 'print "OK\n"' 2>/dev/null | grep -q OK; then
    echo -e "${YELLOW}Warning: JSON module not found${NC}"
    echo "Some tests may fail. Install with: cpan JSON"
fi

echo -e "${GREEN}Running Unit Tests${NC}"
echo "-----------------------------------"

failed_tests=0
total_tests=0

# Run all test files in tests/unit/
for test_file in tests/unit/*.t; do
    if [ -f "$test_file" ]; then
        total_tests=$((total_tests + 1))
        echo ""
        echo -e "${YELLOW}Running: $(basename $test_file)${NC}"

        if perl -I. "$test_file"; then
            echo -e "${GREEN}✓ PASS${NC}"
        else
            echo -e "${RED}✗ FAIL${NC}"
            failed_tests=$((failed_tests + 1))
        fi
    fi
done

echo ""
echo "==================================="
echo "Test Summary"
echo "==================================="
echo "Total tests: $total_tests"
echo -e "${GREEN}Passed: $((total_tests - failed_tests))${NC}"

if [ $failed_tests -gt 0 ]; then
    echo -e "${RED}Failed: $failed_tests${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
