#!/usr/bin/env bash
#
# mayhem/test.sh — runs ccextractor's upstream functional test suite: the Rust unit tests
# in src/rust (crate ccx_rust) and src/rust/lib_ccxr — the exact suite upstream CI runs in
# .github/workflows/test_rust.yml (`cargo test` in both crates). Test binaries are
# pre-compiled by mayhem/build.sh (`cargo test --no-run`); this script only runs them.
#
# The legacy C libcheck suite in tests/ is intentionally NOT run: it no longer compiles
# against the current source (stale sbs_append_string signature) and upstream CI dropped it.
#
# Runs single-threaded (--test-threads=1): the ccx_rust tests mutate shared global C-FFI
# state and SIGILL under the default parallel harness.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

export RUSTUP_HOME="${RUSTUP_HOME:-/opt/toolchains/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_NET_OFFLINE=true

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASS=0; FAIL=0; SKIP=0; RC=0
LOG=/tmp/ccx-cargo-test.log

run_suite() {
  local dir="$1"
  : > "$LOG"
  ( cd "$dir" && cargo test --offline -- --test-threads=1 ) >"$LOG" 2>&1 || RC=1
  # Sum every harness summary line: "test result: ok. N passed; M failed; K ignored; ..."
  local sums
  sums=$(grep -E '^test result:' "$LOG" | \
    sed -E 's/.* ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored.*/\1 \2 \3/' | \
    awk '{p+=$1; f+=$2; s+=$3} END {printf "%d %d %d", p+0, f+0, s+0}')
  local p f s
  read -r p f s <<<"$sums"
  if ! grep -qE '^test result:' "$LOG"; then
    echo "ERROR: no test harness summary produced in $dir" >&2
    tail -20 "$LOG" >&2
    RC=1; FAIL=$(( FAIL + 1 ))
    return
  fi
  PASS=$(( PASS + p )); FAIL=$(( FAIL + f )); SKIP=$(( SKIP + s ))
  tail -3 "$LOG"
}

echo "== upstream rust suite: src/rust (ccx_rust) =="
run_suite "$SRC/src/rust"

echo "== upstream rust suite: src/rust/lib_ccxr =="
run_suite "$SRC/src/rust/lib_ccxr"

[ "$RC" -ne 0 ] && [ "$FAIL" -eq 0 ] && FAIL=1  # cargo failed without a parsed failure

emit_ctrf "cargo-test" "$PASS" "$FAIL" "$SKIP"
