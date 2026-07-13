#!/usr/bin/env bash
# Air-gapped, re-runnable build for the ccextractor commit image.
# Builds: (a) the in-process libFuzzer harness (target "ccextractor") over the
#         mature pure-C demux/decode pipeline (-DDISABLE_RUST), (b) a standalone
#         run-once reproducer for the same harness, (c) the Rust static lib the
#         C code links against, and (d) the pre-compiled upstream Rust test
#         binaries that mayhem/test.sh runs.
#
# WHY a harness (not the CLI):  the historical `ccextractor @@` file-input
# target is unfuzzable on today's upstream tip — see mayhem/fuzz_harness.c.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CC:=clang}"
: "${SANITIZER_FLAGS:=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${DEBUG_FLAGS:=-gdwarf-3}"   # Mayhem triage reads DWARF <= 3; clang's plain -g emits DWARF-5
: "${COVERAGE_FLAGS:=}"
: "${MAYHEM_JOBS:=$(nproc)}"

# ccextractor's lib_ccx uses Linux-style intrusive lists (list_for_each_entry /
# container_of).  On the empty-list sentinel the loop macro forms a member
# pointer from the list head without dereferencing it — a benign idiom that
# trips these UBSan sub-checks on virtually every parse.  Silence exactly those
# (keep the rest of UBSan halting) so the target is fuzzable rather than
# aborting on the idiom on the first input.
UBSAN_SUPPRESS="-fno-sanitize=null,alignment,object-size,pointer-overflow"
# SOURCE_DATE_EPOCH may be empty (ARG default) — unset it so clang doesn't choke.
[ -z "${SOURCE_DATE_EPOCH:-}" ] && unset SOURCE_DATE_EPOCH || true

export RUSTUP_HOME="${RUSTUP_HOME:-/opt/toolchains/rust/rustup}"
export CARGO_HOME="${CARGO_HOME:-/opt/toolchains/rust/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"
# Air-gapped re-run: use the baked registry cache, never the network.
export CARGO_NET_OFFLINE=true

cd "$SRC/linux"

# --- (b) Rust static lib -----------------------------------------------------
echo "== building rust lib =="
( cd "$SRC/src/rust" && CARGO_TARGET_DIR="$SRC/linux/rust" cargo build --release --offline )
cp "$SRC/linux/rust/release/libccx_rust.a" "$SRC/linux/libccx_rust.a"

# Pre-compile the upstream Rust test suites so mayhem/test.sh only RUNS them.
echo "== pre-compiling rust test suites =="
( cd "$SRC/src/rust" && cargo test --offline --no-run )
( cd "$SRC/src/rust/lib_ccxr" && cargo test --offline --no-run )

# --- generate version header -------------------------------------------------
./pre-build.sh

GPAC_CFLAGS="$(PKG_CONFIG_PATH=/usr/local/lib/pkgconfig pkg-config --cflags gpac)"
# Only a static gpac archive (libgpac_static.a) is installed; link it directly + its private deps.
GPAC_LIBS="/usr/local/lib/libgpac_static.a -llzma"

# -DDISABLE_RUST: build the mature pure-C pipeline (upstream `./build -min-rust`).
# The Rust static lib is still linked (some FFI exports have no C fallback), but
# the demuxer/decoder call sites use their robust C implementations.
BLD_FLAGS="-std=gnu99 -Wno-write-strings -Wno-pointer-sign -D_FILE_OFFSET_BITS=64 \
-DVERSION_FILE_PRESENT -DENABLE_OCR -DGPAC_DISABLE_VTT -DGPAC_DISABLE_OD_DUMP \
-DGPAC_DISABLE_REMOTERY -DNO_GZIP -DFT2_BUILD_LIBRARY -DGPAC_64_BITS -DDISABLE_RUST"

BLD_INCLUDE="-I../src -I/usr/include/leptonica/ -I/usr/include/tesseract/ \
-I../src/lib_ccx/ $GPAC_CFLAGS -I../src/thirdparty/libpng -I../src/thirdparty/zlib \
-I../src/lib_ccx/zvbi -I../src/thirdparty/lib_hash -I../src/thirdparty \
-I../src/thirdparty/freetype/include"

SRC_LIBPNG="$(find ../src/thirdparty/libpng/ -name '*.c')"
SRC_ZLIB="$(find ../src/thirdparty/zlib/ -name '*.c')"
SRC_CCX="$(find ../src/lib_ccx/ -name '*.c')"
SRC_HASH="$(find ../src/thirdparty/lib_hash/ -name '*.c')"
SRC_UTF8PROC="../src/thirdparty/utf8proc/utf8proc.c"
SRC_FREETYPE="$(cat "$SRC/mayhem/freetype-sources.txt")"

# Harness replaces ../src/ccextractor.c (which defines main()); the harness
# provides the few globals that file owned (see mayhem/fuzz_harness.c).
BLD_SOURCES="$SRC/mayhem/fuzz_harness.c $SRC_CCX $SRC_ZLIB $SRC_LIBPNG $SRC_HASH $SRC_UTF8PROC $SRC_FREETYPE"
BLD_LINKER="-lm -Wl,-z,muldefs -ltesseract -lleptonica -lpthread -ldl ./libccx_rust.a $GPAC_LIBS"

echo "== building ccextractor libFuzzer target (sanitized) =="
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $DEBUG_FLAGS $UBSAN_SUPPRESS $BLD_FLAGS $BLD_INCLUDE \
  -o ccextractor $BLD_SOURCES $BLD_LINKER

echo "== building ccextractor-standalone reproducer =="
# Same harness, LLVM's run-once driver instead of the libFuzzer engine: a natural
# crash reproducer (one input file, respects $SANITIZER_FLAGS). Repro artifact,
# not a Mayhemfile target.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_SUPPRESS $BLD_FLAGS $BLD_INCLUDE \
  -o ccextractor-standalone "$STANDALONE_FUZZ_MAIN" $BLD_SOURCES $BLD_LINKER

test -x ./ccextractor && test -x ./ccextractor-standalone

# The upstream functional test suite is the Rust suite (src/rust + src/rust/lib_ccxr,
# the suite wired into upstream CI's test_rust.yml); mayhem/test.sh runs it via `cargo test`.
# The legacy C libcheck suite in tests/ is NOT built: it no longer compiles against the
# current source (its ccx_encoders_splitbysentence_suite.c calls sbs_append_string with the
# old 3-arg signature — a hard int-conversion error under clang-19/gcc-14) and upstream CI
# does not run it.

echo "build.sh done"
