#!/usr/bin/env bash
# Runs the integration test suite (tests/resources/pgtest) inside the official MTA server.
# Usage: tests/run.sh            (expects build/release/ml_pgsql.so)
#        MLPG_MODULE=/abs/path/ml_pgsql.so tests/run.sh
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=${MLPG_PROJECT:-mlpg-test}
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.tls.yml)
export MLPG_SUITE=test
export MLPG_OUT=./out-test

cleanup() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Throwaway TLS material for the sslmode=verify-full tests
if [ ! -f certs/server.key ]; then
    if command -v openssl >/dev/null; then
        certs/generate.sh
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/certs":/c -w /c --entrypoint sh alpine/openssl ./generate.sh
    fi
fi

OUT=out-test
mkdir -p "$OUT"
rm -f "$OUT"/server.log "$OUT"/scripts.log "$OUT"/console.log

"${COMPOSE[@]}" build -q mta
"${COMPOSE[@]}" up -d --wait postgres >/dev/null

set +e
timeout 900 "${COMPOSE[@]}" run --rm --no-deps mta 2>&1 | tee "$OUT"/console.log | grep --line-buffered -E "PGTEST|ERROR|WARNING|MODULE|Segmentation|terminate called|Loading script failed"
status=${PIPESTATUS[0]}
set -e

fail=0
pass_count=$(grep -c "PGTEST PASS" "$OUT"/console.log || true)
fail_count=$(grep -c "PGTEST FAIL" "$OUT"/console.log || true)
echo
echo "== $pass_count passed, $fail_count failed (server exit status $status)"

if ! grep -q "PGTEST SUMMARY" "$OUT"/console.log; then
    echo "!! test run did not complete"
    fail=1
fi
if [ "$fail_count" != "0" ]; then fail=1; fi
if grep -qE "Segmentation fault|core dumped|terminate called|Aborted" "$OUT"/console.log; then
    echo "!! server crashed"
    fail=1
fi
if [ "$status" != "0" ]; then
    echo "!! server exited with status $status"
    fail=1
fi

# Writes queued right before shutdown() must all have reached the database.
drained=$("${COMPOSE[@]}" exec -T postgres psql -U mta -d mta -tAc "SELECT count(*) FROM drain_test" 2>/dev/null || echo "?")
echo "== shutdown drain: $drained / 3000 rows"
if [ "$drained" != "3000" ]; then
    echo "!! writes were lost at shutdown"
    fail=1
fi

exit $fail
