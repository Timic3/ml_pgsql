#!/usr/bin/env bash
# Memory soak: the shipping ml_pgsql.so inside the official MTA server under a steady mixed load
# over TLS (tests/resources/pgsoak), sampled from outside the Lua VM to prove that the
# mta-server64 process does not grow.
#
#   tests/soak.sh                     # 30 minutes of load
#   tests/soak.sh --quick             # 5 minutes
#   tests/soak.sh --analyze           # only redo the analysis of the last run (in $SOAK_OUT)
#   SOAK_MINUTES=180 tests/soak.sh
#   SOAK_MODE=control tests/soak.sh   # the same Lua-side churn without module calls
#   MLPG_PLATFORM=linux/arm64 MLPG_ARCH=arm64 MLPG_MODULE=../build/arm64/ml_pgsql.so tests/soak.sh
#
# Every SOAK_SAMPLE_SECONDS (and at every phase change) the script reads /proc/<pid>/status
# (VmRSS, RssAnon, VmHWM, Threads) and counts /proc/<pid>/fd of the server through docker exec,
# then merges the samples with the resource's "PGSOAK STAT" lines into tests/out-soak/samples.csv.
# Verdict and numbers: tests/out-soak/summary.txt. Raw console: tests/out-soak/console.log.
#
# The run fails if, after a warm-up of min(5 min, 20% of the load):
#   - RSS grows by more than max(4 MB, 3%), or its trend over the second half of the load (a
#     linear fit to one-minute medians) rises faster than SOAK_RSS_SLOPE_KB_MIN and is clearly
#     above zero (slope minus two standard errors)
#   - threads or fds are not back at their baseline (module loaded, no connection open) once
#     every pool is closed
#   - the Lua heap (after a full collect) or the registry trends upward, or a pool's
#     outstanding count does not drain to 0
#   - pgsoak reports a failure (every result is verified), an unexpected ERROR line appears,
#     the server crashes, or writes queued right before shutdown() are lost
#
# Environment:
#   SOAK_MINUTES=30 (5 with --quick), SOAK_RATE=2000 ops/s (250 under arm64 emulation),
#   SOAK_MODE=module|control, SOAK_SAMPLE_SECONDS=10, SOAK_WARMUP_SECONDS (default above)
#   SOAK_RSS_SLOPE_KB_MIN=40, SOAK_LUA_SLOPE_KB_MIN=8   slope limits, see README "Memory soak"
#   SOAK_CFG_<key>=<value>   any other pgsoak CFG key, e.g. SOAK_CFG_killSeconds=5
#   SOAK_OUT=out-soak        output directory under tests/ (e.g. out-soak-control)
#   SOAK_MTA_ENV="A=1 B=2"   environment for the server process, by default
#                            MALLOC_MMAP_THRESHOLD_=131072 so that RSS follows what is allocated.
#                            Empty runs with glibc's malloc defaults, whose arena caching after
#                            reconnects adds a few MB that fail the RSS checks without any leak
#                            (README "Memory soak").
#   SOAK_HEAPTRACK=1         run the server under heaptrack (tests/mta/heaptrack.Dockerfile); the
#                            trace lands in $SOAK_OUT/heaptrack.*. Symbols need an unstripped twin:
#                            cmake -DMLPG_STRIP=OFF (same code), passed as MLPG_MODULE. The server
#                            aborts with "free(): invalid pointer" after "Server stopped!" under
#                            heaptrack, with or without the module (not a module bug); the trace
#                            is complete. Analyse it with heaptrack_print inside that image.
#   MLPG_MODULE, MLPG_PLATFORM, MLPG_ARCH as for tests/run.sh; MLPG_SOAK_PROJECT=mlpg-soak
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

QUICK=0 ANALYZE_ONLY=0
for arg in "$@"; do
    case $arg in
        --quick) QUICK=1 ;;
        --analyze) ANALYZE_ONLY=1 ;;
        *) echo "usage: $0 [--quick] [--analyze]" >&2; exit 2 ;;
    esac
done

log() { printf '[soak.sh] %s\n' "$*" >&2; }

PROJECT=${MLPG_SOAK_PROJECT:-mlpg-soak}
CTR=$PROJECT-mta
OUT=${SOAK_OUT:-out-soak}
CONSOLE=$OUT/console.log
HOST=$OUT/host.tsv
export MLPG_SUITE=soak MLPG_OUT=./$OUT

# Analysis of $OUT/{console.log,host.tsv,run.env}: prints the verdict, writes summary.txt.
analyze() {
python3 -I - "$CONSOLE" "$HOST" "$OUT/samples.csv" "$OUT/summary.txt" "$OUT" <<'PY'
import csv, json, math, os, re, statistics, sys

console_path, host_path, csv_path, summary_path, out_dir = sys.argv[1:6]
env = os.environ

# ---- console: PGSOAK lines with their line index (host samples record the line count)
with open(console_path, encoding="utf-8", errors="replace") as f:
    lines = f.read().split("\n")
phases, stats, fails = [], [], []
config = report = ops = None
drain_queued = None
tag_re = re.compile(r"PGSOAK (\w+) ?(.*)$")
for i, raw in enumerate(lines):
    line = raw.rstrip("\r")
    m = tag_re.search(line)
    if not m:
        continue
    tag, rest = m.groups()
    try:
        if tag == "PHASE":
            name, _, t = rest.partition(" t=")
            phases.append((i, name.strip(), int(t) if t.strip().isdigit() else None))
        elif tag == "STAT":
            stats.append((i, json.loads(rest)))
        elif tag == "FAIL":
            fails.append(rest)
        elif tag == "CONFIG":
            config = json.loads(rest)
        elif tag == "REPORT":
            report = json.loads(rest)
        elif tag == "OPS":
            ops = json.loads(rest)
        elif tag == "DRAIN":
            drain_queued = int(rest.split("=", 1)[1])
    except (ValueError, IndexError) as e:
        fails.append(f"unparsable console line {i + 1}: {line[:200]} ({e})")

def latest(events, count):
    """Last event printed before the console had `count` complete lines."""
    found = None
    for ev in events:
        if ev[0] < count:
            found = ev
        else:
            break
    return found

# ---- host samples merged with the Lua side
samples = []
with open(host_path) as f:
    for row in f:
        parts = row.rstrip("\n").split("\t")
        if len(parts) < 9:
            continue
        epoch, count = float(parts[0]), int(parts[1])
        rss, anon, hwm, vsz, thr, fds, cpu = (int(x) for x in parts[2:9])
        ph = latest(phases, count)
        st = latest(stats, count)
        samples.append({"epoch": epoch, "phase": ph[1] if ph else "start", "rss": rss, "anon": anon, "hwm": hwm,
                        "vsz": vsz, "threads": thr, "fds": fds, "cpu": cpu / 100.0, "lua": st[1] if st else {}})

load = [s for s in samples if s["phase"] == "load"]
t_load = load[0]["epoch"] if load else (samples[0]["epoch"] if samples else 0)
COLS = [("t_s", None), ("t_load_s", None), ("phase", None), ("rss_kb", "rss"), ("rss_anon_kb", "anon"), ("hwm_kb", "hwm"),
        ("vmsize_kb", "vsz"), ("threads", "threads"), ("fds", "fds"), ("cpu_s", "cpu")]
LUA_COLS = [("lua_phase", "ph"), ("lua_kb", "kb"), ("lua_live_kb", "live"), ("lua_registry", "reg"), ("ops", "ops"),
            ("ops_per_s", "rate"), ("ok", "ok"), ("expected_errors", "xerr"), ("kill_failures", "kf"), ("failures", "fail"),
            ("pending", "pend"), ("lost", "lost"), ("throttled", "thr"), ("outstanding_a", "oA"), ("outstanding_b", "oB"),
            ("queued_a", "qA"), ("queued_b", "qB"), ("connected_a", "cnA"), ("connected_b", "cnB"), ("reconnects_a", "rcA"),
            ("reconnects_b", "rcB"), ("kills", "kills"), ("churn_opened", "churn"), ("churn_open", "copen"),
            ("gc_pending", "gcw"), ("child_cycles", "child"), ("backends", "be"), ("backends_churn", "bec")]
with open(csv_path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow([c for c, _ in COLS] + [c for c, _ in LUA_COLS])
    t_first = samples[0]["epoch"] if samples else 0
    for s in samples:
        w.writerow([round(s["epoch"] - t_first, 1), round(s["epoch"] - t_load, 1), s["phase"]]
                   + [s[k] for _, k in COLS[3:]] + [s["lua"].get(k, "") for _, k in LUA_COLS])

# ---- analysis
checks = []  # (ok, label, detail)
notes = []
def check(ok, label, detail=""):
    checks.append((bool(ok), label, detail))

def median(v):
    return statistics.median(v) if v else float("nan")

def ols(xs, ys):
    """Least-squares slope and its standard error."""
    n = len(xs)
    if n < 3:
        return float("nan"), float("inf")
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return float("nan"), float("inf")
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    res = sum((y - my - b * (x - mx)) ** 2 for x, y in zip(xs, ys))
    return b, math.sqrt(res / (n - 2) / sxx)

cfg = (config or {}).get("cfg", {})
load_seconds = float(cfg.get("loadSeconds") or (load[-1]["epoch"] - t_load if load else 0))
warm = float(env["S_WARMUP"]) if env.get("S_WARMUP") else min(300.0, 0.2 * load_seconds)
rss_slope_limit, lua_slope_limit = float(env["S_RSS_SLOPE"]), float(env["S_LUA_SLOPE"])
control = cfg.get("mode") == "control"

def trend(series, warm_s, half_s):
    """series: [(seconds since load start, value)] -> start, end, growth, slope/min, se/min, n.
    Growth compares the medians of the first and last tenth (at least 6 samples) after the
    warm-up. The slope is fitted to the medians of bins of at most a minute over the second
    half, so that short swings (GC cycles, large results in flight) and the correlation
    between neighbouring samples do not pass for a trend."""
    post = [(t, v) for t, v in series if t >= warm_s and v is not None]
    if len(post) < 6:
        return None
    k = max(6, len(post) // 10)
    start, end = median([v for _, v in post[:k]]), median([v for _, v in post[-k:]])
    second = [(t, v) for t, v in series if t >= half_s and v is not None]
    width = min(60.0, (second[-1][0] - second[0][0]) / 6) if len(second) > 1 else 60.0
    bins = {}
    for t, v in second:
        bins.setdefault(int((t - second[0][0]) // max(width, 1.0)), []).append((t, v))
    xs = [median([t for t, _ in b]) / 60.0 for b in bins.values()]
    ys = [median([v for _, v in b]) for b in bins.values()]
    slope, se = ols(xs, ys)
    return {"start": start, "end": end, "growth": end - start, "slope": slope, "se": se, "n": len(post)}

def clearly_rising(tr, limit):
    return tr["slope"] > limit and tr["slope"] - 2 * tr["se"] > 0

host = [(s["epoch"] - t_load, s) for s in load]
rss_tr = trend([(t, s["rss"]) for t, s in host], warm, load_seconds / 2)
anon_tr = trend([(t, s["anon"]) for t, s in host], warm, load_seconds / 2)

# Lua side from the STAT lines themselves (their own timestamps, getTickCount() ms)
load_phase = next((p for p in phases if p[1] == "load"), None)
lua_t0 = load_phase[2] if load_phase and load_phase[2] is not None else None
lua_load = [st for _, st in stats if st.get("ph") == "load"] if lua_t0 is not None else []
live_tr = trend([((st["t"] - lua_t0) / 1000.0, st.get("live")) for st in lua_load], warm, load_seconds / 2)
reg_tr = trend([((st["t"] - lua_t0) / 1000.0, st.get("reg")) for st in lua_load], warm, load_seconds / 2)

base = [s for s in samples if s["phase"] == "baseline"]
final = [s for s in samples if s["phase"] == "final"]

check(config is not None, "pgsoak started", "" if config else "no PGSOAK CONFIG line")
check(len(load) >= 6, "enough load samples", f"{len(load)} samples")
if rss_tr:
    limit = max(4096, 0.03 * rss_tr["start"])
    check(rss_tr["growth"] <= limit, "RSS growth after warm-up", f"{rss_tr['growth']:+.0f} KB (limit {limit:.0f} KB)")
    check(not clearly_rising(rss_tr, rss_slope_limit), "RSS slope, second half",
          f"{rss_tr['slope']:+.1f} ± {rss_tr['se']:.1f} KB/min (limit {rss_slope_limit:g})")
else:
    check(False, "RSS trend", "not enough samples after the warm-up")
if base and final:
    tb, fb = median([s["threads"] for s in base]), median([s["fds"] for s in base])
    tf, ff = final[-1]["threads"], final[-1]["fds"]
    check(tf <= tb, "threads back at baseline", f"{tb:.0f} -> {tf}")
    check(ff <= fb, "fds back at baseline", f"{fb:.0f} -> {ff}")
    if tf < tb or ff < fb:
        notes.append("final is below baseline: something besides the module (MTA's startup HTTP requests?) "
                     "was still open at baseline, which makes the fd/thread check lenient; see proc-*.txt")
else:
    check(False, "baseline and final samples", f"{len(base)} baseline, {len(final)} final samples")
if live_tr:
    limit = max(512, 0.10 * live_tr["start"])
    check(live_tr["growth"] <= limit, "Lua heap growth (after full GC)", f"{live_tr['growth']:+.0f} KB (limit {limit:.0f} KB)")
    check(not clearly_rising(live_tr, lua_slope_limit), "Lua heap slope, second half",
          f"{live_tr['slope']:+.2f} ± {live_tr['se']:.2f} KB/min (limit {lua_slope_limit:g})")
else:
    check(False, "Lua heap trend", "not enough PGSOAK STAT lines")
if reg_tr:
    limit = max(200, 0.05 * reg_tr["start"])
    check(reg_tr["growth"] <= limit and not clearly_rising(reg_tr, limit / 10), "Lua registry flat",
          f"{reg_tr['start']:.0f} -> {reg_tr['end']:.0f} refs, slope {reg_tr['slope']:+.1f}/min")
if report:
    check(report.get("ok") and report.get("failures") == 0, "pgsoak checks (every result verified)",
          f"{report.get('failures')} failures, {report.get('lost')} lost, {report.get('ops')} operations")
    if not control:
        for name in ("pgsoak-a", "pgsoak-b"):
            o = (report.get(name) or {}).get("outstanding")
            check(o == 0, f"{name} outstanding drained", f"outstanding {o}")
else:
    check(False, "pgsoak report", "no PGSOAK REPORT line (did the load finish?)")
check(not fails, "no PGSOAK FAIL lines", f"{len(fails)}: {fails[0][:150]}" if fails else "")

allowed_errors = [re.compile(r"ERROR: Error saving '.*/mtaserver\.soak\.conf'")]  # the config is mounted read-only
error_re = re.compile(r"^(\[[\d:]+\] )?ERROR\b|\[ml_pgsql\]")
errors = [l for l in lines if error_re.search(l) and not any(p.search(l) for p in allowed_errors)]
check(not errors, "no unexpected ERROR lines", f"{len(errors)}: {errors[0][:150]}" if errors else "")
crash = [l for l in lines if re.search(r"Segmentation fault|core dumped|terminate called|Aborted|Bus error", l)]
check(not crash, "no crash", crash[0][:150] if crash else "")
check(env["S_RC"] == "0", "server exit status", env["S_RC"])
check(any(p[1] == "shutdown" for p in phases) and drain_queued is not None and env["S_DRAINED"] == str(drain_queued),
      "shutdown() drain", f"{env['S_DRAINED']} / {drain_queued} rows")

ok = all(c[0] for c in checks)

# ---- summary
def fmt(v, d=0):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    return f"{v:,.{d}f}"

def at(series_samples, key):
    return median([s[key] for s in series_samples]) if series_samples else None

post = [s for t, s in host if t >= warm]
k = max(6, len(post) // 10) if post else 0
early, late = post[:k], post[-k:]
out = []
out.append(f"== ml_pgsql memory soak: {'PASS' if ok else 'FAIL'}")
if config:
    out.append(f"module   ml_pgsql {config.get('module')}, libpq {config.get('libpq')}, sha256 {env['S_MODULE_SHA']}..., "
               f"MTA {config.get('mta')}, {env['S_ARCH']}{' (emulated)' if env['S_EMULATED'] == '1' else ''}, {config.get('tls')}")
if "S_MTA_ENV" in env:
    out.append(f"server   env {env['S_MTA_ENV'] or '(empty: glibc malloc defaults)'}")
if report:
    secs = max(load_seconds, 1)
    ks = ", ".join(f"{k} {v}" for k, v in sorted((report.get("killStates") or {}).items())) or "none"
    out.append(f"load     {secs / 60:.1f} min, mode {report.get('mode')}, target {cfg.get('rate')} ops/s, "
               f"{report.get('ops'):,} operations ({report.get('ops') / secs:,.0f}/s), {report.get('expectedErrors'):,} expected errors")
    if not control:
        a, b = report.get("pgsoak-a") or {}, report.get("pgsoak-b") or {}
        ch, cc = report.get("churn") or {}, report.get("child") or {}
        out.append(f"         kills {report.get('kills')} (hit {report.get('killsHit')}), failures they caused: {ks}; "
                   f"reconnects A {a.get('reconnects')} B {b.get('reconnects')}")
        out.append(f"         churn {ch.get('opened')} connections ({ch.get('dropped')} left to the GC), "
                   f"child resource cycles {cc.get('stops')}, pgExec writes landed "
                   f"{sum((report.get(n) or {}).get('landed') or 0 for n in ('pgsoak-a', 'pgsoak-b', 'pgsoak-churn')):,}")
    cpu = [s["cpu"] for s in load]
    if len(cpu) > 1 and load[-1]["epoch"] > load[0]["epoch"]:
        out.append(f"         server CPU {100 * (cpu[-1] - cpu[0]) / (load[-1]['epoch'] - load[0]['epoch']):.0f}% of one core during the load")
out.append(f"warm-up  {warm:.0f} s; slope over the second half of the load ({load_seconds / 2:.0f} s onwards)")
out.append("")
out.append(f"{'':16}{'baseline':>12}{'after warm-up':>15}{'end of load':>13}{'final':>10}")
def row(label, key, unit=""):
    out.append(f"{label:16}{fmt(at(base, key)):>12}{fmt(at(early, key)):>15}{fmt(at(late, key)):>13}"
               f"{fmt(final[-1][key] if final else None):>10}  {unit}")
row("VmRSS", "rss", "KB")
row("RssAnon", "anon", "KB")
row("threads", "threads")
row("fds", "fds")
out.append(f"{'VmHWM':16}{'':12}{'':15}{fmt(load[-1]['hwm'] if load else None):>13}{'':10}  KB")
if live_tr:
    out.append(f"{'Lua heap (live)':16}{'':12}{fmt(live_tr['start']):>15}{fmt(live_tr['end']):>13}{'':10}  KB")
if reg_tr:
    out.append(f"{'Lua registry':16}{'':12}{fmt(reg_tr['start']):>15}{fmt(reg_tr['end']):>13}{'':10}  refs")
out.append("")
for tr, name in ((rss_tr, "VmRSS"), (anon_tr, "RssAnon")):
    if tr:
        out.append(f"{name} slope {tr['slope']:+.1f} ± {tr['se']:.1f} KB/min, growth {tr['growth']:+.0f} KB "
                   f"({100 * tr['growth'] / tr['start']:+.2f}%) after warm-up")
if live_tr:
    out.append(f"Lua heap slope {live_tr['slope']:+.2f} ± {live_tr['se']:.2f} KB/min")
out.append("")
for c_ok, label, detail in checks:
    out.append(f"  {'ok  ' if c_ok else 'FAIL'}  {label}{': ' + detail if detail else ''}")
out += [f"  note  {n}" for n in notes]
if fails:
    out.append("")
    out.append("first failures:")
    out += [f"  {f[:300]}" for f in fails[:20]]
if errors:
    out.append("")
    out.append("unexpected ERROR lines:")
    out += [f"  {e[:300]}" for e in errors[:20]]

def snapshot(name):
    counts = {}
    try:
        with open(os.path.join(out_dir, f"proc-{name}.txt")) as f:
            for line in f:
                n, _, what = line.strip().partition(" ")
                if what:
                    counts[what] = int(n)
    except (OSError, ValueError):
        return None
    return counts

snap_base, snap_final = snapshot("baseline"), snapshot("final")
if snap_base is not None and snap_final is not None:
    diff = [(k, snap_base.get(k, 0), snap_final.get(k, 0)) for k in sorted(set(snap_base) | set(snap_final))
            if snap_base.get(k, 0) != snap_final.get(k, 0)]
    out.append("")
    procs = f"tests/{os.path.basename(os.path.normpath(out_dir))}/proc-*.txt"
    out.append(f"fds/threads that differ between baseline and final ({procs}):"
               if diff else f"fds and threads at final are identical to baseline ({procs})")
    out += [f"  {k}: {a} -> {b}" for k, a, b in diff]
text = "\n".join(out) + "\n"
with open(summary_path, "w", encoding="utf-8") as f:
    f.write(text)
sys.stdout.write(text)
sys.exit(0 if ok else 1)
PY
}

if [ "$ANALYZE_ONLY" = 1 ]; then
    [ -f "$OUT/run.env" ] || { log "no finished run in tests/$OUT"; exit 2; }
    set -a; . "$OUT/run.env"; set +a
    export S_WARMUP=${SOAK_WARMUP_SECONDS:-} S_RSS_SLOPE=${SOAK_RSS_SLOPE_KB_MIN:-40} S_LUA_SLOPE=${SOAK_LUA_SLOPE_KB_MIN:-8}
    analyze
    exit $?
fi

MODULE=${MLPG_MODULE:-../build/release/ml_pgsql.so}
[ -f "$MODULE" ] || { log "module not found: $MODULE (build it first: ./build.sh)"; exit 2; }
MLPG_MODULE=$(cd "$(dirname "$MODULE")" && pwd)/$(basename "$MODULE")
export MLPG_MODULE

# arm64 on an x64 host (or the reverse) runs under emulation, several times slower
EMULATED=0
case "${MLPG_ARCH:-amd64}:$(uname -m)" in arm64:x86_64 | amd64:aarch64) EMULATED=1 ;; esac

if [ "$QUICK" = 1 ]; then MINUTES=${SOAK_MINUTES:-5}; else MINUTES=${SOAK_MINUTES:-30}; fi
LOAD_SECONDS=$(awk -v m="$MINUTES" 'BEGIN { printf "%d", m * 60 }')
RATE=${SOAK_RATE:-$([ "$EMULATED" = 1 ] && echo 250 || echo 2000)}
MODE=${SOAK_MODE:-module}
SAMPLE_SECONDS=${SOAK_SAMPLE_SECONDS:-10}
RUN_TIMEOUT=$((LOAD_SECONDS + (EMULATED ? 1800 : 900)))  # + setup, baseline, drain, final

compose() { docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.tls.yml "$@"; }

teardown() {
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
    local ids
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null || true)
    if [ -n "$ids" ]; then docker rm -f $ids >/dev/null 2>&1 || true; fi
}
trap teardown EXIT
trap 'log "interrupted"; exit 130' INT TERM

# Throwaway TLS material (see tests/run.sh)
if [ ! -f certs/server.key ]; then
    if command -v openssl >/dev/null; then
        certs/generate.sh
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/certs":/c -w /c --entrypoint sh alpine/openssl ./generate.sh
    fi
fi
command -v python3 >/dev/null || { log "python3 is required for the analysis"; exit 2; }

mkdir -p "$OUT"
rm -f "$OUT"/console.log "$OUT"/server.log "$OUT"/scripts.log "$OUT"/server_auth.log "$HOST" "$OUT"/samples.csv "$OUT"/summary.txt "$OUT"/proc-*.txt "$OUT"/heaptrack.*
teardown

log "module $MLPG_MODULE ($(sha256sum "$MLPG_MODULE" | cut -c1-16)), ${MLPG_ARCH:-amd64}$([ "$EMULATED" = 1 ] && echo ", emulated")"
log "load: $MINUTES min at $RATE ops/s, mode $MODE"
compose build -q mta
if [ "${SOAK_HEAPTRACK:-0}" = 1 ]; then
    # built on top of the image above; compose then runs it instead (docker-compose.yml)
    export MLPG_MTA_IMAGE=mlpg-mta-heaptrack:${MLPG_ARCH:-amd64}
    docker build -q --platform "${MLPG_PLATFORM:-linux/amd64}" --build-arg BASE="mlpg-mta:${MLPG_ARCH:-amd64}" \
        -t "$MLPG_MTA_IMAGE" -f mta/heaptrack.Dockerfile mta >/dev/null
    log "heaptrack: $MLPG_MTA_IMAGE, trace -> tests/$OUT/heaptrack.*"
fi
compose up -d --wait postgres >/dev/null

# pgsoak reads its configuration from this table (resources are mounted read-only)
cfg_sql="CREATE TABLE soak_config(key text PRIMARY KEY, value text NOT NULL);"
add_cfg() {
    [[ $1 =~ ^[A-Za-z]+$ ]] || { log "bad config key: $1"; exit 2; }
    cfg_sql+=" INSERT INTO soak_config VALUES ('$1', '${2//\'/\'\'}') ON CONFLICT (key) DO UPDATE SET value = excluded.value;"
}
add_cfg loadSeconds "$LOAD_SECONDS"
add_cfg rate "$RATE"
add_cfg mode "$MODE"
add_cfg sampleSeconds "$SAMPLE_SECONDS"
while IFS='=' read -r name value; do
    [ -n "$name" ] && add_cfg "${name#SOAK_CFG_}" "$value"
done < <(env | grep '^SOAK_CFG_' || true)
compose exec -T postgres psql -q -U mta -d mta -v ON_ERROR_STOP=1 -c "$cfg_sql" >/dev/null

# The server process, read from inside its container: one TSV row
# VmRSS, RssAnon, VmHWM, VmSize (KB), threads, open fds, CPU ticks (utime + stime).
read -r -d '' PROBE <<'SH' || true
p=$(pgrep -o -x mta-server64 || pgrep -o -f mta-server) || exit 3
set -- $(cut -d' ' -f14,15 /proc/$p/stat)
fds=$(ls /proc/$p/fd | wc -l)
awk -v fds="$fds" -v cpu="$(($1 + $2))" '
    /^VmRSS:/ { rss = $2 } /^RssAnon:/ { anon = $2 } /^VmHWM:/ { hwm = $2 } /^VmSize:/ { vsz = $2 } /^Threads:/ { thr = $2 }
    END { printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n", rss, anon, hwm, vsz, thr, fds, cpu }' /proc/$p/status
SH

# Open fds (by target) and threads (by name), kept for the baseline, drain and final phases so a
# difference can be attributed.
read -r -d '' SNAPSHOT <<'SH' || true
p=$(pgrep -o -x mta-server64 || pgrep -o -f mta-server) || exit 3
for f in /proc/$p/fd/*; do echo "fd $(readlink "$f" | sed -E 's/:\[[0-9]+\]$/:[]/')"; done | sort | uniq -c
for t in /proc/$p/task/*; do echo "thread $(cat "$t/comm")"; done | sed -E 's/pgsql-[0-9]+-/pgsql-N-/' | sort | uniq -c
SH
snapshot() { docker exec "$CTR" sh -c "$SNAPSHOT" >"$OUT/proc-$1.txt" 2>/dev/null || true; }

# Columns: epoch, console lines at the time (to merge with PGSOAK lines), probe row
sample() {
    local lines row
    lines=$(wc -l <"$CONSOLE")
    row=$(docker exec "$CTR" sh -c "$PROBE" 2>/dev/null) || return 1
    [ -n "$row" ] || return 1
    printf '%s\t%s\t%s\n' "$(date +%s.%N)" "$lines" "$row" >>"$HOST"
    last_row=$row
}

MTA_ENV=${SOAK_MTA_ENV-MALLOC_MMAP_THRESHOLD_=131072}  # set but empty: glibc's defaults
env_args=()
for kv in $MTA_ENV; do env_args+=(-e "$kv"); done
log "server running resource pgsoak (timeout ${RUN_TIMEOUT}s), env ${MTA_ENV:-(none)}, console -> tests/$CONSOLE"
: >"$CONSOLE"
timeout --kill-after=30 "$RUN_TIMEOUT" docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.tls.yml \
    run --rm --no-deps -T --name "$CTR" "${env_args[@]}" mta >"$CONSOLE" 2>&1 </dev/null &
run_pid=$!

last_phase="" next_at=0 next_log=0 last_row=""
while kill -0 "$run_pid" 2>/dev/null; do
    phase=$(grep -ao 'PGSOAK PHASE [a-z]*' "$CONSOLE" 2>/dev/null | tail -n 1 | cut -d' ' -f3 || true)
    now=$(date +%s)
    if [ "$phase" != "$last_phase" ] || [ "$now" -ge "$next_at" ]; then
        if sample; then
            if [ "$phase" != "$last_phase" ] || [ "$now" -ge "$next_log" ]; then
                read -r rss _ _ _ thr fds _ <<<"$last_row"
                stat=$(grep -ao 'PGSOAK STAT .*' "$CONSOLE" | tail -n 1 | sed -nE 's/.*"live":([0-9]+).*"ops":([0-9]+).*"rate":([0-9]+).*/lua=\1KB ops=\2 rate=\3\/s/p' || true)
                fails=$(grep -c 'PGSOAK FAIL' "$CONSOLE" || true)
                log "${phase:-start}: rss=${rss}KB threads=$thr fds=$fds $stat fails=$fails"
                next_log=$((now + 60))
            fi
            case "$phase" in baseline | drain | final) [ "$phase" != "$last_phase" ] && snapshot "$phase" ;; esac
            last_phase=$phase
            next_at=$((now + SAMPLE_SECONDS))
        fi
    fi
    sleep 1
done
rc=0
wait "$run_pid" || rc=$?
log "server exited with status $rc"

# Writes queued right before shutdown() must all have reached the database.
drained=$(compose exec -T postgres psql -U mta -d mta -tAc "SELECT count(*) FROM soak_drain" 2>/dev/null || echo "?")

cat >"$OUT/run.env" <<EOF
S_RC=$rc
S_DRAINED=$drained
S_EMULATED=$EMULATED
S_ARCH=${MLPG_ARCH:-amd64}
S_MODULE_SHA=$(sha256sum "$MLPG_MODULE" | cut -c1-16)
S_MTA_ENV=$(printf '%q' "$MTA_ENV")
EOF
set -a; . "$OUT/run.env"; set +a
export S_WARMUP=${SOAK_WARMUP_SECONDS:-} S_RSS_SLOPE=${SOAK_RSS_SLOPE_KB_MIN:-40} S_LUA_SLOPE=${SOAK_LUA_SLOPE_KB_MIN:-8}
analyze
