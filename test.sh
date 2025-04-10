#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Don't exit on error, we'll handle errors in the run_test function
set +e

# Build the binary
print_status "Building rstrict binary..."
cargo build --release
if [ $? -ne 0 ]; then
    print_error "Failed to build rstrict binary"
    exit 1
fi
print_success "Binary built successfully"

# Create test directories
TEST_DIR="test_env"
RO_DIR="$TEST_DIR/ro"
RW_DIR="$TEST_DIR/rw"
EXEC_DIR="$TEST_DIR/exec"
NESTED_DIR="$TEST_DIR/nested/path/deep"

print_status "Setting up test environment..."
rm -rf "$TEST_DIR"
mkdir -p "$RO_DIR" "$RW_DIR" "$EXEC_DIR" "$NESTED_DIR"

# Create test files
echo "readonly content" > "$RO_DIR/test.txt"
echo "readwrite content" > "$RW_DIR/test.txt"
echo "nested content" > "$NESTED_DIR/test.txt"
echo "#!/bin/bash" > "$EXEC_DIR/test.sh"
echo "echo 'executable content'" >> "$EXEC_DIR/test.sh"
chmod +x "$EXEC_DIR/test.sh"
cp $EXEC_DIR/test.sh $EXEC_DIR/test2.sh

# Create a script in RW dir to test execution in RW dirs
echo "#!/bin/bash" > "$RW_DIR/rw_script.sh"
echo "echo 'this script is in a read-write directory'" >> "$RW_DIR/rw_script.sh"
chmod +x "$RW_DIR/rw_script.sh"

# Function to run a test case
run_test() {
    local name="$1"
    local cmd="$2"
    local expected_exit="$3"
    
    print_status "Running test: $name"
    eval "$cmd"
    local exit_code=$?
    
    if [ $exit_code -eq $expected_exit ]; then
        print_success "Test passed: $name (exit code: $exit_code)"
        return 0
    else
        print_error "Test failed: $name (expected exit $expected_exit, got $exit_code)"
        exit 1
    fi
}

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    print_error "curl is not installed. Please install it to run network tests."
    exit 1
fi

# Get absolute paths
ROOT_DIR=$(pwd)
ABSOLUTE_RO_DIR="$ROOT_DIR/$RO_DIR"
ABSOLUTE_RW_DIR="$ROOT_DIR/$RW_DIR" 
ABSOLUTE_EXEC_DIR="$ROOT_DIR/$EXEC_DIR"
ABSOLUTE_NESTED_DIR="$ROOT_DIR/$NESTED_DIR"

# Basic test cases
print_status "Starting test cases..."

# Read-only access test
run_test "Read-only access to file" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro $ABSOLUTE_RO_DIR cat $ABSOLUTE_RO_DIR/test.txt" \
    0

# Write access test (should fail)
run_test "No write access to read-only directory" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro $ABSOLUTE_RO_DIR touch $ABSOLUTE_RO_DIR/new.txt" \
    1

# Write access test (should succeed)
run_test "Write access to read-write directory" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --rw $ABSOLUTE_RW_DIR touch $ABSOLUTE_RW_DIR/new.txt" \
    0

# Execute access test
run_test "Execute access with rox flag" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --rox $ABSOLUTE_EXEC_DIR $ABSOLUTE_EXEC_DIR/test.sh" \
    0

# Execute access test (should fail)
run_test "No execute access with just ro flag" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro $ABSOLUTE_EXEC_DIR $ABSOLUTE_EXEC_DIR/test.sh" \
    1

# Auto-exec test
run_test "Auto-exec flag test" \
    "./target/release/rstrict --log-level debug --add-exec --rox /usr/bin --rox /lib --rox /lib64 --ro $ROOT_DIR ls" \
    0

# Default restrictive mode
run_test "Default restrictive mode" \
    "./target/release/rstrict --log-level debug ls" \
    1

# Unrestricted filesystem
run_test "Unrestricted filesystem" \
    "./target/release/rstrict --log-level debug --unrestricted-filesystem --rox /usr/bin --rox /lib --rox /lib64 ls" \
    0

# Execute access in read-write directory
run_test "Execute access in read-write directory" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --rwx $ABSOLUTE_RW_DIR $ABSOLUTE_RW_DIR/rw_script.sh" \
    0

# No execute access in read-write directory without rwx
run_test "No execute access in read-write directory without rwx" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --rw $ABSOLUTE_RW_DIR $ABSOLUTE_RW_DIR/rw_script.sh" \
    1

# Deep directory traversal
run_test "Deep directory traversal" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro $ABSOLUTE_NESTED_DIR cat $ABSOLUTE_NESTED_DIR/test.txt" \
    0

# Multiple read paths
run_test "Multiple read paths" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro $ABSOLUTE_RO_DIR --ro $ABSOLUTE_NESTED_DIR cat $ABSOLUTE_NESTED_DIR/test.txt" \
    0

# Process creation with pipe
run_test "Process creation with pipe" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro /usr bash -c 'ls /usr | grep bin'" \
    0

# File redirection
run_test "File redirection" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro /usr --rw $ABSOLUTE_RW_DIR bash -c 'ls /usr > $ABSOLUTE_RW_DIR/output.txt && cat $ABSOLUTE_RW_DIR/output.txt'" \
    0

# Network restrictions tests
print_status "Testing network restrictions..."

# Test TCP connection without permission (should fail)
run_test "TCP connection without permission" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro /etc curl -s --connect-timeout 2 https://example.com" \
    6

# Test TCP connection with permission (should succeed)
run_test "TCP connection with permission" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro /etc --connect-tcp 443 curl -s --connect-timeout 2 https://example.com" \
    0

# Test unrestricted network access
run_test "Unrestricted network access" \
    "./target/release/rstrict --log-level debug --unrestricted-network --rox /usr/bin --rox /lib --rox /lib64 --ro /etc curl -s --connect-timeout 2 https://example.com" \
    0

# Test multiple TCP ports
run_test "Multiple TCP ports" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --ro /etc --connect-tcp 443 --connect-tcp 80 curl -s --connect-timeout 2 https://example.com" \
    0

# Test restricted and unrestricted combinations
run_test "Restricted filesystem but unrestricted network" \
    "./target/release/rstrict --log-level debug --unrestricted-network --rox /usr/bin --rox /lib --rox /lib64 --ro /etc curl -s --connect-timeout 2 https://example.com" \
    0

run_test "Unrestricted filesystem but restricted network" \
    "./target/release/rstrict --log-level debug --unrestricted-filesystem --rox /usr/bin --rox /lib --rox /lib64 curl -s --connect-timeout 2 https://example.com" \
    6

# Environment variables test
export TEST_ENV_VAR="test_value_123"
run_test "Environment isolation (no variables should be passed)" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64
 bash -c '[[ -z \$TEST_ENV_VAR ]] && echo \"No env var\" || echo \$TEST_ENV_VAR'" \
    0

run_test "Passing specific environment variable" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --env TEST_ENV_VAR bash -c 'echo \$TEST_ENV_VAR | grep \"test_value_123\"'" \
    0

run_test "Passing custom environment variable" \
    "./target/release/rstrict --log-level debug --rox /usr/bin --rox /lib --rox /lib64 --env CUSTOM_VAR=custom_value bash -c 'echo \$CUSTOM_VAR | grep \"custom_value\"'" \
    0

# Clean up
print_status "Cleaning up..."
rm -rf "$TEST_DIR"

print_success "All tests completed!"