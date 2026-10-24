# ml_pgsql: PostgreSQL for MTA:SA servers

A native MTA:SA server module that gives Lua scripts asynchronous access to PostgreSQL through
libpq. Queries run on background threads, results come back on the main thread, and nothing
a script does can block the server unless it asks to (the `*Sync` functions).

- **Async by default**: callbacks, coroutine `await`, or fire-and-forget.
- **Fast**: queued queries are pipelined, so a burst of N queries costs about one network
  round trip instead of N. Results are converted straight from libpq buffers into Lua tables.
  See [Performance](#performance) for a comparison with MTA's built-in MySQL.
- **Safe parameters**: `$1, $2, ...` placeholders, sent separately from the SQL text. Lua
  tables become PostgreSQL arrays.
- **Typed results**: booleans, numbers, `bigint` without silent precision loss, `bytea` as
  binary strings, arrays as tables, NULL as nil.
- **Atomic transactions** in a single round trip.
- **Hardened**:
  - bounded queues, and a time budget for result delivery per server frame
  - reconnect with backoff, and a dead idle connection is caught before a query is sent
  - graceful drain when a resource stops or the server shuts down, so `onResourceStop`
    saves still land
  - safe with `unloadmodule`/`reloadmodule` and with resources that fail to start
  - TLS via a statically linked OpenSSL
  - only the module entry points are exported
  - no host packages needed

Supported servers: MTA:SA 1.6 on **Linux x64** and **Linux arm64**, with glibc 2.31 or newer
(Ubuntu 20.04+, Debian 11+, ...). Tested against PostgreSQL 18.

## Installation

1. Copy `ml_pgsql.so` into the server's module directory:
   - x64: `<server>/x64/modules/ml_pgsql.so`
   - arm64: `<server>/arm64/modules/ml_pgsql.so`
2. Add it to `mods/deathmatch/mtaserver.conf`:
   ```xml
   <module src="ml_pgsql.so"/>
   ```
3. Optionally restrict access with ACL rights such as `function.pgConnect`. Module functions go
   through MTA's ACL like built-in ones.

## Quick start

```lua
local db = assert(pgConnect("host=127.0.0.1 dbname=mta user=mta password=secret"))

-- callback
pgQuery(db, function(rows, err)
    if not rows then return outputDebugString(err, 1) end
    for _, row in ipairs(rows) do print(row.id, row.name) end
end, "SELECT id, name FROM accounts WHERE level >= $1", 3)

-- fire and forget (failures are printed as warnings with the calling file:line)
pgExec(db, "UPDATE accounts SET last_seen = now() WHERE id = $1", accountId)

-- coroutine style
coroutine.wrap(function()
    local rows, err = pgQueryAwait(db, "SELECT count(*) AS n FROM accounts")
    print(rows and rows[1].n or err)
end)()

-- atomic transaction (one round trip; all or nothing)
pgTransaction(db, {
    {"UPDATE wallets SET balance = balance - $2 WHERE id = $1", from, amount},
    {"UPDATE wallets SET balance = balance + $2 WHERE id = $1", to, amount},
    {"INSERT INTO transfers(src, dst, amount) VALUES ($1, $2, $3) RETURNING id", from, to, amount},
}, function(results, err)
    if results then print("transfer id", results[3][1].id) end
end)
```

Every function that takes a connection is also a method: `db:query(cb, sql, ...)`,
`db:exec(...)`, `db:queryAwait(...)`, `db:querySync(...)`, `db:transaction(...)`,
`db:transactionAwait(...)`, `db:transactionSync(...)`, `db:stats()`, `db:close()`.

## API

### `pgConnect(conninfo [, options]) -> connection | false, error`

`conninfo` is a libpq connection string (`"host=... port=... dbname=... user=... password=..."`)
or URI (`"postgresql://user:pass@host:5432/db?sslmode=verify-full&sslrootcert=/path/ca.crt"`).
By default this blocks until the first connection is established (bounded by
`connectTimeout`) so bad credentials are reported immediately. Pass `lazy = true` to return at
once.

**Connect once and keep the connection**, typically from the resource's start; it closes by
itself when the resource stops. Don't call `pgConnect` per query, command or player event. Each
call blocks the server through the TCP and TLS handshake and authentication (unless `lazy`),
starts a thread per pooled connection, and makes PostgreSQL start a backend process. A server
that keeps opening connections also keeps growing in memory, see
[Memory with many short-lived connections](#behaviour-and-guarantees).

| option | default | meaning |
|---|---|---|
| `poolSize` | `1` | Connections (one thread each), 1–64. With 1, queries run strictly in submission order, like MTA's `dbConnect`. With more, independent queries run in parallel and order is only guaranteed within one transaction. |
| `pipeline` | `true` | Send queued queries together. Each query is still its own implicit transaction. |
| `batchSize` | `64` | Max queries per pipelined round trip. |
| `maxQueue` | `100000` | Limit on outstanding queries: queued, running, or finished but not yet delivered to Lua. Beyond it, calls return `false, "query queue is full..."` instead of growing memory. |
| `connectTimeout` | `10000` | ms, per connection attempt. |
| `queryTimeout` | `0` | ms, server-side `statement_timeout` (0 = none). |
| `syncTimeout` | `30000` | ms, max time a `*Sync` call blocks the server. |
| `drainTimeout` | `10000` | ms, how long queued queries may keep running after `pgClose`, resource stop or server shutdown before they are cancelled. |
| `lazy` | `false` | Don't wait for the first connection. |
| `int64` | `"auto"` | `bigint`: `"auto"` gives a number when exactly representable (abs ≤ 2^53), otherwise a string. `"number"` always gives a number (may lose precision). `"string"` always gives a string. |
| `numeric` | `"number"` | `numeric`/`decimal` as `"number"` or exact `"string"`. |
| `applicationName` | `"mta:<resource>"` | Shown in `pg_stat_activity`. |

Defaults applied unless the connection string says otherwise:
- `client_encoding=UTF8`
- TCP keepalives (30 s idle, 10 s interval, 3 probes)
- `tcp_user_timeout=60000`, so a silently dropped network path is detected instead of hanging
  for the kernel's ~15 minutes

### `pgQuery(conn, callback, sql, ...) -> true | false, error`

Runs `sql` with parameters `...` (`$1`, `$2`, ...) and later calls
`callback(rows, nil, affectedRows)` on success or `callback(false, errorMessage, sqlstate)` on
failure. `rows` is an array of row tables keyed by column name.

### `pgExec(conn, sql, ...) -> true | false, error`

Fire and forget. Failures are reported as debug warnings that include the calling `file:line`.

### `pgQueryAwait(conn, sql, ...) -> rows, nil, affected | false, error, sqlstate`

Must be called inside a coroutine. Suspends the coroutine until the result arrives; the rest of
the server keeps running. Don't resume a coroutine yourself while it is waiting, and don't call
it inside `pcall` (Lua 5.1 cannot yield across `pcall`; you get an error).

### `pgQuerySync(conn, sql, ...) -> rows, nil, affected | false, error, sqlstate`

Blocks the whole server until the result arrives (max `syncTimeout`). Meant for startup code.
It runs after everything already queued on the connection.

### `pgTransaction(conn, statements, callback) -> true | false, error`
### `pgTransactionAwait(conn, statements)` / `pgTransactionSync(conn, statements)`

`statements` is an array whose entries are SQL strings or `{sql, param1, param2, ...}` tables
(`nil` holes are allowed). All statements run atomically in one round trip: if one fails, none
of them take effect.
- Success: `callback(results, nil, affected)`, where `results[i]` is the rows of statement `i`
  and `affected[i]` its affected-row count.
- Failure: `callback(false, error, sqlstate, failedStatementIndex)`.

The module wraps the statements in `BEGIN … COMMIT` itself and runs them as one pipelined
segment, so statements that cannot run in a transaction block (`VACUUM`, `CREATE DATABASE`)
fail cleanly. An error raised at `COMMIT` (a deferred constraint, a serialization failure)
fails the transaction, with `failedStatementIndex` set to nil. `BEGIN`/`COMMIT`/`ROLLBACK`/
`SAVEPOINT`/`COPY` are rejected inside `statements`.

### `pgClose(conn) -> boolean`

Stops accepting queries. Already queued ones still run and their callbacks still fire, then
the connections close. You rarely need this: connections also close automatically when the
owning resource stops (after `onResourceStop`, so final saves complete) and when the connection
object is garbage-collected.

### `pgStats(conn) -> table`

`poolSize, connected, queued, inFlight, outstanding, submitted, succeeded, failed, reconnects,
roundTrips, avgLatencyMs`.

### Helpers

- `pgQuoteIdent(name)`: quotes an identifier (`my"table` → `"my""table"`) for dynamic table or
  column names. Values should always be parameters instead.
- `pgBytea(binaryString)`: encodes binary data for a `bytea` parameter. Text parameters
  cannot contain NUL bytes.
- `PG_NULL`: SQL NULL inside table parameters. Plain `nil` works in argument lists.
- `pgVersion() -> moduleVersion, libpqVersion, tlsLibrary`: `tlsLibrary` is `"OpenSSL"`

## Types

| PostgreSQL | Lua |
|---|---|
| `NULL` | `nil` (the key is absent, like MTA's `dbPoll`) |
| `boolean` | boolean |
| `smallint`, `integer`, `oid`, `real`, `double precision` | number (`NaN`/`±Infinity` included) |
| `bigint` | number or string, see `int64` |
| `numeric` | number or string, see `numeric` |
| `bytea` | binary string |
| arrays of the above and of `text`, `varchar`, `uuid`, `json(b)`, `timestamp(tz)`, `date`, ... | table (nested for multi-dimensional; NULL elements are nil) |
| everything else (`text`, `json`, `timestamp`, `uuid`, `interval`, ...) | string |

Parameters:
- `nil`/`PG_NULL` → NULL
- booleans → `true`/`false`
- integral numbers → integer text; other numbers → shortest round-trip decimal
- strings → passed as-is
- array tables → PostgreSQL array literals (`WHERE id = ANY($1)`)

Tables with non-integer keys are rejected; use `toJSON` for objects.

## Behaviour and guarantees

- **Ordering.** With `poolSize = 1` (the default), queries execute in the order they were
  issued, across `pgExec`, `pgQuery`, `*Await` and `*Sync`. With more connections, use one
  `pgTransaction` for statements that must run in order. Session settings (`SET ...`) apply to
  only one connection of a pool.
- **Transactions span exactly one call.** A connection is shared by every query of the
  resource, so a transaction must not stay open between calls:
  - `pgExec(db, "BEGIN")` raises an error; use `pgTransaction`, or send the whole
    `BEGIN; ...; COMMIT;` block as one string.
  - If a script leaves a transaction block open, the module rolls it back and the call fails
    with SQLSTATE `25000`.
  - A script that fails in the middle is rolled back too, so it never leaves the session in a
    failed transaction (`25P02`).
- **Pipelining.** Queued queries are written to the socket together, and each still gets its
  own implicit transaction, so one failing query never affects its neighbours. On one
  connection this is limited to roughly one server packet per query. Use `pgTransaction` for
  bulk writes, or `poolSize > 1` for more parallelism.
- **Delivery.** Callbacks and coroutine resumes run in the server's `DoPulse`, at most about
  20 ms worth per frame; the rest continues next frame.
  - Callback errors are printed as debug errors and never affect other queries.
  - `pgExec` failure warnings are limited to 20 per second per resource, followed by a count of
    the ones not shown.
  - Like any Lua code, callbacks are subject to MTA's "infinite running script" watchdog. The
    module re-arms its instruction counter before each callback. A resource whose only
    activity is several heavy callbacks (millions of Lua instructions each) without any MTA
    event or timer in between can still accumulate watchdog time.
- **Connection loss.**
  - A session the server closed while idle (restart, `idle_session_timeout`,
    `pg_terminate_backend`) is detected and replaced before the next query is sent.
  - Queries that were never sent are retried on a fresh connection, up to 3 times.
  - Queries already sent when a connection breaks fail with SQLSTATE `08006`. They are never
    retried, because they may have run.
  - A disconnected connection never takes work while another connection of the pool is up. It
    reconnects in the background, backing off from 250 ms to 5 s.
  - When no connection is available, queries fail fast with `08001` instead of piling up.
- **Resource stop.** `pgExec` calls made in `onResourceStop` still reach the database. Pending
  callbacks of a stopped resource are dropped, and its connections close once their queues are
  empty (bounded by `drainTimeout`).
- **Server shutdown / `unloadmodule`.**
  - Queued work drains, bounded by `drainTimeout`. Running queries are then cancelled
    server-side.
  - Results that still arrive within a second of the cancel are reported normally; anything
    still unanswered fails with `08006` ("outcome unknown"), never with a misleading "cancelled".
  - All threads are joined before `ShutdownModule` returns.
  - After `unloadmodule`, connection objects become inert, pending callbacks are dropped, and
    functions a script kept in local variables raise "the ml_pgsql module is not loaded". The
    module stays mapped (`-z nodelete`), so such calls cannot reach unmapped code.
  - A hanging DNS server cannot stall connects or shutdown. libpq resolves host names with a
    blocking `getaddrinfo`, so the module first looks names up on a helper thread and gives up
    at `connectTimeout` or on shutdown.
- **Errors.** Programming errors (wrong argument types, unsupported parameter values) raise Lua
  errors. Runtime problems (connection closed, queue full, server errors) are returned as
  values. Messages are PostgreSQL's, plus a SQLSTATE code (e.g. `23505` unique violation).
  Module-side states: `08001` cannot connect, `08006` connection lost mid-query, `57014`
  cancelled because the connection was closed.
- **Scripts with several statements.** Parameterless SQL containing several `;`-separated
  commands is sent with the simple query protocol, so migration scripts work through `pgExec`.
  `COPY ... FROM STDIN` is rejected cleanly and the connection stays usable.
- **Memory with many short-lived connections.** The module frees everything it allocates
  (see [Memory soak](#memory-soak)). Even so, RSS keeps growing on a server that opens new
  connections all the time (for example a `pgConnect` per command) when they move large values
  (big results, `bytea` of hundreds of KB). This is glibc's allocator: once large blocks have
  been freed, it raises its mmap and trim thresholds, and the buffers of each new connection
  then stay cached in the per-thread malloc arenas. At one new connection per second it measured
  about +0.6 MB/min for the whole 30-minute test. Occasional new connections, from reconnects or
  resource restarts, add a few MB that then level off. If your server cannot avoid churning
  connections, start it with `MALLOC_ARENA_MAX=2` or `MALLOC_MMAP_THRESHOLD_=131072` in its
  environment: either kept RSS flat in the same test.

## Performance

`tests/bench.sh` runs the same workloads through MTA's built-in `dbConnect("mysql")` and through
this module, inside the official MTA 1.6 server. Both databases (MySQL 8.4, PostgreSQL 18) ran
in Docker on the same machine with default settings. Full tables, including variants, are in
[tests/bench-results.md](tests/bench-results.md).

| workload | MTA MySQL `dbConnect` | ml_pgsql, 1 connection | ml_pgsql, `poolSize=4` |
|---|---|---|---|
| 20,000 single-row INSERTs, fire-and-forget | ~7,100 /s | **~10,400 /s** | **~41,000 /s** |
| 20,000 primary-key SELECTs with callbacks | ~6,800 /s | **~10,500 /s** | **~42,500 /s** |
| main-thread time to issue 20,000 queries | 28–44 ms | **6–22 ms** | 7–16 ms |
| 5,000-row insert as one transaction | ~710 ms | **~51 ms** | ~57 ms |
| 20 × SELECT of 10,000 rows | ~1.5 M rows/s | ~1.5 M rows/s | **~3.2 M rows/s** |
| query → callback → next query | 1 server frame | 1 server frame | 1 server frame |
| blocking round trip (`dbPoll(qh, -1)` / `pgQuerySync`) | ~218 µs | ~227 µs | – |

- **Bursts:** the module is about 1.5× faster on one connection and about 6× faster with four.
  Pipelining sends queued queries in one round trip; MTA's driver does one query per round trip
  on a single thread.
- **Transactions:** `pgTransaction` is about 14× faster, because all its statements go out in a
  single round trip instead of one `dbExec` per row.
- **Main thread:** issuing queries costs a fraction of `dbExec`/`dbQuery`, so the server frame
  stays at the normal 11 ms during bursts. MySQL's issue loops stretched frames to 30–45 ms.
  Converting large results is about 35% cheaper than MTA's.
- **Callback latency:** both drivers deliver results once per server frame. That is about 40 ms
  on an idle MTA server and 10 ms at `server_logic_fps_limit=100`.
- **Single blocking round trip:** within about 10 µs of MySQL, mostly protocol difference (the
  plain `psql` and `mysql` clients differ by about the same).

These numbers come from Docker on WSL2, where a network round trip costs ~0.19 ms. On a real
network, pipelining gains more, because each saved round trip costs more.

## Releases and CI

Prebuilt `ml_pgsql.so` for Linux x64 and arm64 are attached to each
[GitHub release](../../releases), with `SHA256SUMS`, the third-party license texts and this
README.

GitHub Actions (`.github/workflows/`):
- **`build.yml`**, on every push and pull request, for both architectures natively (arm64 on
  GitHub's `ubuntu-24.04-arm` runners):
  - builds the module and verifies it with `tools/check-binary.sh`: exported symbols,
    dependencies, glibc version, `nodelete`
  - runs the integration suite in the official MTA server
- **Releases**: pushing a tag `X.Y.Z` (or `vX.Y.Z`) that matches `MLPG_VERSION_STRING` in
  `src/module.h` publishes a release with both archives.
- **`sanitizers.yml`**: the full sanitizer matrix, manual trigger only.

Before tagging a release, run these manually; CI runs neither:
1. the sanitizer harness: the `sanitizers.yml` workflow, or `tests/harness/run.sh` locally
2. the memory soak: `tests/soak.sh` (30 minutes) on x64. Optionally also on arm64:
   `MLPG_PLATFORM=linux/arm64 MLPG_ARCH=arm64 MLPG_MODULE=../build/arm64/ml_pgsql.so tests/soak.sh`.
   Under emulation it uses a lower rate.

## Building

Requires Docker. The build image is Ubuntu 20.04 (GCC 10). OpenSSL 3.5 and libpq 18 are built
from verified source tarballs and linked statically.

```sh
./build.sh          # -> build/release/ml_pgsql.so  (Linux x64)
./build.sh arm64    # -> build/arm64/ml_pgsql.so    (Linux arm64, via emulation if needed)
```

## Testing

- `tests/run.sh`: 44 integration tests inside the official MTA server, against PostgreSQL 18 with
  TLS. Areas:
  - types and parameters, errors
  - callbacks, await and sync calls, transactions and their atomicity
  - ordering, pipelining, backpressure and timeouts
  - reconnect after `pg_terminate_backend`
  - resource stop/restart with queries in flight, garbage collection, ACL
  - TLS `verify-full`

  Finally it queues 3000 writes, calls `shutdown()`, and checks from outside the server that
  every row arrived. On arm64 run it as:
  `MLPG_PLATFORM=linux/arm64 MLPG_ARCH=arm64 MLPG_MODULE=../build/arm64/ml_pgsql.so tests/run.sh`.
- `tests/harness/run.sh`: a stand-in MTA host built around MTA's own Lua. It loads the module
  exactly as the server does (no global Lua symbols, the same hook order, VMs destroyed without
  hooks, `unloadmodule`/`reloadmodule`). It runs 8 scenarios under ASan+UBSan, TSan, valgrind
  and a plain build:
  - full API coverage
  - await/GC interplay
  - sync calls and limits
  - connection failures through a fault-injecting proxy
  - lifecycle
  - a 100k-operation stress run with random stops, reloads and network cuts
  - a soak test that checks RSS, thread and fd counts stay flat
  - a hanging DNS server

  All pass, with no suppressions for module code.
- `tests/soak.sh`: memory soak of the release build in the official MTA server, see below.
- `tests/bench.sh`: the MySQL comparison; writes `tests/bench-results.md`.

### Memory soak

`tests/soak.sh` (30 minutes; `--quick` for 5) runs the release `ml_pgsql.so`, with its static
libpq and OpenSSL, inside `mta-server64` under a steady load from resource `pgsoak`, all over
TLS. The load runs at about 2,000 operations/s:
- callbacks, coroutine awaits and the occasional sync call
- transactions, a third of them failing on purpose
- 10k–20k-row results, `bytea` up to 256 KB, array parameters, and queries that error
- pools of 1 and 4 connections, plus short-lived connections that are closed with queries in
  flight or left to the garbage collector
- a backend killed every 20 s, and a child resource stopped with queries in flight every 15 s

Every result is checked, and all writes are counted against the database at the end.

The server runs with `MALLOC_MMAP_THRESHOLD_=131072`. glibc then returns large blocks to the
system as soon as they are freed, so RSS follows what is actually allocated. With glibc's
defaults, every new connection (reconnects, child resources) leaves memory cached in the malloc
arenas until RSS levels off. Over 30 minutes that is +4.5 MB after the warm-up, which fails the
checks below although nothing leaks. `SOAK_MTA_ENV=` (empty) runs with the defaults anyway.

From outside the server, every 10 s, the script reads RSS and thread count from
`/proc/<pid>/status` and counts `/proc/<pid>/fd`. It merges these with the resource's
Lua-side numbers (heap after a full GC, registry size, `pgStats` outstanding counts, operation
counts) into `tests/out-soak/samples.csv`, and writes the verdict to
`tests/out-soak/summary.txt`. The first 5 minutes (at most 20% of the run) are warm-up.
After that the run fails if any of these hold:
- RSS grows by more than max(4 MB, 3%), or its trend over the second half rises by more than
  40 KB/min and is clearly above zero
- threads or fds are not back at their baseline once every pool is closed. The baseline is
  taken with the module loaded and no connection open, after MTA's own startup requests finish.
- the Lua heap or registry trends upward, or a pool's outstanding count does not drain to 0
- a result is wrong, an unexpected error is logged, the server crashes, or writes queued
  right before `shutdown()` are lost

The RSS checks catch any allocation leaked per operation: glibc's smallest block is 32 bytes,
which at this rate is 3.8 MB/min. They also catch leaks of about 10 KB or more per new
connection. Smaller ones need heaptrack.

`SOAK_MODE=control` runs the same Lua-side churn without module calls. `SOAK_HEAPTRACK=1`
runs the server under heaptrack. `--analyze` re-evaluates a finished run. The header of
`tests/soak.sh` lists the remaining knobs.

Findings on x64 (MTA 1.6, glibc 2.31):
- Under heaptrack the live heap stayed flat for the whole load, and nothing left at exit came
  from the module, libpq or OpenSSL.
- The control run's RSS was flat.
- With `MALLOC_MMAP_THRESHOLD_=131072`, RSS stayed within ±1 MB of 62 MB through the load and
  fell to 57 MB once the pools closed.
- With glibc's defaults, RSS rose 4.5 MB after the warm-up and levelled off at about 86 MB. A
  run with a third of the reconnects and child-resource cycles ended at the same level.
- RSS creep at high connection churn comes from glibc, see
  [Memory with many short-lived connections](#behaviour-and-guarantees).

## Design notes

- **Lua symbols.** MTA loads `deathmatch.so`, which contains Lua, without `RTLD_GLOBAL`, so a
  module cannot link against Lua. A private Lua copy would corrupt shared tables (Lua 5.1's
  static `dummynode`). The module resolves the server's own Lua API at load time instead, from
  the library that implements the module manager.
- **Lua errors.** MTA's Lua reports errors with `longjmp`, which skips C++ destructors. Every
  binding first validates arguments (which may raise), then does its C++ work using only Lua
  calls that cannot raise, then pushes results.
- **Threads and memory.**
  - Threads never touch Lua. Results stay in libpq's `PGresult` buffers until the main thread
    converts them.
  - Each connection is owned by one thread running non-blocking libpq, which never blocks
    longer than 50 ms without checking for shutdown.
- **VM lifecycle.**
  - Connections are owned by the resource that created them, and only that resource's VM can use
    them. Handles carry a magic value and a size check, so a userdata given our metatable via
    `debug.setmetatable` is rejected.
  - Callbacks are tied to the resource's VM. Besides the stop hooks, each VM holds a sentinel
    userdata whose finalizer runs inside `lua_close`. That covers MTA destroying the VM of a
    resource whose start was aborted, which happens without calling the module. A once-a-second
    `GetResourceFromName` check is a second line of defence.
  - On unload, metatables in surviving VMs are neutralised so nothing calls into unmapped code.

## License

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled third-party components:
- libpq: PostgreSQL License
- OpenSSL: Apache 2.0
- Lua headers: MIT
- MTA's module SDK header: zlib-style license that excludes commercial applications

## Not included

`LISTEN/NOTIFY`, `COPY` streaming, interactive (multi-round-trip) transactions and Windows
builds are not supported in this version.
