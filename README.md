# rstrict

A lightweight, secure sandbox for running Linux processes using the Linux kernel's [Landlock LSM](https://docs.kernel.org/userspace-api/landlock.html), implemented in Rust with the excellent [`landlock-rs`](https://docs.rs/landlock/latest/landlock/) crate.

**rstrict** leverages the Linux **Landlock** security module to sandbox processes, allowing you to run commands with restricted access to the filesystem and network, reducing the potential impact of vulnerabilities or unintended actions.

## Features

*   **Kernel-level Security:** Uses the Linux Landlock LSM for enforcement.
*   **Lightweight:** Minimal overhead compared to VMs or heavier container solutions.
*   **Fine-grained Filesystem Control:** Allow read-only (`--ro`), read-write (`--rw`), read-execute (`--rox`), or read-write-execute (`--rwx`) access recursively beneath specified paths.
*   **TCP Network Control:** Allow binding (`--bind-tcp`) or connecting (`--connect-tcp`) to specific TCP ports. **(Important:** Landlock network rules currently **only restrict TCP** bind/connect. **UDP, ICMP, and other protocols are NOT restricted** by these rules.)
*   **Helper Flags:** Simplify common tasks with `--add-exec` (allow executable itself), `--ldd` (allow library dependencies), and `--env` (manage environment variables).
*   **Configurable Logging:** Adjust verbosity for diagnostics.

## Requirements

*   **Linux Kernel:**
    *   **5.13+** for basic Landlock filesystem sandboxing.
    *   **5.19+** recommended for network sandboxing support (used by `landlock-rs` 0.4.1+). *(Note: Your code might depend on specific ABI features available in later kernels; adjust if necessary based on `landlock-rs` version used)*.
*   **Rust Toolchain:** (Version depends on dependencies, typically the latest stable is recommended for building from source).
*   **`ldd` command:** Required *only* if using the `--ldd` helper flag.

## Installation

### From Crates.io (Recommended)

```bash
cargo install rstrict
```

### From Source

1.  Clone the repository:
    ```bash
    git clone https://github.com/creslinux/rstrict.git
    cd rstrict
    ```
2.  Build the release binary:
    ```bash
    cargo build --release
    ```
3.  The binary will be located at `target/release/rstrict`. You can copy it to a location in your `$PATH`:
    ```bash
    sudo cp target/release/rstrict /usr/local/bin/
    ```

## Usage

The basic command structure is:

```bash
rstrict [OPTIONS] -- <COMMAND> [COMMAND_ARGS...]
```

*   `[OPTIONS]`: Flags to configure the sandbox rules (see below).
*   `--`: **Recommended:** Separates `rstrict` options from the command you want to run.
*   `<COMMAND>`: The command to execute inside the sandbox.
*   `[COMMAND_ARGS...]`: Arguments for the command being executed.

### Options

**Filesystem Access:**

*   `--ro <PATH>`: Allow read-only access to the specified file or directory path (recursive). Can be used multiple times.
*   `--rw <PATH>`: Allow read-write access to the specified file or directory path (recursive). Can be used multiple times.
*   `--rox <PATH>`: Allow read-only *and* execute access to the specified file or directory path (recursive). Needed for executables, libraries, scripts. Can be used multiple times.
*   `--rwx <PATH>`: Allow read-write *and* execute access to the specified file or directory path (recursive). Can be used multiple times.

**Network Access (TCP Only):**

*   `--bind-tcp <PORT>`: Allow binding to the specified TCP port. Can be used multiple times.
*   `--connect-tcp <PORT>`: Allow making outgoing TCP connections *only* to the specified port. Can be used multiple times.

**Helper Flags:**

*   `--add-exec`: Automatically find `<COMMAND>` in `$PATH` and add it to the `--rox` list. Highly recommended.
*   `--ldd`: Run `ldd` on `<COMMAND>` to find shared library dependencies. Adds the libraries and common system library directories (like `/lib`, `/usr/lib`) to the `--rox` list. **Requires `ldd` to be installed.** This is a convenience flag; manual `--rox` rules are more precise.
*   `--env <VAR>`: Specify environment variables for the sandboxed process.
    *   `--env KEY=VALUE`: Sets the variable `KEY` to `VALUE`.
    *   `--env KEY`: Inherits the value of `KEY` from `rstrict`'s current environment.
    *   Can be used multiple times.

**Unrestricted Access:**

*   `--unrestricted-filesystem`: Disable Landlock filesystem rules. The process will have normal filesystem permissions.
*   `--unrestricted-network`: Disable Landlock network (TCP) rules. The process will have normal TCP network permissions. **Note:** This does not affect other protocols like UDP which are unrestricted by Landlock anyway.

**Logging & Meta:**

*   `--log-level <LEVEL>`: Set logging verbosity. Options: `error` (default), `warn`, `info`, `debug`, `trace`.
*   `--help`: Show help message and exit.
*   `--version`: Show version information and exit.

## Permissions Explained

Landlock operates on a "deny-by-default" principle within the scope of accesses it handles (currently filesystem and TCP network). When you enable Landlock (by providing any restriction rule or not using the `--unrestricted-*` flags), the process loses permissions for the controlled operations *except* those explicitly granted.

*   **Filesystem:**
    *   Access rights (`ReadFile`, `WriteFile`, `Execute`) are granted recursively via `PathBeneath`.
    *   Directory access rights (`ReadDir`, `RemoveDir`, `MakeDir`, `RemoveFile`, etc.) are automatically included based on whether read or write access is granted to the directory path.
    *   **Libraries (`.so` files) and the dynamic loader (`ld.so`) require `Execute` permission**, just like the main executable. `--rox` or `--rwx` must be used for paths containing them.
*   **Network (TCP Only):**
    *   Landlock gates the `bind()` and `connect()` syscalls for TCP sockets (IPv4/IPv6).
    *   **UDP traffic, ICMP (ping), UNIX domain sockets, raw sockets, etc., are NOT restricted by Landlock network rules as implemented in `rstrict`.** A process denied TCP connections can still send/receive UDP packets (e.g., for DNS) if otherwise permitted by the system.

## Examples

**1. Running `ls` with minimal read access:**

```bash
# --add-exec finds /bin/ls and adds it as --rox
# --ldd finds libc.so etc. and adds them/their dirs as --rox
# Grant read-only access needed to view attributes within /bin
rstrict --log-level info \
        --ro /bin \
        --add-exec \
        --ldd \
        -- \
        ls -l /bin/bash
```
*Output should show details for `/bin/bash`. Trying `ls -l /tmp` would fail with a permission error.*

**2. Running `curl` to fetch a webpage (HTTPS):**

This requires TCP network access (port 443), filesystem access for DNS configuration, and filesystem access for CA certificates.

```bash
rstrict --log-level info \
        --add-exec \
        --ldd \
        --ro /etc/resolv.conf \
        --ro /etc/nsswitch.conf \
        --ro /etc/hosts \
        --ro /etc/ssl/certs \
        --connect-tcp 443 \
        -- \
        curl https://example.com
```

*   `--add-exec`, `--ldd`: Allow `curl` and its libraries to run.
*   `--ro /etc/resolv.conf`, etc.: Allow `curl` (via libc) to read system DNS configuration files. **This allows the DNS resolver to work.**
*   `--ro /etc/ssl/certs`: Allow `curl` to read trusted Certificate Authority certificates to verify the HTTPS connection. (Path might vary slightly by distribution).
*   `--connect-tcp 443`: Allow `curl` to make an outgoing **TCP** connection to port 443 (HTTPS).
*   **Note:** The actual DNS lookup likely uses **UDP** port 53. This traffic is **not** blocked by `rstrict`'s Landlock rules, as they only apply to TCP. Therefore, DNS resolution succeeds, and only the subsequent TCP connection to port 443 is explicitly controlled and allowed by the `--connect-tcp` rule.

*If you changed `--connect-tcp 443` to `--connect-tcp 442`, `curl` would fail with a TCP connection error. If you removed the `--ro /etc/...` rules, `curl` would fail with a DNS resolution error.*

**3. Allowing write access to a specific directory:**

```bash
# Create a temporary directory first
mkdir ./my_temp_data

# Run touch inside the sandbox, allowing write access to ./my_temp_data
rstrict --log-level info \
        --rw ./my_temp_data \
        --add-exec \
        --ldd \
        -- \
        touch ./my_temp_data/test_file.txt

# Check if the file was created
ls ./my_temp_data
```
*Output should show `test_file.txt`.*

**4. Passing Environment Variables:**

```bash
rstrict --log-level info \
        --env GREETING="Hello Sandbox" \
        --env USER \
        --add-exec \
        --ldd \
        -- \
        sh -c 'echo "$GREETING | Current user: $USER"'
```
*Output should show `Hello Sandbox | Current user: your_username`.*

## How it Works

1.  `rstrict` parses its command-line arguments to build a sandbox configuration.
2.  It resolves paths and potentially runs `ldd` if requested (`--ldd`).
3.  It uses the excellent **[`landlock-rs`](https://docs.rs/landlock/latest/landlock/index.html)** crate to interact with the Linux kernel's Landlock API. This crate provides safe and ergonomic bindings to the underlying syscalls.
4.  It defines the access rights it wants to handle (Filesystem Read/Write/Execute, Network TCP Bind/Connect).
5.  It creates a Landlock "ruleset".
6.  It adds rules to the ruleset based on the command-line options (e.g., `PathBeneath` rules for filesystem paths, `NetPort` rules for TCP ports).
7.  It calls `restrict_self()` to apply the Landlock ruleset to the current `rstrict` process.
8.  Crucially, Landlock rules are inherited on `fork()` and **persist across `execve()`**.
9.  `rstrict` then uses the `execvpe` syscall (via the `nix` crate) to replace its own process image with the target `<COMMAND>`, passing along any specified environment variables.
10. The target `<COMMAND>` starts running *already confined* by the Landlock rules applied in step 7.

## Limitations

*   **Linux Only:** Landlock is a Linux-specific kernel feature. `rstrict` will not work on other operating systems (Windows, macOS, BSD).
*   **Kernel Version:** Requires a Linux kernel supporting Landlock. See "Requirements" section for specifics. If Landlock is unsupported or specific features are missing, restrictions may not be fully enforced (check logs).
*   **`--ldd` Dependency:** The `--ldd` flag requires the `ldd` command-line tool to be present and executable. Output parsing might be fragile.
*   **Network Restrictions (TCP Only):** Landlock network rules currently only apply to TCP `bind()` and `connect()`. **UDP, ICMP, etc., are not restricted.** This means DNS lookups over UDP will typically succeed even if TCP connections are blocked.
*   **No UID/GID Changes:** `rstrict` does not change user or group IDs. It relies solely on Landlock for confinement within the existing user context.

## Contributing

Contributions (bug reports, feature requests, pull requests) are welcome! Please open an issue on the GitHub repository to discuss changes.

## License

This project is licensed under the **MIT License**.
