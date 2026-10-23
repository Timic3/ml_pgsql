#!/usr/bin/env bash
# Runs inside the mlpg-harness image (see run.sh). Builds the module + fake host for each
# variant and runs every scenario under it.
#   in_container.sh [variant...]        variants: asan tsan valgrind plain (default: all)
#   SCENARIOS="functional await"        restrict scenarios (default: all in scenarios/)
set -uo pipefail
ROOT=/src
H=$ROOT/tests/harness
# MLPG_SRC_ROOT: build the module from another checkout (e.g. a patched copy); default: this repo
MOD_ROOT=${MLPG_SRC_ROOT:-$ROOT}
LOGS=${MLPG_LOGS:-$ROOT/build/harness-logs}
JOBS=$(nproc)
VARIANTS=("$@")
[ ${#VARIANTS[@]} -eq 0 ] && VARIANTS=(asan tsan valgrind plain)
if [ -n "${SCENARIOS:-}" ]; then read -r -a SCEN <<<"$SCENARIOS"; else
  # smoke: harness self-check; dnshang: needs a container with a dead DNS server (run.sh runs it separately)
  SCEN=(); for d in "$H"/scenarios/*/; do n=$(basename "$d"); case $n in smoke|dnshang) ;; *) SCEN+=("$n") ;; esac; done; fi

PGHOST_=${MLPG_PGHOST:-mlpg-harness-pg}
export MLPG_PGHOST=$PGHOST_ MLPG_PGPORT=5432
export MLPG_CONNINFO="host=$PGHOST_ port=5432 user=mta password=mta dbname=mta sslmode=disable connect_timeout=10"

build_module() { # dir sanitize buildtype
  cmake -S "$MOD_ROOT" -B "$MOD_ROOT/build/$1" -G Ninja -DCMAKE_BUILD_TYPE="$3" -DMLPG_SANITIZE="$2" >/dev/null && cmake --build "$MOD_ROOT/build/$1" -j"$JOBS" >/dev/null
}
build_host() { # dir sanitize
  cmake -S "$H" -B "$ROOT/build/$1" -G Ninja -DHARNESS_SANITIZE="$2" >/dev/null && cmake --build "$ROOT/build/$1" -j"$JOBS" >/dev/null
}

build_variant() {
  case $1 in
    asan) build_module asan "address,undefined,float-cast-overflow" RelWithDebInfo && build_host harness-asan "address,undefined" ;;
    tsan) build_module tsan thread RelWithDebInfo && build_host harness-tsan thread ;;
    valgrind|plain) build_module debug "" Debug && build_host harness-plain "" ;;
  esac
}

# scenario timeouts (seconds, native); multiplied by the slowdown
timeout_for() { case $1 in stress|soak) echo 900 ;; dnshang) echo 200 ;; *) echo 300 ;; esac; }

run_one() { # variant scenario
  local v=$1 s=$2 mod host slow scale cmd=() rc
  case $v in
    asan) mod=$MOD_ROOT/build/asan/ml_pgsql.so; host=$ROOT/build/harness-asan; slow=2; scale=0.5 ;;
    tsan) mod=$MOD_ROOT/build/tsan/ml_pgsql.so; host=$ROOT/build/harness-tsan; slow=4; scale=0.25 ;;
    valgrind) mod=$MOD_ROOT/build/debug/ml_pgsql.so; host=$ROOT/build/harness-plain; slow=12; scale=0.05 ;;
    plain) mod=$MOD_ROOT/build/debug/ml_pgsql.so; host=$ROOT/build/harness-plain; slow=1; scale=1 ;;
  esac
  local t; t=$(timeout_for "$s"); t=$(( t * slow ))
  mkdir -p "$LOGS/$v"
  local log=$LOGS/$v/$s.log
  export MLPG_VARIANT=$v MLPG_SLOWDOWN=$slow MLPG_SCALE=${MLPG_SCALE_OVERRIDE:-$scale}
  local args=(--module "$mod" --scenario "$H/scenarios/$s/main.lua" --prelude "$H/lua/prelude.lua" --timeout "$t")
  case $v in
    asan)
      export ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:abort_on_error=0:handle_abort=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_string_checks=1:detect_invalid_pointer_pairs=0:symbolize=1:exitcode=86"
      export LSAN_OPTIONS="suppressions=$H/supp/lsan.supp:print_suppressions=1:exitcode=87"
      export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=0:suppressions=$H/supp/ubsan.supp"  # report and continue; the log scan fails the run
      export MLPG_LEAK_CHECK_AT_UNLOAD=1
      cmd=("$host/mtaserver_fake") ;;
    tsan)
      export TSAN_OPTIONS="suppressions=$H/supp/tsan.supp:print_suppressions=1:halt_on_error=0:second_deadlock_stack=1:history_size=7:exitcode=66"
      # high mmap ASLR entropy breaks GCC's TSan memory layout ("unexpected memory mapping")
      cmd=(setarch "$(uname -m)" -R "$host/mtaserver_fake") ;;
    valgrind)
      cmd=(valgrind --tool=memcheck --leak-check=full --errors-for-leak-kinds=definite --show-leak-kinds=definite,indirect
           --error-exitcode=99 --keep-debuginfo=yes --num-callers=40 --fair-sched=yes
           --suppressions="$H/supp/valgrind.supp" --gen-suppressions=all "$host/mtaserver_fake") ;;
    plain) cmd=("$host/mtaserver_fake") ;;
  esac
  local t0=$SECONDS
  timeout -s KILL $(( t + 300 )) "${cmd[@]}" "${args[@]}" >"$log" 2>&1
  rc=$?
  local extra=""
  # sanitizer reports that did not change the exit code (e.g. UBSan recoverable, TSan at exit)
  if grep -qE "runtime error:|WARNING: ThreadSanitizer|ERROR: AddressSanitizer|ERROR: LeakSanitizer|definitely lost: [1-9]" "$log"; then
    [ $rc -eq 0 ] && rc=98
    extra=" (sanitizer report in log)"
  fi
  printf '%-9s %-12s %s  %4ds  %s%s\n' "$v" "$s" "$([ $rc -eq 0 ] && echo PASS || echo "FAIL(rc=$rc)")" $((SECONDS - t0)) "$log" "$extra" | tee -a "$LOGS/summary.txt"
  return $rc
}

mkdir -p "$LOGS"; [ -n "${MLPG_APPEND_SUMMARY:-}" ] || : >"$LOGS/summary.txt"
failed=0
for v in "${VARIANTS[@]}"; do
  echo "== building $v"
  if ! build_variant "$v"; then echo "build failed for $v"; failed=1; continue; fi
  for s in "${SCEN[@]}"; do run_one "$v" "$s" || failed=1; done
done
[ -n "${MLPG_NO_RESULTS:-}" ] || { echo; echo "==== results"; cat "$LOGS/summary.txt"; }
exit $failed
