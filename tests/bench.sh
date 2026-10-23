#!/usr/bin/env bash
# Benchmark ml_pgsql against MTA's built-in MySQL driver (dbConnect/dbQuery/dbExec/dbPoll),
# both running inside the official MTA:SA Linux server in Docker.
#
#   tests/bench.sh                     # 2 runs -> tests/bench-results.md
#   RUNS=3 tests/bench.sh
#   MLPG_MODULE=/abs/path/ml_pgsql.so tests/bench.sh
#
# Builds nothing: it uses the already built module (build/release/ml_pgsql.so by default).
# Every run starts from fresh databases (compose down -v), starts resource "pgbench"
# (tests/resources/pgbench) and collects the BENCH* lines it prints. Raw console output is kept
# in tests/out-bench/. Uses the compose project "mlpg-bench" so other stacks are left alone.
#
# Environment:
#   RUNS=2            number of runs
#   RUN_TIMEOUT=1500  seconds before a hung MTA run is killed
#   REFERENCE=1       also measure plain client round trips (psql, mysql, pgbench) for context
#   OUT_MD=...        output file (default tests/bench-results.md)
#   MLPG_BENCH_PROJECT=mlpg-bench
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
PROJECT=${MLPG_BENCH_PROJECT:-mlpg-bench}
RUNS=${RUNS:-2}
RUN_TIMEOUT=${RUN_TIMEOUT:-1500}
REFERENCE=${REFERENCE:-1}
OUT_MD=${OUT_MD:-$here/bench-results.md}
LOGDIR=$here/out-bench
MODULE=${MLPG_MODULE:-$here/../build/release/ml_pgsql.so}
NET=${PROJECT}_default

compose() {
    docker compose -p "$PROJECT" -f "$here/docker-compose.yml" -f "$here/docker-compose.bench.yml" "$@"
}

teardown() {
    compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
    # one-off "run" containers left behind if a run was killed
    local ids
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true)
    if [ -n "$ids" ]; then docker rm -f $ids >/dev/null 2>&1 || true; fi
}

log() { printf '[bench.sh] %s\n' "$*" >&2; }

[ -f "$MODULE" ] || { log "module not found: $MODULE (build it first, see README)"; exit 2; }
MLPG_MODULE=$(cd "$(dirname "$MODULE")" && pwd)/$(basename "$MODULE")
export MLPG_MODULE
command -v python3 >/dev/null || { log "python3 is required to render the results"; exit 2; }

trap teardown EXIT
trap 'log "interrupted"; exit 130' INT TERM

mkdir -p "$LOGDIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
files=()
status=0

# Plain client round trips on the same Docker network, outside MTA: what the network and the
# database servers allow without MTA in between. Prints REF_*=value lines.
reference() {
    local n=5000 dir
    dir=$(mktemp -d)
    docker exec "${PROJECT}-postgres-1" psql -q -U mta -d mta -v ON_ERROR_STOP=1 -c "SET client_min_messages = warning;" -c \
        "DROP TABLE IF EXISTS refbench; CREATE TABLE refbench (id int PRIMARY KEY, name varchar(64), score int, data text);
         INSERT INTO refbench SELECT g, 'name' || g, g, repeat('x', 100) FROM generate_series(1, 20000) g; ANALYZE refbench;" >/dev/null
    docker exec "${PROJECT}-mysql-1" mysql -umta -pmta mta -e \
        "DROP TABLE IF EXISTS refbench; CREATE TABLE refbench (id int PRIMARY KEY, name varchar(64), score int, data text);
         SET SESSION cte_max_recursion_depth = 100000;
         INSERT INTO refbench WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 20000)
         SELECT n, CONCAT('name', n), n, REPEAT('x', 100) FROM s; ANALYZE TABLE refbench;" >/dev/null 2>&1
    for i in $(seq 1 "$n"); do printf 'SELECT id, name, score, data FROM refbench WHERE id = %d;\n' "$i"; done >"$dir/q.sql"
    printf '%s\n' '\set id random(1, 20000)' 'SELECT id, name, score, data FROM refbench WHERE id = :id;' >"$dir/one.sql"
    {
        printf '%s\n' '\set id random(1, 20000)' '\startpipeline'
        for i in $(seq 1 64); do
            printf '%s\n' 'SELECT id, name, score, data FROM refbench WHERE id = :id;'
            [ "$i" -lt 64 ] && printf '%s\n' '\syncpipeline'
        done
        printf '%s\n' '\endpipeline'
    } >"$dir/pipe.sql"
    chmod -R a+rX "$dir"
    # sequential round trips through the command line clients (container start-up not timed)
    local timed='t0=$(date +%s%N); "$@" < /ref/q.sql > /dev/null 2>&1; t1=$(date +%s%N); echo $(( (t1 - t0) / 1000 ))'
    local us
    us=$(docker run --rm --network "$NET" -v "$dir:/ref:ro" -e PGPASSWORD=mta postgres:18 \
        sh -c "$timed" sh psql -q -X -h postgres -U mta -d mta)
    echo "REF_PSQL_US=$((us / n))"
    us=$(docker run --rm --network "$NET" -v "$dir:/ref:ro" mysql:8.4 \
        sh -c "$timed" sh mysql -h mysql -umta -pmta -N -B mta)
    echo "REF_MYSQL_US=$((us / n))"
    # pgbench: one query per round trip, and 64 per round trip each with its own Sync (the way
    # ml_pgsql pipelines: every query stays its own implicit transaction)
    local tps
    for f in one pipe; do
        tps=$(docker run --rm --network "$NET" -v "$dir:/ref:ro" -e PGPASSWORD=mta postgres:18 \
            pgbench -h postgres -U mta -n -M extended -f "/ref/$f.sql" -T 3 mta 2>/dev/null |
            sed -n 's/^tps = \([0-9.]*\).*/\1/p')
        echo "REF_PGBENCH_${f^^}_TPS=$tps"
    done
    rm -rf "$dir"
}

for run in $(seq 1 "$RUNS"); do
    log "run $run/$RUNS: starting fresh databases"
    teardown
    compose up -d --wait --wait-timeout 300 postgres mysql >/dev/null 2>&1 || {
        log "databases did not become healthy"; compose ps >&2 || true; status=1; break; }

    console=$LOGDIR/console-$stamp-run$run.log
    out=$LOGDIR/bench-$stamp-run$run.txt
    log "run $run/$RUNS: MTA server running resource pgbench (timeout ${RUN_TIMEOUT}s), console -> ${console#$here/}"
    rc=0
    MLPG_SUITE=bench timeout --kill-after=30 "$RUN_TIMEOUT" \
        docker compose -p "$PROJECT" -f "$here/docker-compose.yml" -f "$here/docker-compose.bench.yml" \
        run --rm -T mta >"$console" 2>&1 </dev/null || rc=$?
    grep -ao 'BENCH[A-Z]* .*' "$console" | tr -d '\r' >"$out" || true
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        log "run $run: TIMED OUT after ${RUN_TIMEOUT}s"; echo "BENCHERROR run timed out after ${RUN_TIMEOUT}s" >>"$out"; status=1
    fi
    if ! grep -q '^BENCHDONE ' "$out"; then
        log "run $run: no BENCHDONE line (server exit code $rc); last console lines:"; tail -n 30 "$console" >&2; status=1
    fi
    if grep -q '^BENCH\(FAIL\|ERROR\) ' "$out"; then
        log "run $run: correctness failures:"; grep '^BENCH\(FAIL\|ERROR\) ' "$out" >&2; status=1
    fi
    if grep -qi 'segmentation fault\|core dumped\|terminate called' "$console"; then
        log "run $run: the server crashed, see $console"; echo "BENCHERROR server crashed" >>"$out"; status=1
    fi
    if [ "$REFERENCE" = 1 ]; then
        log "run $run: reference round trips outside MTA"
        reference >>"$out" 2>/dev/null || log "reference measurement failed (ignored)"
    fi
    files+=("$out")
    teardown
done

# machine / environment info for the report
export B_DATE=$(date -u '+%Y-%m-%d %H:%M UTC')
export B_NPROC=$(nproc)
export B_CPU=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
export B_MEM=$(awk '/MemTotal/ {printf "%.0f GiB", $2 / 1048576}' /proc/meminfo)
export B_KERNEL=$(uname -sr)
export B_OS=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown)
export B_DOCKER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)
export B_STATUS=$status
export B_MODULE_SHA=$(sha256sum "$MLPG_MODULE" | cut -c1-16)
export B_MODULE_MTIME=$(date -u -r "$MLPG_MODULE" '+%Y-%m-%d %H:%M:%S UTC')

python3 -I - "$OUT_MD" "${files[@]}" <<'PY'
import json, os, sys

out_md, files = sys.argv[1], sys.argv[2:]
runs = []
for path in files:
    run = {"results": {}, "meta": {}, "fails": [], "done": None, "ref": {}, "file": os.path.basename(path)}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            tag, _, rest = line.partition(" ")
            if tag == "BENCHJSON":
                r = json.loads(rest)
                run["results"][(r["workload"], r["backend"])] = r
            elif tag == "BENCHMETA":
                run["meta"] = json.loads(rest)
            elif tag == "BENCHDONE":
                run["done"] = json.loads(rest)
            elif tag in ("BENCHFAIL", "BENCHERROR"):
                run["fails"].append(line)
            elif line.startswith("REF_") and "=" in line:
                k, v = line.split("=", 1)
                run["ref"][k] = v
    runs.append(run)

meta = next((r["meta"] for r in runs if r["meta"]), {})
cfg = meta.get("cfg", {})
nruns = len(runs)

def cell(workload, backend, key, fmt="{:,.0f}"):
    vals = []
    for run in runs:
        r = run["results"].get((workload, backend))
        v = None if r is None else r.get(key)
        if v is None:
            vals.append("–")
        elif isinstance(v, (int, float)):
            vals.append(fmt.format(v))
        else:
            vals.append(str(v))
    if len(set(vals)) == 1 and not all(isinstance(run["results"].get((workload, backend), {}).get(key), (int, float)) for run in runs):
        return vals[0]  # identical text (e.g. the method) in every run
    return " / ".join(vals)

def backends_for(workload):
    seen = []
    for run in runs:
        for (w, b) in run["results"]:
            if w == workload and b not in seen:
                seen.append(b)
    return seen

def ok_mark(workload, backend):
    bad = [run for run in runs if (workload, backend) in run["results"] and not run["results"][(workload, backend)].get("ok", True)]
    return " ⚠️" if bad else ""

LABELS = {}
for run in runs:
    for (w, b), r in run["results"].items():
        LABELS.setdefault(b, r.get("label", b))

def table(title, workload, cols, note=None):
    bs = backends_for(workload)
    if not bs:
        return []
    lines = [f"### {title}", ""]
    if note:
        lines += [note, ""]
    lines.append("| backend | " + " | ".join(c[0] for c in cols) + " |")
    lines.append("|---|" + "|".join("---:" for _ in cols) + "|")
    for b in bs:
        lines.append(f"| `{b}`{ok_mark(workload, b)} | " + " | ".join(cell(workload, b, c[1], *(c[2:] or [])) for c in cols) + " |")
    lines.append("")
    return lines

FR = [("frame p99 ms", "frameP99"), ("frame max ms", "frameMax")]
md = []
md += ["# ml_pgsql vs MTA built-in MySQL: benchmark results", ""]
md += [f"Generated {os.environ.get('B_DATE')} by `tests/bench.sh`: {nruns} run(s), each from fresh databases. "
       f"Each cell shows one value per run (`run 1 / run 2 / ...`).", ""]
status = "all correctness checks passed" if os.environ.get("B_STATUS") == "0" and all(r["done"] and not r["fails"] for r in runs) else "**FAILURES, see below**"
md += [f"Status: {status}.", ""]

md += ["## Environment", "", "| | |", "|---|---|"]
md += [f"| CPU | {os.environ.get('B_CPU')} ({os.environ.get('B_NPROC')} logical CPUs), {os.environ.get('B_MEM')} RAM |"]
md += [f"| OS | {os.environ.get('B_OS')}, kernel {os.environ.get('B_KERNEL')}, Docker {os.environ.get('B_DOCKER')} |"]
md += [f"| MTA server | {meta.get('mta', '?')} (official Linux x64 build, `tests/mta/Dockerfile`) |"]
md += [f"| ml_pgsql | {meta.get('module', '?')}, libpq {meta.get('libpq', '?')}; `ml_pgsql.so` sha256 {os.environ.get('B_MODULE_SHA')}…, built {os.environ.get('B_MODULE_MTIME')} |"]
md += [f"| PostgreSQL | {meta.get('pgServer', '?')} (`postgres:18`, data on tmpfs, default settings) |"]
md += [f"| MySQL | {meta.get('mysqlServer', '?')} (`mysql:8.4`, data on tmpfs, default settings) |"]
fps = meta.get("fpsLimit")
md += [f"| Server frames | `server_logic_fps_limit={fps}` during the run (≈{1000 // fps if fps else '?'} ms frames); "
       f"MTA's default on an empty server is ≈40 ms frames (see `seq_select_default_fps`) |"]
md += [""]

refs = [r["ref"] for r in runs if r["ref"]]
if refs:
    def rj(key, fmt="{}", conv=str):
        out = []
        for r in refs:
            try:
                out.append(fmt.format(conv(r[key])))
            except (KeyError, ValueError, TypeError):
                out.append("–")
        return " / ".join(out)
    md += ["Reference without MTA (client container on the same Docker network, sequential PK SELECTs):", ""]
    md += [f"- `psql`: {rj('REF_PSQL_US')} µs per round trip; `mysql` CLI: {rj('REF_MYSQL_US')} µs per round trip",
           f"- `pgbench -M extended`: {rj('REF_PGBENCH_ONE_TPS', '{:.0f}', float)} queries/s with one query per round trip; "
           f"{rj('REF_PGBENCH_PIPE_TPS', '{:.0f}', lambda v: float(v) * 64)} queries/s pipelined 64 deep "
           f"with one Sync per query (ml_pgsql's pipelining model)", ""]

md += ["## Backends", "", "| id | configuration |", "|---|---|"]
for b, label in LABELS.items():
    if b != "server":
        md += [f"| `{b}` | {label} |"]
md += [""]

md += ["## Results", ""]
md += table(f"a. Single-row INSERT, fire-and-forget (N={cfg.get('nInsert')})", "insert",
            [("ops/s", "ops"), ("total ms", "ms"), ("submit loop ms", "submitMs"), ("round trips", "roundTrips")] + FR,
            "`dbExec` vs `pgExec` in one loop, timed until a fence query (or `pgStats` for poolSize>1) shows that all rows are written. "
            "*Submit loop* is main-thread time spent issuing the burst.")
md += table(f"b. Point SELECT by primary key, burst (N={cfg.get('nPoint')})", "point_select",
            [("ops/s", "ops"), ("total ms", "ms"), ("submit loop ms", "submitMs"), ("round trips", "roundTrips")] + FR,
            "All queries issued in one loop with one shared callback (`dbQuery` + `dbPoll(qh, 0)` vs `pgQuery`), timed until the last callback.")
md += table(f"c. Sequential round trips through callbacks (N={cfg.get('nSeq')})", "seq_select",
            [("avg ms", "latAvg", "{:.2f}"), ("p50 ms", "latP50"), ("p99 ms", "latP99"), ("max ms", "latMax")],
            "Each query is issued from the previous query's callback. Both drivers deliver results once per server frame, so this measures frame pacing.")
md += table(f"c'. Same at MTA's default frame pacing (N={cfg.get('nSeqDefault')})", "seq_select_default_fps",
            [("avg ms", "latAvg", "{:.2f}"), ("p50 ms", "latP50"), ("p99 ms", "latP99"), ("max ms", "latMax")])
md += table(f"c''. Blocking round trips (N={cfg.get('nSync')})", "sync_select",
            [("µs/query", "latAvgUs"), ("ops/s", "ops")] + FR,
            "`dbPoll(dbQuery(...), -1)` vs `pgQuerySync`, in chunks of "
            f"{cfg.get('syncChunk')} per frame. This is the real driver round trip, without frame pacing.")
md += table(f"d. Large result: {cfg.get('largeReps')} × SELECT of {cfg.get('largeRows')} rows × 4 columns, burst", "large_select",
            [("rows/s", "rowsPerSec"), ("total ms", "ms"), ("to-Lua avg ms", "convAvg", "{:.2f}"), ("to-Lua max ms", "convMax")] + FR,
            "*To-Lua* is main-thread time per result until it is a Lua table: ml_pgsql converts before calling the callback, MTA converts in `dbPoll`.")
md += table(f"e. Bulk insert in one transaction ({cfg.get('bulkRows')} rows, {cfg.get('bulkReps')} repetitions)", "bulk_tx",
            [("method", "mode", "{}"), ("ms/tx", "ms", "{:.1f}"), ("rows/s", "rowsPerSec"), ("submit ms", "submitMs", "{:.1f}")] + FR,
            "MySQL: `START TRANSACTION`, N × `dbExec`, `COMMIT` on the ordered connection, or one multi-statement `dbQuery` "
            "(`multi_statements=1`). ml_pgsql: `pgTransaction` with N statements.")
md += table("f. Idle server frames (no database work)", "idle_frames_default",
            [("frame avg ms", "frameAvg", "{:.1f}"), ("frame p99 ms", "frameP99"), ("frame max ms", "frameMax")],
            "Default pacing. The *frame* columns above are gaps between consecutive server frames, measured with "
            "`setTimer(fn, 0, 0)` while the workload ran; a long frame means the main thread was blocked.")
md += table("f'. Idle server frames at the benchmark's fps limit", "idle_frames",
            [("frame avg ms", "frameAvg", "{:.1f}"), ("frame p99 ms", "frameP99"), ("frame max ms", "frameMax")])

fails = [(i + 1, l) for i, r in enumerate(runs) for l in r["fails"]]
missing = [i + 1 for i, r in enumerate(runs) if not r["done"]]
md += ["## Correctness", ""]
if not fails and not missing:
    md += ["Every workload verified its results (row counts after inserts, one row per point SELECT with the expected id sum, "
           "result shape of large SELECTs, no failed queries). No failures.", ""]
else:
    for i in missing:
        md += [f"- run {i}: did not finish (no BENCHDONE)"]
    for i, l in fails:
        md += [f"- run {i}: `{l}`"]
    md += [""]

md += ["Raw output: " + ", ".join(f"`tests/out-bench/{r['file']}`" for r in runs), ""]
with open(out_md, "w", encoding="utf-8") as f:
    f.write("\n".join(md))
print(f"wrote {out_md}", file=sys.stderr)
PY

log "results: ${OUT_MD#$here/}"
exit $status
