#!/bin/bash
# Rust endpoint test (macOS)
#
# Installs Rust (rustup), several toolchain versions (stable, an older stable,
# nightly) and Bazel (via Bazelisk), then downloads a tiny Rust project and
# builds, tests and runs it with each toolchain and with Bazel.
#
# Run as a normal user (NOT with sudo):
#   bash test-macos.sh
#
# Every step runs even if an earlier one fails, so the summary shows exactly
# which steps did not work.

# ---- Settings -------------------------------------------------------------
# rustup uses its own defaults (~/.rustup, ~/.cargo). To put the project
# somewhere else, set WORK_DIR, for example:
#   WORK_DIR="$HOME/RustDev"
WORK_DIR="${WORK_DIR:-$HOME/rust-endpoint-test}"
OLDER_TOOLCHAIN="${OLDER_TOOLCHAIN:-1.80.0}"
PROJECT_URL="https://github.com/sethcall/rust-endpoint-test/archive/refs/heads/main.tar.gz"
# Leave empty for Bazel's default output location (~/Library/Caches/bazel).
BAZEL_OUTPUT_USER_ROOT="${BAZEL_OUTPUT_USER_ROOT:-}"
# ---------------------------------------------------------------------------

mkdir -p "$WORK_DIR"
LOG="$WORK_DIR/rust-endpoint-test-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

RESULTS=()
FAILED=0

step() {
  local name="$1"; shift
  echo
  echo "=== [$(date -u +%H:%M:%SZ)] $name"
  echo "+ $*"
  if "$@"; then
    RESULTS+=("PASS  $name")
  else
    RESULTS+=("FAIL  $name (exit $?)")
    FAILED=$((FAILED + 1))
  fi
}

# Runs a command and checks its output contains an expected string.
expect_output() {
  local expected="$1"; shift
  local out
  out="$("$@" 2>&1)"; local rc=$?
  echo "$out"
  [ $rc -eq 0 ] || return $rc
  if ! grep -qF -- "$expected" <<<"$out"; then
    echo "Expected output to contain: $expected"
    return 1
  fi
}

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) BAZELISK_ASSET=bazelisk-darwin-arm64 ;;
  x86_64) BAZELISK_ASSET=bazelisk-darwin-amd64 ;;
  *) echo "Unsupported architecture: $ARCH"; exit 2 ;;
esac

echo "Rust endpoint test (macOS)"
echo "Host:      $(hostname)"
echo "User:      $(whoami)"
echo "OS:        $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $ARCH"
echo "Work dir:  $WORK_DIR"
echo "Log file:  $LOG"
echo "Start UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

export PATH="$HOME/.cargo/bin:$WORK_DIR/bin:$PATH"
PROJ="$WORK_DIR/rust-endpoint-test-main"

# 1. Prerequisite: Apple command line tools (provides the linker rustc uses).
step "Xcode Command Line Tools present" xcode-select -p

# 2. Install Rust with rustup (no admin rights, no shell profile changes).
install_rustup() {
  if command -v rustup >/dev/null 2>&1; then
    echo "rustup already installed; updating instead."
    rustup self update && rustup update stable
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
  fi
}
step "Install rustup + stable toolchain" install_rustup
step "rustc runs" rustc --version
step "cargo runs" cargo --version

# 3. Download the sample project (no git needed).
fetch_project() {
  rm -rf "$PROJ"
  curl -fsSL "$PROJECT_URL" | tar -xz -C "$WORK_DIR"
}
step "Download sample project" fetch_project
cd "$PROJ" || { echo "Project directory missing; later steps will fail."; }

# 4. Build, test and run with stable. build.rs and the test binary are
#    freshly compiled executables that run immediately.
step "cargo build (stable)" cargo +stable build
step "cargo test (stable)" cargo +stable test
step "cargo run (stable)" expect_output "Hello from Rust!" cargo +stable run

# 5. Install an older stable and nightly side by side, then rebuild with each.
step "Install toolchain $OLDER_TOOLCHAIN" rustup toolchain install "$OLDER_TOOLCHAIN" --profile minimal
step "cargo test ($OLDER_TOOLCHAIN)" cargo "+$OLDER_TOOLCHAIN" test
step "cargo run ($OLDER_TOOLCHAIN)" expect_output "rustc $OLDER_TOOLCHAIN" cargo "+$OLDER_TOOLCHAIN" run

step "Install toolchain nightly" rustup toolchain install nightly --profile minimal
step "cargo test (nightly)" cargo +nightly test
step "cargo run (nightly)" expect_output "-nightly" cargo +nightly run

# 6. Per-project pinning, the way real projects select a version.
step "rustup override set $OLDER_TOOLCHAIN" rustup override set "$OLDER_TOOLCHAIN"
step "cargo run (pinned via override)" expect_output "rustc $OLDER_TOOLCHAIN" cargo run
rustup override unset >/dev/null 2>&1

# 7. Directly run the built executable (as a developer would after building).
step "Run built binary directly" expect_output "Hello from Rust!" ./target/debug/rust-endpoint-test

# 8. Install Bazel via Bazelisk (reads .bazelversion), then build, test, run.
install_bazelisk() {
  mkdir -p "$WORK_DIR/bin"
  curl -fsSL -o "$WORK_DIR/bin/bazel" \
    "https://github.com/bazelbuild/bazelisk/releases/latest/download/$BAZELISK_ASSET"
  chmod +x "$WORK_DIR/bin/bazel"
}
step "Install Bazelisk" install_bazelisk

BAZEL=("$WORK_DIR/bin/bazel")
[ -n "$BAZEL_OUTPUT_USER_ROOT" ] && BAZEL+=("--output_user_root=$BAZEL_OUTPUT_USER_ROOT")

step "bazel version" "${BAZEL[@]}" version
step "bazel build //:hello" "${BAZEL[@]}" build //:hello
step "bazel test //:hello_test" "${BAZEL[@]}" test //:hello_test
step "bazel run //:hello" expect_output "Built with: Bazel rules_rust" "${BAZEL[@]}" run //:hello
"${BAZEL[@]}" shutdown >/dev/null 2>&1

# ---- Summary --------------------------------------------------------------
echo
echo "End UTC:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "================ SUMMARY ================"
printf '%s\n' "${RESULTS[@]}"
echo "========================================="
if [ "$FAILED" -eq 0 ]; then
  echo "All ${#RESULTS[@]} steps PASSED on this host."
else
  echo "$FAILED of ${#RESULTS[@]} steps FAILED. TEST FAILED."
fi
echo "Log saved to: $LOG"
exit "$FAILED"
