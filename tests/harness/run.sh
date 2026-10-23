#!/usr/bin/env bash
# Builds and runs the ml_pgsql sanitizer harness: every scenario under
#   asan      ASan + UBSan (+LSan at exit and right after every ShutdownModule)
#   tsan      ThreadSanitizer (host, MTA's Lua and the module instrumented)
#   valgrind  memcheck on a non-sanitized debug build
#   plain     same debug build without tools (timing / RSS baseline)
# Returns non-zero if anything failed.
#
# Scenarios (tests/harness/scenarios/<name>/main.lua, each a "resource" that may start others):
#   functional  every API function/option, type conversions both ways, COPY, transactions
#   await       coroutine awaits, yield across C boundaries (10k, leak check), GC during resume
#   sync        *Sync, syncTimeout, queryTimeout, maxQueue, ordering, poolSize 4, pipeline=false
#   connfail    bad host/port/password, outages and hung server (TCP proxy), killed sessions
#   lifecycle   pgClose/stop/GC with pending work, unload/reload with live VMs, ShutdownModule
#               timing, VMs destroyed without hooks (+ lua_State address reuse)
#   stress      100k mixed ops x SCALE over 4 VMs with random stops/destroys/reloads/net cuts
#   soak        steady load with churn; RSS/threads/fds/Lua heap sampled (MLPG_SOAK_SECONDS)
#   dnshang     hanging DNS resolver (runs in a separate container with --dns 192.0.2.1)
#
#   tests/harness/run.sh                      # everything
#   tests/harness/run.sh asan tsan            # selected variants
#   SCENARIOS="functional lifecycle" tests/harness/run.sh asan
#   MLPG_SOAK_SECONDS=600 tests/harness/run.sh plain    # longer soak
#   MLPG_SRC_ROOT=/abs/path/to/checkout ...  # test another module checkout (e.g. with a fix applied)
#   KEEP=1 ...                                # keep the postgres container/network afterwards
#
# Uses its own docker network/containers (mlpg-harness, mlpg-harness-pg); never touches the
# tests/docker-compose.yml stack. Logs: build/harness-logs/<variant>/<scenario>.log
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
IMAGE=mlpg-harness:latest
NET=mlpg-harness
PG=mlpg-harness-pg

cleanup() {
  if [ -z "${KEEP:-}" ]; then
    docker rm -f "$PG" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== docker image"
docker build -q -t "$IMAGE" "$HERE" >/dev/null

echo "== postgres"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
if ! docker inspect "$PG" >/dev/null 2>&1; then
  docker run -d --name "$PG" --network "$NET" \
    -e POSTGRES_PASSWORD=mta -e POSTGRES_USER=mta -e POSTGRES_DB=mta \
    --tmpfs /var/lib/postgresql postgres:18 -c max_connections=400 >/dev/null
fi
for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U mta -d mta -h 127.0.0.1 >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$PG" pg_isready -U mta -d mta -h 127.0.0.1 >/dev/null

ENV_ARGS=(-e MLPG_PGHOST="$PG")
for v in MLPG_SOAK_SECONDS MLPG_SCALE_OVERRIDE; do
  if [ -n "${!v:-}" ]; then ENV_ARGS+=(-e "$v=${!v}"); fi
done
MOUNTS=(-v "$ROOT":/src)
if [ -n "${MLPG_SRC_ROOT:-}" ]; then
  MOUNTS+=(-v "$MLPG_SRC_ROOT":/modsrc)
  ENV_ARGS+=(-e MLPG_SRC_ROOT=/modsrc)
fi

# Scenarios that need a dead DNS server run in a second container (--dns 192.0.2.1: external
# names hang, container names still resolve through docker's embedded DNS).
MAIN_SCEN=""; DNS_SCEN=""
if [ -n "${SCENARIOS:-}" ]; then
  for s in $SCENARIOS; do if [ "$s" = dnshang ]; then DNS_SCEN=dnshang; else MAIN_SCEN="$MAIN_SCEN $s"; fi; done
else
  DNS_SCEN=dnshang
fi

# seccomp=unconfined: TSan needs personality(ADDR_NO_RANDOMIZE) (setarch -R)
rc=0
APPEND=()
if [ -z "${SCENARIOS:-}" ] || [ -n "${MAIN_SCEN// /}" ]; then
  extra=()
  if [ -n "${SCENARIOS:-}" ]; then extra=(-e "SCENARIOS=$MAIN_SCEN"); fi
  docker run --rm --network "$NET" --security-opt seccomp=unconfined \
    -u "$(id -u):$(id -g)" "${MOUNTS[@]}" "${ENV_ARGS[@]}" "${extra[@]}" -e MLPG_NO_RESULTS=1 \
    "$IMAGE" /src/tests/harness/in_container.sh "$@" || rc=1
  APPEND=(-e MLPG_APPEND_SUMMARY=1)
fi
if [ -n "$DNS_SCEN" ]; then
  docker run --rm --network "$NET" --dns 192.0.2.1 --security-opt seccomp=unconfined \
    -u "$(id -u):$(id -g)" "${MOUNTS[@]}" "${ENV_ARGS[@]}" -e SCENARIOS=dnshang "${APPEND[@]}" -e MLPG_NO_RESULTS=1 \
    "$IMAGE" /src/tests/harness/in_container.sh "$@" || rc=1
fi
echo; echo "==== results"; cat "$ROOT/build/harness-logs/summary.txt"
exit $rc
