#!/bin/bash

# Exit immediately if a command exits with a non-zero status during setup.
set -e

# --- Configuration ---
RSTRICT_BIN="./target/release/rstrict"
TEST_DIR="_test_env" # Use underscore to avoid potential name clashes

# --- Check for Linux ---
if [ "$(uname -s)" != "Linux" ]; then
    echo -e "${YELLOW}Warning: This script is designed to run on Linux only.${NC}"
    echo -e "${YELLOW}Tests will be skipped on this platform.${NC}"
    exit 0
fi

# Kernel version check (informational only)
KERNEL_VERSION=$(uname -r)
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

echo -e "${CYAN}Running on Linux kernel ${KERNEL_VERSION}${NC}"
if [ "$KERNEL_MAJOR" -lt 5 ] || ([ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -lt 13 ]); then
    echo -e "${YELLOW}Note: Some tests may fail on kernel < 5.13 due to limited Landlock support${NC}"
    echo -e "${YELLOW}Continuing with tests anyway...${NC}"
fi

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_section() {
    echo -e "\n${CYAN}==== $1 ====${NC}"
}

# Initialize test failures count and results log
TEST_FAILURES=0
# Ensure a clean test results log
echo "# Test Results - $(date)" > _test_results.log

print_status() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    # Log the success for CI to parse
    echo "[PASS] $1" >> _test_results.log
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    # Add to test failures count (used in CI)
    TEST_FAILURES=$((TEST_FAILURES+1))
    # Log the failure for CI to parse
    echo "[FAIL] $1" >> _test_results.log
}

# Function to run a test case
# Usage: run_test "Test Name" EXPECTED_EXIT_CODE "command" "arg1" "arg2" ...
run_test() {
    local name="$1"
    local expected_exit="$2"
    shift 2 # Remove name and expected_exit from arguments
    local cmd_str="$*" # Keep the command string representation for printing

    print_status "$name"
    echo -e "       Running: ${cmd_str}"

    # Disable exit on error for the command execution only
    set +e
    "$@" # Execute the command with proper argument separation
    local exit_code=$?
    set -e # Re-enable exit on error

    if [ $exit_code -eq $expected_exit ]; then
        print_success "$name (Expected Exit: $expected_exit, Got: $exit_code)"
        return 0
    else
        print_fail "$name (Expected Exit: $expected_exit, Got: $exit_code)"
        # Don't exit, just track the failure and continue
        return 0
    fi
}

# --- Setup ---
print_section "Setup"

echo "Building rstrict binary..."
cargo build --release
if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed.${NC}"
    exit 1
fi
echo "Build successful."

echo "Creating test environment in $TEST_DIR..."
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/ro_dir" \
         "$TEST_DIR/rw_dir" \
         "$TEST_DIR/rox_dir" \
         "$TEST_DIR/rwx_dir" \
         "$TEST_DIR/nested/deep"

# Create test files and scripts
echo "read_only_file_content" > "$TEST_DIR/ro_file.txt"
echo "read_write_file_content" > "$TEST_DIR/rw_file.txt"
echo "read_only_dir_content" > "$TEST_DIR/ro_dir/ro_in_dir.txt"
echo "read_write_dir_content" > "$TEST_DIR/rw_dir/rw_in_dir.txt"
echo "nested_content" > "$TEST_DIR/nested/deep/nested.txt"

# Script that should only be executable
cat << EOF > "$TEST_DIR/exec_script.sh"
#!/bin/bash
echo "EXECUTABLE SCRIPT OUTPUT"
exit 0
EOF
chmod +x "$TEST_DIR/exec_script.sh"

# Script placed in a R-O directory (shouldn't be executable with just --ro)
cp "$TEST_DIR/exec_script.sh" "$TEST_DIR/ro_dir/nonexec_script.sh"
chmod +x "$TEST_DIR/ro_dir/nonexec_script.sh" # Mark executable, but rstrict should block

# Script placed in a R-W directory (shouldn't be executable with just --rw)
cp "$TEST_DIR/exec_script.sh" "$TEST_DIR/rw_dir/nonexec_script.sh"
chmod +x "$TEST_DIR/rw_dir/nonexec_script.sh" # Mark executable, but rstrict should block

# Script placed in ROX dir
cp "$TEST_DIR/exec_script.sh" "$TEST_DIR/rox_dir/rox_script.sh"
chmod +x "$TEST_DIR/rox_dir/rox_script.sh"

# Script placed in RWX dir
cp "$TEST_DIR/exec_script.sh" "$TEST_DIR/rwx_dir/rwx_script.sh"
chmod +x "$TEST_DIR/rwx_dir/rwx_script.sh"

# Get absolute paths (needed for Landlock rules)
ABS_TEST_DIR=$(realpath "$TEST_DIR")
ABS_RO_FILE="$ABS_TEST_DIR/ro_file.txt"
ABS_RW_FILE="$ABS_TEST_DIR/rw_file.txt"
ABS_RO_DIR="$ABS_TEST_DIR/ro_dir"
ABS_RW_DIR="$ABS_TEST_DIR/rw_dir"
ABS_ROX_DIR="$ABS_TEST_DIR/rox_dir"
ABS_RWX_DIR="$ABS_TEST_DIR/rwx_dir"
ABS_EXEC_SCRIPT="$ABS_TEST_DIR/exec_script.sh"
ABS_NESTED_DIR="$ABS_TEST_DIR/nested" # Grant access to parent for nested test

echo "Test environment ready."

# --- Test Cases ---
TEST_FAILURES=0

# == Basic Execution & Default Restrictions ==
print_section "Basic Execution & Default Restrictions"
run_test "Execute 'true' with essential access" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd -- \
    true
run_test "Execute 'echo' with essential access" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd -- \
    echo "Test"
run_test "Execute 'ls' without ANY explicit permissions (should fail)" 1 \
    "$RSTRICT_BIN" --log-level error -- \
    ls # Fails because ls binary itself cannot be read/executed

# == Read-Only (--ro) Tests ==
print_section "Read-Only (--ro) Tests"
run_test "Read allowed file (--ro file)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_RO_FILE" -- \
    cat "$ABS_RO_FILE"
run_test "Write denied file (--ro file)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_RO_FILE" -- \
    bash -c "echo 'test' > $ABS_RO_FILE" # Use bash to attempt redirection

run_test "Read allowed dir contents (--ro dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_RO_DIR" -- \
    ls "$ABS_RO_DIR"
run_test "Read allowed file within dir (--ro dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_RO_DIR" -- \
    cat "$ABS_RO_DIR/ro_in_dir.txt"
run_test "Write denied within dir (--ro dir)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_RO_DIR" -- \
    touch "$ABS_RO_DIR/new_file.txt"
run_test "Execute denied script within dir (--ro dir)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_RO_DIR" -- \
    "$ABS_RO_DIR/nonexec_script.sh"

# == Read-Write (--rw) Tests ==
print_section "Read-Write (--rw) Tests"
run_test "Read allowed file (--rw file)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_RW_FILE" -- \
    cat "$ABS_RW_FILE"
run_test "Read allowed dir contents (--rw dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_RW_DIR" -- \
    ls "$ABS_RW_DIR"
run_test "Write allowed within dir (--rw dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_RW_DIR" -- \
    touch "$ABS_RW_DIR/new_rw_file.txt"
run_test "Read file created within dir (--rw dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_RW_DIR" -- \
    cat "$ABS_RW_DIR/new_rw_file.txt"
run_test "Remove file within dir (--rw dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_RW_DIR" -- \
    rm "$ABS_RW_DIR/new_rw_file.txt"
run_test "Execute denied script within dir (--rw dir)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_RW_DIR" -- \
    "$ABS_RW_DIR/nonexec_script.sh"

# == Read-Execute (--rox) Tests ==
print_section "Read-Execute (--rox) Tests"
run_test "Execute allowed script (--rox file)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rox "$ABS_EXEC_SCRIPT" -- \
    bash "$ABS_EXEC_SCRIPT"
run_test "Read allowed script (--rox file)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rox "$ABS_EXEC_SCRIPT" -- \
    cat "$ABS_EXEC_SCRIPT"
run_test "Write denied script (--rox file)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rox "$ABS_EXEC_SCRIPT" -- \
    bash -c "echo 'no write' >> $ABS_EXEC_SCRIPT"

run_test "Read allowed dir contents (--rox dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rox "$ABS_ROX_DIR" -- \
    ls "$ABS_ROX_DIR"
run_test "Execute allowed script within dir (--rox dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rox "$ABS_ROX_DIR" -- \
    bash "$ABS_ROX_DIR/rox_script.sh"
run_test "Write denied within dir (--rox dir)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rox "$ABS_ROX_DIR" -- \
    touch "$ABS_ROX_DIR/new_file.txt"

# == Read-Write-Execute (--rwx) Tests ==
print_section "Read-Write-Execute (--rwx) Tests"
run_test "Read allowed dir contents (--rwx dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rwx "$ABS_RWX_DIR" -- \
    ls "$ABS_RWX_DIR"
run_test "Write allowed within dir (--rwx dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rwx "$ABS_RWX_DIR" -- \
    touch "$ABS_RWX_DIR/new_rwx_file.txt"
run_test "Execute allowed script within dir (--rwx dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rwx "$ABS_RWX_DIR" -- \
    bash "$ABS_RWX_DIR/rwx_script.sh"
run_test "Modify executable script within dir (--rwx dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rwx "$ABS_RWX_DIR" -- \
    bash -c "echo '# new line' >> $ABS_RWX_DIR/rwx_script.sh"

# == Helper Flag Tests ==
print_section "Helper Flag Tests (--add-exec, --ldd)"
# --add-exec is implicitly tested in most cases above
run_test "--add-exec basic test ('ls' needs implicit libs)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro / -- \
    ls / # Allow reading root dir content just to see output
# Test --ldd (implicitly used above, difficult to isolate perfectly without specific binaries)
# This test relies on `ls` needing libs that --ldd provides access to
run_test "--ldd allows dynamically linked binary ('ls')" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro / -- \
    ls /

# == Nested Path Tests ==
print_section "Nested Path Tests"
run_test "Read nested file (--ro parent dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_NESTED_DIR" -- \
    cat "$ABS_NESTED_DIR/deep/nested.txt"
run_test "Write denied nested file (--ro parent dir)" 1 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --ro "$ABS_NESTED_DIR" -- \
    touch "$ABS_NESTED_DIR/deep/new_nested.txt"
run_test "Write allowed nested file (--rw parent dir)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --rw "$ABS_NESTED_DIR" -- \
    touch "$ABS_NESTED_DIR/deep/new_nested_rw.txt"

# == Unrestricted Tests ==
print_section "Unrestricted Flag Tests"
run_test "Unrestricted filesystem allows writing anywhere (potentially dangerous!)" 0 \
    "$RSTRICT_BIN" --log-level error --unrestricted-filesystem --add-exec --ldd -- \
    touch "$ABS_TEST_DIR/unrestricted_fs_test.txt"
# Network test for unrestricted below

# == Network Tests (Curl) ==
print_section "Network Tests (Curl)"
# Check curl exists
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}[SKIP] curl not found, skipping network tests.${NC}"
else
    # Use specific curl options for testing:
    # --head: Fetch only headers
    # --fail: Return error on HTTP >= 400
    # -sS: Silent mode, but show errors
    # --connect-timeout 5: Fail faster if connection blocked
    CURL_CMD=(curl --head --fail -sS --connect-timeout 5 https://example.com)

    # Define common necessary --ro paths for curl DNS/TLS
    CURL_FS_RO=(--ro /etc/resolv.conf --ro /etc/nsswitch.conf --ro /etc/hosts --ro /etc/ssl/certs)

    run_test "Network: Curl fails (No FS rules for DNS/TLS config)" 6 \
        "$RSTRICT_BIN" --log-level error --add-exec --ldd -- \
        "${CURL_CMD[@]}" # curl exit 6: Couldn't resolve host
    run_test "Network: Curl fails (FS rules OK, No TCP connect permission)" 7 \
        "$RSTRICT_BIN" --log-level error --add-exec --ldd "${CURL_FS_RO[@]}" -- \
        "${CURL_CMD[@]}" # curl exit 7: Failed to connect() to host or proxy.
    run_test "Network: Curl fails (FS rules OK, Wrong TCP port allowed)" 7 \
        "$RSTRICT_BIN" --log-level error --add-exec --ldd "${CURL_FS_RO[@]}" --connect-tcp 80 -- \
        "${CURL_CMD[@]}" # Still exit 7, blocked on port 443
    run_test "Network: Curl succeeds (FS rules OK, Correct TCP port allowed)" 0 \
        "$RSTRICT_BIN" --log-level error --add-exec --ldd "${CURL_FS_RO[@]}" --connect-tcp 443 -- \
        "${CURL_CMD[@]}" # Should succeed
    run_test "Network: Curl succeeds (--unrestricted-network)" 0 \
        "$RSTRICT_BIN" --log-level error --add-exec --ldd "${CURL_FS_RO[@]}" --unrestricted-network -- \
        "${CURL_CMD[@]}" # Should succeed
fi

# == Environment Variable Tests ==
print_section "Environment Variable Tests"
export TEST_OUTSIDE_VAR="value_outside"

run_test "Env: Variable isolation (bash -c check)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd -- \
    bash -c 'if [ -z "$TEST_OUTSIDE_VAR" ]; then exit 0; else echo "Env: Variable isolation (bash -c) FAILED: Expected unset, got '\''$TEST_OUTSIDE_VAR'\''."; exit 1; fi'

run_test "Env: Inherit variable (--env VAR)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --env TEST_OUTSIDE_VAR -- \
    bash -c 'if [ "$TEST_OUTSIDE_VAR" == "value_outside" ]; then exit 0; else echo "Env: Inherit FAILED: Expected '\''value_outside'\'', got '\''$TEST_OUTSIDE_VAR'\''."; exit 1; fi'

run_test "Env: Set variable (--env KEY=VALUE)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --env TEST_SET_VAR=value_inside -- \
    bash -c 'if [ "$TEST_SET_VAR" == "value_inside" ]; then exit 0; else echo "Env: Set FAILED: Expected '\''value_inside'\'', got '\''$TEST_SET_VAR'\''."; exit 1; fi'

run_test "Env: Set variable overrides inherited (--env VAR --env VAR=val)" 0 \
    "$RSTRICT_BIN" --log-level error --add-exec --ldd --env TEST_OUTSIDE_VAR --env TEST_OUTSIDE_VAR=override -- \
    bash -c 'if [ "$TEST_OUTSIDE_VAR" == "override" ]; then exit 0; else echo "Env: Override FAILED: Expected '\''override'\'', got '\''$TEST_OUTSIDE_VAR'\''."; exit 1; fi'

# --- Final Summary ---
print_section "Summary"

echo "Test script finished with $TEST_FAILURES failures."

# --- Cleanup ---
print_section "Cleanup"
echo "Removing test environment $TEST_DIR..."
rm -rf "$TEST_DIR"
echo "Cleanup complete."

# Add summary to test results log file
PASSED_COUNT=$(grep -c "\[PASS\]" _test_results.log || echo "0")
TOTAL_COUNT=$((PASSED_COUNT + TEST_FAILURES))
echo "" >> _test_results.log
echo "# Summary: $PASSED_COUNT/$TOTAL_COUNT tests passed, $TEST_FAILURES failures" >> _test_results.log
if [ "$TEST_FAILURES" -gt 0 ]; then
    echo "# Failed tests:" >> _test_results.log
    grep "\[FAIL\]" _test_results.log | sed 's/\[FAIL\]/  /' >> _test_results.log
fi

# Final test results and detailed summary for terminal output
if [ "$TEST_FAILURES" -gt 0 ]; then
    echo -e "${RED}FAILED: Tests completed with $TEST_FAILURES failures.${NC}"
    echo
    echo -e "${RED}Failed tests:${NC}"
    grep "\[FAIL\]" _test_results.log | sed 's/\[FAIL\]/  /'
    echo
    exit 1
else
    echo -e "${GREEN}SUCCESS: All tests passed successfully!${NC}"
    exit 0
fi
