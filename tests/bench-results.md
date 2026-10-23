# ml_pgsql vs MTA built-in MySQL: benchmark results

Generated 2026-10-23 21:43 UTC by `tests/bench.sh`: 2 run(s), each from fresh databases. Each cell shows one value per run (`run 1 / run 2 / ...`).

Status: all correctness checks passed.

## Environment

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X3D 16-Core Processor (32 logical CPUs), 47 GiB RAM |
| OS | Debian GNU/Linux 12 (bookworm), kernel Linux 6.18.54.1-microsoft-standard-WSL2, Docker 29.9.1 |
| MTA server | 1.6-release-24153 (official Linux x64 build, `tests/mta/Dockerfile`) |
| ml_pgsql | 1.0.0, libpq 180006; `ml_pgsql.so` sha256 751bc9a52de5a908…, built 2026-10-23 21:38:26 UTC |
| PostgreSQL | 18.6 (Debian 18.6-1.pgdg13+2) (`postgres:18`, data on tmpfs, default settings) |
| MySQL | 8.4.13 (`mysql:8.4`, data on tmpfs, default settings) |
| Server frames | `server_logic_fps_limit=100` during the run (≈10 ms frames); MTA's default on an empty server is ≈40 ms frames (see `seq_select_default_fps`) |

Reference without MTA (client container on the same Docker network, sequential PK SELECTs):

- `psql`: 189 / 173 µs per round trip; `mysql` CLI: 162 / 157 µs per round trip
- `pgbench -M extended`: 5780 / 6142 queries/s with one query per round trip; 10319 / 10873 queries/s pipelined 64 deep with one Sync per query (ml_pgsql's pipelining model)

## Backends

| id | configuration |
|---|---|
| `mysql` | MySQL dbConnect defaults (batch=1) |
| `pg` | ml_pgsql poolSize=1, pipeline |
| `mysql_b0` | MySQL batch=0 (autocommit per statement) |
| `pg_nopipe` | ml_pgsql poolSize=1, pipeline=false |
| `pg_pool4` | ml_pgsql poolSize=4, pipeline |
| `mysql_multi` | MySQL multi_statements=1 (bulk as one multi-statement dbQuery) |

## Results

### a. Single-row INSERT, fire-and-forget (N=20000)

`dbExec` vs `pgExec` in one loop, timed until a fence query (or `pgStats` for poolSize>1) shows that all rows are written. *Submit loop* is main-thread time spent issuing the burst.

| backend | ops/s | total ms | submit loop ms | round trips | frame p99 ms | frame max ms |
|---|---:|---:|---:|---:|---:|---:|
| `mysql` | 7,236 / 6,923 | 2,764 / 2,889 | 39 / 44 | – | 11 / 11 | 39 / 44 |
| `pg` | 10,735 / 10,163 | 1,863 / 1,968 | 18 / 22 | 314 / 314 | 11 / 11 | 18 / 22 |
| `mysql_b0` | 3,773 / 3,824 | 5,301 / 5,230 | 36 / 34 | – | 11 / 11 | 36 / 35 |
| `pg_nopipe` | 6,242 / 6,268 | 3,204 / 3,191 | 19 / 16 | 20,001 / 20,001 | 11 / 11 | 19 / 16 |
| `pg_pool4` | 41,494 / 40,650 | 482 / 492 | 16 / 16 | 330 / 330 | 17 / 16 | 17 / 16 |

### b. Point SELECT by primary key, burst (N=20000)

All queries issued in one loop with one shared callback (`dbQuery` + `dbPoll(qh, 0)` vs `pgQuery`), timed until the last callback.

| backend | ops/s | total ms | submit loop ms | round trips | frame p99 ms | frame max ms |
|---|---:|---:|---:|---:|---:|---:|
| `mysql` | 6,959 / 6,649 | 2,874 / 3,008 | 28 / 31 | – | 11 / 11 | 29 / 33 |
| `pg` | 10,466 / 10,526 | 1,911 / 1,900 | 8 / 6 | 314 / 314 | 11 / 11 | 11 / 11 |
| `mysql_b0` | 6,859 / 7,000 | 2,916 / 2,857 | 29 / 29 | – | 11 / 11 | 31 / 32 |
| `pg_nopipe` | 6,289 / 5,900 | 3,180 / 3,390 | 8 / 7 | 20,000 / 20,000 | 11 / 11 | 11 / 11 |
| `pg_pool4` | 42,463 / 42,553 | 471 / 470 | 7 / 7 | 330 / 330 | 11 / 11 | 11 / 11 |

### c. Sequential round trips through callbacks (N=1000)

Each query is issued from the previous query's callback. Both drivers deliver results once per server frame, so this measures frame pacing.

| backend | avg ms | p50 ms | p99 ms | max ms |
|---|---:|---:|---:|---:|
| `mysql` | 10.00 / 9.99 | 10 / 10 | 11 / 11 | 11 / 11 |
| `pg` | 10.00 / 10.00 | 10 / 10 | 11 / 11 | 11 / 11 |
| `mysql_b0` | 10.00 / 10.00 | 10 / 10 | 11 / 11 | 11 / 11 |
| `pg_nopipe` | 10.00 / 10.00 | 10 / 10 | 11 / 11 | 11 / 11 |
| `pg_pool4` | 10.00 / 10.00 | 10 / 10 | 11 / 11 | 11 / 11 |

### c'. Same at MTA's default frame pacing (N=100)

| backend | avg ms | p50 ms | p99 ms | max ms |
|---|---:|---:|---:|---:|
| `mysql` | 40.25 / 40.13 | 40 / 40 | 41 / 41 | 41 / 41 |
| `pg` | 40.23 / 40.23 | 40 / 40 | 41 / 41 | 41 / 41 |

### c''. Blocking round trips (N=2000)

`dbPoll(dbQuery(...), -1)` vs `pgQuerySync`, in chunks of 250 per frame. This is the real driver round trip, without frame pacing.

| backend | µs/query | ops/s | frame p99 ms | frame max ms |
|---|---:|---:|---:|---:|
| `mysql` | 213 / 222 | 4,706 / 4,505 | 56 / 58 | 56 / 58 |
| `pg` | 231 / 223 | 4,329 / 4,484 | 60 / 57 | 60 / 57 |
| `mysql_b0` | 209 / 217 | 4,785 / 4,619 | 54 / 57 | 54 / 57 |
| `pg_nopipe` | 233 / 229 | 4,292 / 4,367 | 61 / 59 | 61 / 59 |
| `pg_pool4` | 247 / 241 | 4,049 / 4,149 | 64 / 63 | 64 / 63 |

### d. Large result: 20 × SELECT of 10000 rows × 4 columns, burst

*To-Lua* is main-thread time per result until it is a Lua table: ml_pgsql converts before calling the callback, MTA converts in `dbPoll`.

| backend | rows/s | total ms | to-Lua avg ms | to-Lua max ms | frame p99 ms | frame max ms |
|---|---:|---:|---:|---:|---:|---:|
| `mysql` | 1,515,152 / 1,459,854 | 132 / 137 | 3.35 / 3.55 | 5 / 6 | 15 / 17 | 15 / 17 |
| `pg` | 1,503,759 / 1,449,275 | 133 / 138 | 2.25 / 2.20 | 4 / 5 | 21 / 21 | 21 / 21 |
| `mysql_b0` | 1,492,537 / 1,470,588 | 134 / 136 | 4.00 / 4.55 | 7 / 7 | 31 / 22 | 31 / 22 |
| `pg_nopipe` | 1,324,503 / 1,315,789 | 151 / 152 | 2.15 / 2.50 | 3 / 5 | 11 / 10 | 11 / 10 |
| `pg_pool4` | 2,941,176 / 3,571,429 | 68 / 56 | 2.55 / 2.30 | 4 / 4 | 21 / 21 | 21 / 21 |

### e. Bulk insert in one transaction (5000 rows, 5 repetitions)

MySQL: `START TRANSACTION`, N × `dbExec`, `COMMIT` on the ordered connection, or one multi-statement `dbQuery` (`multi_statements=1`). ml_pgsql: `pgTransaction` with N statements.

| backend | method | ms/tx | rows/s | submit ms | frame p99 ms | frame max ms |
|---|---:|---:|---:|---:|---:|---:|
| `mysql` | ordered dbExec | 691.8 / 726.2 | 7,228 / 6,885 | 11.4 / 10.8 | 11 / 11 | 14 / 15 |
| `pg` | pgTransaction | 51.0 / 51.2 | 98,039 / 97,656 | 4.6 / 4.2 | 11 / 11 | 11 / 11 |
| `mysql_b0` | ordered dbExec | 695.8 / 685.8 | 7,186 / 7,291 | 10.8 / 10.4 | 11 / 11 | 12 / 12 |
| `pg_nopipe` | pgTransaction | 52.6 / 50.8 | 95,057 / 98,425 | 4.4 / 4.6 | 11 / 11 | 11 / 11 |
| `pg_pool4` | pgTransaction | 61.4 / 53.0 | 81,433 / 94,340 | 5.0 / 4.6 | 11 / 11 | 11 / 11 |
| `mysql_multi` | multi-statement dbQuery | 382.4 / 351.8 | 13,075 / 14,213 | 9.4 / 8.4 | 11 / 11 | 12 / 11 |

### f. Idle server frames (no database work)

Default pacing. The *frame* columns above are gaps between consecutive server frames, measured with `setTimer(fn, 0, 0)` while the workload ran; a long frame means the main thread was blocked.

| backend | frame avg ms | frame p99 ms | frame max ms |
|---|---:|---:|---:|
| `server` | 40.2 / 40.1 | 41 / 41 | 41 / 41 |

### f'. Idle server frames at the benchmark's fps limit

| backend | frame avg ms | frame p99 ms | frame max ms |
|---|---:|---:|---:|
| `server` | 10.0 / 10.0 | 11 / 11 | 11 / 11 |

## Correctness

Every workload verified its results (row counts after inserts, one row per point SELECT with the expected id sum, result shape of large SELECTs, no failed queries). No failures.

Raw output: `tests/out-bench/bench-20261023T213857Z-run1.txt`, `tests/out-bench/bench-20261023T213857Z-run2.txt`
