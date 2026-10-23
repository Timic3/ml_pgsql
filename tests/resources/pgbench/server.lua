--[[
pgbench: ml_pgsql vs MTA's built-in MySQL driver (dbConnect/dbExec/dbQuery/dbPoll), measured
inside the real MTA server. Started by tests/bench.sh (MLPG_SUITE=bench).

Output:
  [bench] ...        human readable progress and a summary table
  BENCHMETA {json}   versions and configuration
  BENCHJSON {json}   one line per (backend, workload) result
  BENCHFAIL msg      a correctness check failed (row counts, errors, timeouts)
  BENCHERROR msg     the benchmark script itself crashed
  BENCHDONE {json}   end marker (failure count); the server shuts down right after

Timing uses getTickCount() (1 ms resolution), so everything is measured over many operations.
Server frames are observed with a setTimer(fn, 0, 0) timer, which runs once at the start of
every server frame (before ml_pgsql's pulse and before MTA's database pulse, which is where
both drivers run result callbacks).
]]

local CFG = {
    pgConninfo = "host=postgres port=5432 dbname=mta user=mta password=mta",
    myHost = "dbname=mta;host=mysql;port=3306",
    myUser = "mta",
    myPass = "mta",

    -- server_logic_fps_limit while benchmarking (max allowed is 100 -> 10 ms frames). An empty
    -- server otherwise idles 40 ms per frame (threadnet auto idle_sleep_time), which makes every
    -- callback-driven round trip cost a full 40 ms frame for both drivers. Busy servers with
    -- players run frames much faster than that, so 100 fps is the more representative setting.
    fpsLimit = 100,

    nInsert = 20000,      -- a. fire-and-forget single-row INSERTs
    seedRows = 20000,     -- rows seeded for the SELECT workloads
    nPoint = 20000,       -- b. point SELECTs issued in one burst (ids 1..nPoint, <= seedRows)
    nSeq = 1000,          -- c. sequential callback round trips at fpsLimit
    nSeqDefault = 100,    -- c'. the same at MTA's default frame pacing (fps limit 0)
    nSync = 2000,         -- c''. blocking round trips (dbPoll(qh, -1) vs pgQuerySync)
    syncChunk = 250,      --      per server frame, to stay far below MTA's 5 s script limit
    largeRows = 10000,    -- d. rows per large SELECT (4 columns)
    largeReps = 20,       --    issued in one burst
    bulkRows = 5000,      -- e. rows per bulk transaction
    bulkReps = 5,

    settleMs = 300,       -- idle time before each measured section
    waitTimeoutMs = 120000,
    watchdogMs = 25 * 60 * 1000,
}

-- Backends, in run order (interleaved so drift on the host affects both sides alike).
--   only: run just these workloads. seqDefault: also run c' (default frame pacing).
local BACKENDS = {
    { id = "mysql", kind = "mysql", options = "", seqDefault = true,
      label = "MySQL dbConnect defaults (batch=1)" },
    { id = "pg", kind = "pg", opts = {}, seqDefault = true,
      label = "ml_pgsql poolSize=1, pipeline" },
    { id = "mysql_b0", kind = "mysql", options = "batch=0",
      label = "MySQL batch=0 (autocommit per statement)" },
    { id = "pg_nopipe", kind = "pg", opts = { pipeline = false },
      label = "ml_pgsql poolSize=1, pipeline=false" },
    { id = "pg_pool4", kind = "pg", opts = { poolSize = 4 },
      label = "ml_pgsql poolSize=4, pipeline" },
    { id = "mysql_multi", kind = "mysql", options = "multi_statements=1", multi = true, only = { bulk_tx = true },
      label = "MySQL multi_statements=1 (bulk as one multi-statement dbQuery)" },
}

local PAYLOAD = string.rep("abcdefgh", 8)  -- 64 bytes per inserted row

local SQL = {
    mysql = {
        drop = "DROP TABLE IF EXISTS bench",
        create = "CREATE TABLE bench (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(64) NOT NULL, score INT NOT NULL, data TEXT NOT NULL) ENGINE=InnoDB",
        prepSeed = "SET SESSION cte_max_recursion_depth = 1000000",
        seed = "INSERT INTO bench (name, score, data) WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < %d) SELECT CONCAT('name', n), n, REPEAT('x', 100) FROM seq",
        analyze = "ANALYZE TABLE bench",
        insert = "INSERT INTO bench (name, score, data) VALUES (?, ?, ?)",
        point = "SELECT id, name, score, data FROM bench WHERE id = ?",
        large = "SELECT id, name, score, data FROM bench WHERE id <= ?",
        count = "SELECT COUNT(*) AS n FROM bench",
        fence = "SELECT 1 AS fence",
        version = "SELECT VERSION() AS v",
    },
    pg = {
        drop = "DROP TABLE IF EXISTS bench",
        create = "CREATE TABLE bench (id serial PRIMARY KEY, name varchar(64) NOT NULL, score int NOT NULL, data text NOT NULL)",
        seed = "INSERT INTO bench (name, score, data) SELECT 'name' || g, g, repeat('x', 100) FROM generate_series(1, %d) g",
        analyze = "ANALYZE bench",
        insert = "INSERT INTO bench (name, score, data) VALUES ($1, $2, $3)",
        point = "SELECT id, name, score, data FROM bench WHERE id = $1",
        large = "SELECT id, name, score, data FROM bench WHERE id <= $1",
        count = "SELECT count(*)::int AS n FROM bench",
        fence = "SELECT 1 AS fence",
        version = "SELECT current_setting('server_version') AS v",
    },
}

local WORKLOAD_ORDER = {
    "idle_frames_default", "idle_frames", "insert", "point_select", "seq_select", "seq_select_default_fps",
    "sync_select", "large_select", "bulk_tx",
}

local results, failures, meta = {}, 0, {}
local co
local TIMEOUT = setmetatable({}, { __tostring = function() return "TIMEOUT" end })

---------------------------------------------------------------------------------------------
-- small utilities
---------------------------------------------------------------------------------------------

local function log(fmt, ...)
    print("[bench] " .. string.format(fmt, ...))
end

local jsonEscapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function json(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.6g", v)
    elseif t == "string" then
        return '"' .. (v:gsub('[%c"\\]', function(c) return jsonEscapes[c] or string.format("\\u%04x", c:byte()) end)) .. '"'
    elseif t == "table" then
        if next(v) == nil then return "[]" end
        if #v > 0 then
            local parts = {}
            for i = 1, #v do parts[i] = json(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = json(k) .. ":" .. json(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json(tostring(v))
end

local function pct(sorted, p)
    if #sorted == 0 then return 0 end
    return sorted[math.max(1, math.ceil(#sorted * p))]
end

local function summarize(arr)
    local s, sum = {}, 0
    for i, v in ipairs(arr) do s[i] = v; sum = sum + v end
    table.sort(s)
    return { n = #s, avg = #s > 0 and sum / #s or 0, p50 = pct(s, 0.5), p99 = pct(s, 0.99), max = s[#s] or 0 }
end

local function round(v, d)
    local m = 10 ^ (d or 0)
    return math.floor(v * m + 0.5) / m
end

local function benchFail(msg)
    failures = failures + 1
    print("BENCHFAIL " .. msg)
end

local function newRecord(b, workload, n)
    return { backend = b.id, label = b.label, kind = b.kind, workload = workload, n = n, ok = true }
end

local function check(rec, cond, fmt, ...)
    if cond then return true end
    local msg = string.format(fmt, ...)
    rec.ok = false
    rec.errors = rec.errors or {}
    rec.errors[#rec.errors + 1] = msg
    benchFail(rec.backend .. "/" .. rec.workload .. ": " .. msg)
    return false
end

local function record(rec)
    results[#results + 1] = rec
    print("BENCHJSON " .. json(rec))
end

---------------------------------------------------------------------------------------------
-- coroutine scheduling
---------------------------------------------------------------------------------------------

local finishRun  -- forward

local function resumeCo(...)
    if not co or coroutine.status(co) ~= "suspended" then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        failures = failures + 1
        print("BENCHERROR " .. tostring(err))
        local okTb, tb = pcall(debug.traceback, co)
        if okTb then print(tb) end
        finishRun()
    end
end

-- One wait at a time. signal() may be called from any callback; it resumes the coroutine on the
-- next frame (outside the driver's callback loop), and only if that wait is still current.
local waitGen, waiting = 0, false

local function signal(...)
    local gen, n, args = waitGen, select("#", ...), { ... }
    setTimer(function()
        if waiting and gen == waitGen then
            waiting = false
            resumeCo(unpack(args, 1, n))
        end
    end, 0, 1)
end

local function wait(timeoutMs)
    local gen = waitGen
    waiting = true
    local timer = setTimer(function()
        if waiting and gen == waitGen then
            waiting = false
            resumeCo(TIMEOUT)
        end
    end, timeoutMs or CFG.waitTimeoutMs, 1)
    local res = { coroutine.yield() }
    waitGen = waitGen + 1
    waiting = false
    if isTimer(timer) then killTimer(timer) end
    return unpack(res, 1, table.maxn(res))
end

local function sleepMs(ms)
    setTimer(resumeCo, ms, 1)
    coroutine.yield()
end

---------------------------------------------------------------------------------------------
-- frame monitor
---------------------------------------------------------------------------------------------

local FM = { last = getTickCount(), frameStart = getTickCount(), mark = getTickCount() }

local function frameTick()
    local now = getTickCount()
    if FM.gaps then
        FM.gaps[#FM.gaps + 1] = now - FM.last
        if FM.freeze then
            FM.frozen, FM.gaps, FM.freeze = FM.gaps, nil, false
        end
    end
    FM.last, FM.frameStart, FM.mark = now, now, now
    if FM.poll then FM.poll(now) end
end

-- The first recorded gap spans the frame that runs the submit loop.
local function framesStart()
    FM.gaps, FM.frozen, FM.freeze = {}, nil, false
end

-- Completion seen: record one more gap (the frame that delivered the completion), then stop.
local function markComplete()
    if FM.gaps then FM.freeze = true end
end

local function framesCollect()
    if not FM.gaps and not FM.frozen then return {} end
    FM.freeze = FM.freeze or (FM.gaps ~= nil)
    while not FM.frozen do sleepMs(0) end
    local g = FM.frozen
    FM.frozen = nil
    return g
end

local function addFrames(rec, gaps)
    local s = summarize(gaps)
    rec.frames, rec.frameAvg, rec.frameP50, rec.frameP99, rec.frameMax = s.n, round(s.avg, 2), s.p50, s.p99, s.max
end

---------------------------------------------------------------------------------------------
-- backend helpers (setup / verification only; hot loops below call the drivers directly)
---------------------------------------------------------------------------------------------

local function q(b, sql, ...)
    if b.kind == "pg" then
        local ok, err = pgQuery(b.db, function(rows, e, state) signal(rows, rows and nil or (tostring(e) .. " [" .. tostring(state) .. "]")) end, sql, ...)
        if not ok then return false, err end
    else
        local qh = dbQuery(function(h)
            local rows, code, msg = dbPoll(h, 0)
            if rows then signal(rows) else signal(false, tostring(msg) .. " [" .. tostring(code) .. "]") end
        end, b.db, sql, ...)
        if not qh then return false, "dbQuery returned false" end
    end
    local rows, err = wait()
    if rows == TIMEOUT then return false, "timeout" end
    return rows, err
end

local function qq(b, sql, ...)
    local rows, err = q(b, sql, ...)
    if not rows then error(("setup query failed on %s: %s -- %s"):format(b.id, tostring(err), sql), 2) end
    return rows
end

local function countRows(b)
    return tonumber(qq(b, SQL[b.kind].count)[1].n)
end

local function resetTable(b, seed)
    local S = SQL[b.kind]
    qq(b, S.drop)
    qq(b, S.create)
    if seed > 0 then
        if S.prepSeed then qq(b, S.prepSeed) end
        qq(b, S.seed:format(seed))
        qq(b, S.analyze)
        local n = countRows(b)
        if n ~= seed then error(("seeding %s: expected %d rows, got %s"):format(b.id, seed, tostring(n))) end
    end
end

local function pgDelta(b, before)
    if b.kind ~= "pg" then return nil end
    local s = pgStats(b.db)
    return { failed = s.failed - before.failed, roundTrips = s.roundTrips - before.roundTrips, submitted = s.submitted - before.submitted }
end

---------------------------------------------------------------------------------------------
-- workloads
---------------------------------------------------------------------------------------------

-- a. single-row INSERTs, fire and forget, timed until all of them are done.
local function wInsert(b)
    local N = CFG.nInsert
    local rec = newRecord(b, "insert", N)
    resetTable(b, 0)
    sleepMs(CFG.settleMs)

    local db, sql, bad, tEnd = b.db, SQL[b.kind].insert, 0, nil
    local before = b.kind == "pg" and pgStats(db)
    local function done() tEnd = getTickCount(); markComplete(); signal() end

    framesStart()
    local t0 = getTickCount()
    if b.kind == "mysql" then
        for i = 1, N do
            if not dbExec(db, sql, "n" .. i, i, PAYLOAD) then bad = bad + 1 end
        end
    else
        for i = 1, N do
            if not pgExec(db, sql, "n" .. i, i, PAYLOAD) then bad = bad + 1 end
        end
    end
    local t1 = getTickCount()

    -- Completion fence: MySQL and poolSize=1 run strictly in order, so a trailing query's
    -- callback fires after every earlier INSERT. poolSize>1 has no ordering: poll pgStats.
    if b.kind == "mysql" then
        rec.fence = "dbQuery"
        dbQuery(function(h) dbPoll(h, 0); done() end, db, SQL.mysql.fence)
    elseif b.pool == 1 then
        rec.fence = "pgQuery"
        pgQuery(db, done, SQL.pg.fence)
    else
        rec.fence = "pgStats"
        local target = before.succeeded + before.failed + (N - bad)
        FM.poll = function(now)
            local s = pgStats(db)
            if s.succeeded + s.failed >= target then
                FM.poll = nil
                tEnd = now
                markComplete()
                signal()
            end
        end
    end
    local r = wait()
    FM.poll = nil
    local gaps = framesCollect()
    if not check(rec, r ~= TIMEOUT, "timed out") then tEnd = getTickCount() end

    rec.ms = tEnd - t0
    rec.submitMs = t1 - t0
    rec.ops = round(N / math.max(rec.ms, 1) * 1000)
    addFrames(rec, gaps)
    check(rec, bad == 0, "%d submit calls returned false", bad)
    local d = pgDelta(b, before or {})
    if d then
        rec.roundTrips = d.roundTrips
        check(rec, d.failed == 0, "%d queries failed", d.failed)
    end
    local n = countRows(b)
    check(rec, n == N, "expected %d rows, table has %s", N, tostring(n))
    record(rec)
end

-- b. point SELECTs by primary key, all issued in one burst, one shared callback.
local function wPoint(b)
    local N = math.min(CFG.nPoint, CFG.seedRows)
    local rec = newRecord(b, "point_select", N)
    resetTable(b, CFG.seedRows)
    sleepMs(CFG.settleMs)

    local db, sql = b.db, SQL[b.kind].point
    local before = b.kind == "pg" and pgStats(db)
    local done, expected, sumId, bad, firstErr, tEnd = 0, math.huge, 0, 0, nil, nil
    local function onRows(rows, err)
        if rows and rows[1] and not rows[2] then
            sumId = sumId + rows[1].id
        else
            bad = bad + 1
            firstErr = firstErr or tostring(err)
        end
        done = done + 1
        if done == expected then tEnd = getTickCount(); markComplete(); signal() end
    end
    local function onMy(h)
        local rows, _, msg = dbPoll(h, 0)
        onRows(rows, msg)
    end

    framesStart()
    local t0 = getTickCount()
    local submitBad = 0
    if b.kind == "mysql" then
        for i = 1, N do
            if not dbQuery(onMy, db, sql, i) then submitBad = submitBad + 1 end
        end
    else
        for i = 1, N do
            if not pgQuery(db, onRows, sql, i) then submitBad = submitBad + 1 end
        end
    end
    local t1 = getTickCount()
    expected = N - submitBad  -- callbacks only run in a later pulse, so this is in time
    if expected == 0 then tEnd = t1; markComplete(); signal() end

    local r = wait()
    local gaps = framesCollect()
    if not check(rec, r ~= TIMEOUT, "timed out (%d of %d callbacks)", done, expected) then tEnd = getTickCount() end

    rec.ms = tEnd - t0
    rec.submitMs = t1 - t0
    rec.ops = round(N / math.max(rec.ms, 1) * 1000)
    addFrames(rec, gaps)
    check(rec, submitBad == 0, "%d submit calls returned false", submitBad)
    check(rec, bad == 0, "%d callbacks without exactly one row (first error: %s)", bad, tostring(firstErr))
    check(rec, sumId == N * (N + 1) / 2, "sum of returned ids %d, expected %d", sumId, N * (N + 1) / 2)
    local d = pgDelta(b, before or {})
    if d then rec.roundTrips = d.roundTrips end
    record(rec)
end

-- c. sequential round trips: each query is issued from the previous query's callback.
local function wSeq(b, workload, N)
    local rec = newRecord(b, workload, N)
    sleepMs(CFG.settleMs)

    local db, sql, seed = b.db, SQL[b.kind].point, CFG.seedRows
    local lat, i, tIssue, bad, tEnd = {}, 0, 0, 0, nil
    local issue
    local function onRows(rows)
        local now = getTickCount()
        lat[#lat + 1] = now - tIssue
        if not (rows and rows[1] and rows[1].id == ((i - 1) % seed) + 1) then bad = bad + 1 end
        if i < N then issue() else tEnd = now; markComplete(); signal() end
    end
    local function onMy(h) onRows((dbPoll(h, 0))) end
    issue = function()
        i = i + 1
        tIssue = getTickCount()
        local id = ((i - 1) % seed) + 1
        local ok
        if b.kind == "mysql" then ok = dbQuery(onMy, db, sql, id) else ok = pgQuery(db, onRows, sql, id) end
        if not ok then
            bad = bad + 1
            tEnd = getTickCount(); markComplete(); signal()
        end
    end

    framesStart()
    local t0 = getTickCount()
    issue()
    local r = wait()
    local gaps = framesCollect()
    if not check(rec, r ~= TIMEOUT, "timed out after %d of %d", i, N) then tEnd = getTickCount() end

    local s = summarize(lat)
    rec.ms = tEnd - t0
    rec.ops = round(N / math.max(rec.ms, 1) * 1000)
    rec.latAvg, rec.latP50, rec.latP99, rec.latMax = round(rec.ms / N, 3), s.p50, s.p99, s.max
    addFrames(rec, gaps)
    check(rec, bad == 0 and #lat == N, "%d bad results, %d of %d callbacks", bad, #lat, N)
    record(rec)
end

-- c''. blocking round trips on the main thread: dbPoll(dbQuery(...), -1) vs pgQuerySync.
local function wSync(b)
    local N, chunk = CFG.nSync, CFG.syncChunk
    local rec = newRecord(b, "sync_select", N)
    sleepMs(CFG.settleMs)

    local db, sql, seed = b.db, SQL[b.kind].point, CFG.seedRows
    local busy, done, bad = 0, 0, 0
    framesStart()
    while done < N do
        local t0 = getTickCount()
        for _ = 1, math.min(chunk, N - done) do
            done = done + 1
            local id = ((done - 1) % seed) + 1
            local rows
            if b.kind == "mysql" then
                local h = dbQuery(db, sql, id)
                rows = h and dbPoll(h, -1)
            else
                rows = pgQuerySync(db, sql, id)
            end
            if not (rows and rows[1] and rows[1].id == id) then bad = bad + 1 end
        end
        busy = busy + (getTickCount() - t0)
        sleepMs(0)
    end
    markComplete()
    local gaps = framesCollect()

    rec.ms = busy  -- main thread blocked in total
    rec.ops = round(N / math.max(busy, 1) * 1000)
    rec.latAvgUs = round(busy * 1000 / N)
    addFrames(rec, gaps)
    check(rec, bad == 0, "%d bad results", bad)
    record(rec)
end

-- d. large result sets: `largeReps` queries issued in one burst, one shared callback.
local function wLarge(b)
    local R, reps = CFG.largeRows, CFG.largeReps
    local rec = newRecord(b, "large_select", reps)
    rec.rows = R
    sleepMs(CFG.settleMs)

    local db, sql = b.db, SQL[b.kind].large
    local done, expected, conv, poll, bad, tEnd = 0, math.huge, {}, {}, 0, nil
    local function have(rows, tCb)
        local tHave = getTickCount()
        -- Main-thread time until this result is a Lua table: measured from the start of the frame
        -- (or from the previous result delivered in the same frame). ml_pgsql converts before it
        -- calls the callback; MTA converts inside dbPoll.
        conv[#conv + 1] = tHave - FM.mark
        FM.mark = tHave
        if tCb then poll[#poll + 1] = tHave - tCb end
        if not (rows and #rows == R and type(rows[1].id) == "number" and type(rows[1].score) == "number"
                and type(rows[1].data) == "string" and #rows[1].data == 100) then
            bad = bad + 1
        end
        done = done + 1
        if done == expected then tEnd = tHave; markComplete(); signal() end
    end
    local function onPg(rows) have(rows) end
    local function onMy(h)
        local tCb = getTickCount()
        local rows = dbPoll(h, 0)
        have(rows, tCb)
    end

    collectgarbage()
    framesStart()
    local t0 = getTickCount()
    local submitBad = 0
    for _ = 1, reps do
        local ok
        if b.kind == "mysql" then ok = dbQuery(onMy, db, sql, R) else ok = pgQuery(db, onPg, sql, R) end
        if not ok then submitBad = submitBad + 1 end
    end
    local t1 = getTickCount()
    expected = reps - submitBad
    if expected == 0 then tEnd = t1; markComplete(); signal() end
    local r = wait()
    local gaps = framesCollect()
    if not check(rec, r ~= TIMEOUT, "timed out after %d of %d", done, reps) then tEnd = getTickCount() end

    local sc = summarize(conv)
    rec.ms = tEnd - t0
    rec.submitMs = t1 - t0
    rec.rowsPerSec = round(R * reps / math.max(rec.ms, 1) * 1000)
    rec.convAvg, rec.convP50, rec.convMax = round(sc.avg, 2), sc.p50, sc.max
    if #poll > 0 then rec.dbPollAvg = round(summarize(poll).avg, 2) end
    addFrames(rec, gaps)
    check(rec, submitBad == 0, "%d submit calls returned false", submitBad)
    check(rec, bad == 0, "%d of %d results had the wrong shape", bad, reps)
    record(rec)
end

-- e. bulk insert, all rows in one transaction.
local function wBulk(b)
    local R, reps = CFG.bulkRows, CFG.bulkReps
    local rec = newRecord(b, "bulk_tx", reps)
    rec.rows = R
    rec.mode = b.kind == "pg" and "pgTransaction" or (b.multi and "multi-statement dbQuery" or "ordered dbExec")
    resetTable(b, 0)

    local db, sql = b.db, SQL[b.kind].insert
    local before = b.kind == "pg" and pgStats(db)
    local txMs, subMs, allGaps, submitBad = {}, {}, {}, 0
    for rep = 1, reps do
        sleepMs(CFG.settleMs)
        local base, tEnd = (rep - 1) * R, nil
        local function done(ok, err) tEnd = getTickCount(); markComplete(); signal(ok, err) end

        framesStart()
        local t0 = getTickCount()
        if b.kind == "pg" then
            local stmts = {}
            for i = 1, R do stmts[i] = { sql, "n" .. (base + i), base + i, PAYLOAD } end
            local ok, e = pgTransaction(db, stmts, function(res, err) done(res and #res == R, err) end)
            if not ok then done(false, e) end
        elseif b.multi then
            local parts = { "START TRANSACTION" }
            for i = 1, R do parts[i + 1] = dbPrepareString(db, sql, "n" .. (base + i), base + i, PAYLOAD) end
            parts[R + 2] = "COMMIT"
            local h = dbQuery(function(h)
                local rows, code, msg = dbPoll(h, 0)
                done(rows and true or false, msg and (tostring(msg) .. " [" .. tostring(code) .. "]"))
            end, db, table.concat(parts, ";"))
            if not h then done(false, "dbQuery returned false") end
        else
            local ok = dbExec(db, "START TRANSACTION")
            for i = 1, R do ok = dbExec(db, sql, "n" .. (base + i), base + i, PAYLOAD) and ok end
            ok = dbExec(db, "COMMIT") and ok
            if not ok then submitBad = submitBad + 1 end
            dbQuery(function(h) dbPoll(h, 0); done(true) end, db, SQL.mysql.fence)
        end
        local t1 = getTickCount()
        local ok, err = wait()
        local gaps = framesCollect()
        if ok == TIMEOUT then
            check(rec, false, "rep %d timed out", rep)
            tEnd = getTickCount()
        elseif not ok then
            check(rec, false, "rep %d failed: %s", rep, tostring(err))
        end
        txMs[rep], subMs[rep] = tEnd - t0, t1 - t0
        for _, g in ipairs(gaps) do allGaps[#allGaps + 1] = g end
    end

    local st, ss = summarize(txMs), summarize(subMs)
    rec.ms = round(st.avg, 1)  -- per transaction
    rec.msMin, rec.msMax = math.min(unpack(txMs)), st.max
    rec.submitMs = round(ss.avg, 1)
    rec.rowsPerSec = round(R / math.max(st.avg, 0.001) * 1000)
    addFrames(rec, allGaps)
    check(rec, submitBad == 0, "%d reps had dbExec calls that returned false", submitBad)
    local d = pgDelta(b, before or {})
    if d then
        rec.roundTrips = d.roundTrips
        check(rec, d.failed == 0, "%d jobs failed", d.failed)
    end
    local n = countRows(b)
    check(rec, n == R * reps, "expected %d rows, table has %s", R * reps, tostring(n))
    record(rec)
end

local function wIdle(workload, ms)
    local rec = { backend = "server", label = "no database work", kind = "server", workload = workload, ok = true }
    framesStart()
    sleepMs(ms)
    markComplete()
    addFrames(rec, framesCollect())
    rec.ms = ms
    record(rec)
end

---------------------------------------------------------------------------------------------
-- driver
---------------------------------------------------------------------------------------------

local function setFpsLimit(v)
    local ok = setServerConfigSetting("server_logic_fps_limit", tostring(v), false)
    if not ok then benchFail("setServerConfigSetting(server_logic_fps_limit, " .. v .. ") failed") end
    return ok
end

local function connect(b)
    local t0 = getTickCount()
    if b.kind == "mysql" then
        b.db = dbConnect("mysql", CFG.myHost, CFG.myUser, CFG.myPass, b.options)
        b.err = b.db and nil or "dbConnect returned false"
    else
        b.db, b.err = pgConnect(CFG.pgConninfo, b.opts)
        b.pool = b.opts.poolSize or 1
    end
    b.pool = b.pool or 1
    b.connectMs = getTickCount() - t0
    if not b.db then
        benchFail(b.id .. ": connect failed: " .. tostring(b.err))
        return false
    end
    -- warm up (and, for pools, wait until every connection is up)
    for _ = 1, 20 do qq(b, SQL[b.kind].fence) end
    if b.kind == "pg" and b.pool > 1 then
        local deadline = getTickCount() + 10000
        while pgStats(b.db).connected < b.pool and getTickCount() < deadline do
            for _ = 1, b.pool * 4 do pgExec(b.db, SQL.pg.fence) end
            sleepMs(50)
        end
        if pgStats(b.db).connected < b.pool then benchFail(b.id .. ": pool did not fill up") end
    end
    local v = qq(b, SQL[b.kind].version)[1].v
    if b.kind == "mysql" then meta.mysqlServer = v else meta.pgServer = v end
    log("%-12s connected in %d ms (%s) server %s", b.id, b.connectMs, b.label, tostring(v))
    return true
end

local function disconnect(b)
    if not b.db then return end
    if b.kind == "mysql" then
        destroyElement(b.db)
    else
        pgClose(b.db)
    end
    b.db = nil
end

local function runBackend(b)
    if not connect(b) then return end
    local function want(w) return not b.only or b.only[w] end
    local steps = {
        { "insert", function() wInsert(b) end },
        { "point_select", function() wPoint(b) end },  -- seeds the table used by the next three
        { "seq_select", function() wSeq(b, "seq_select", CFG.nSeq) end },
        { "seq_select_default_fps", function()
            if not b.seqDefault then return end
            setFpsLimit(0)
            sleepMs(500)
            wSeq(b, "seq_select_default_fps", CFG.nSeqDefault)
            setFpsLimit(CFG.fpsLimit)
            sleepMs(500)
        end },
        { "sync_select", function() wSync(b) end },
        { "large_select", function() wLarge(b) end },
        { "bulk_tx", function() wBulk(b) end },
    }
    -- No pcall here: Lua 5.1 cannot yield across it. A script error aborts the whole run
    -- loudly (BENCHERROR) instead.
    for _, step in ipairs(steps) do
        if want(step[1]) then step[2]() end
    end
    if b.kind == "pg" then log("%-12s pgStats %s", b.id, json(pgStats(b.db))) end
    disconnect(b)
end

local function fmt(v, d)
    if v == nil then return "-" end
    if d then return string.format("%." .. d .. "f", v) end
    return tostring(v)
end

local function printSummary()
    log("==================================== results ====================================")
    log("fps limit %s | MTA %s | ml_pgsql %s (libpq %s) | PostgreSQL %s | MySQL %s",
        tostring(meta.fpsLimit), tostring(meta.mta), tostring(meta.module), tostring(meta.libpq),
        tostring(meta.pgServer), tostring(meta.mysqlServer))
    for _, w in ipairs(WORKLOAD_ORDER) do
        for _, r in ipairs(results) do
            if r.workload == w then
                local m
                if w == "insert" or w == "point_select" then
                    m = ("total %6s ms  %7s ops/s  submit %5s ms"):format(fmt(r.ms), fmt(r.ops), fmt(r.submitMs))
                elseif w:find("^seq_select") then
                    m = ("avg %6s ms  p50 %3s  p99 %3s  max %3s ms"):format(fmt(r.latAvg, 2), fmt(r.latP50), fmt(r.latP99), fmt(r.latMax))
                elseif w == "sync_select" then
                    m = ("avg %5s us  %7s ops/s (main thread blocked %s ms)"):format(fmt(r.latAvgUs), fmt(r.ops), fmt(r.ms))
                elseif w == "large_select" then
                    m = ("total %6s ms  %8s rows/s  to-Lua avg %s max %s ms per result"):format(fmt(r.ms), fmt(r.rowsPerSec), fmt(r.convAvg, 1), fmt(r.convMax))
                elseif w == "bulk_tx" then
                    m = ("avg %6s ms/tx  %7s rows/s  submit %s ms  [%s]"):format(fmt(r.ms, 1), fmt(r.rowsPerSec), fmt(r.submitMs, 1), tostring(r.mode))
                else
                    m = ""
                end
                log("%-22s %-12s %s | frames %4s p99 %3s max %4s ms%s", w, r.backend, m, fmt(r.frames), fmt(r.frameP99),
                    fmt(r.frameMax), r.ok and "" or "  << FAILED")
            end
        end
    end
    log("failures: %d", failures)
end

local finished = false
finishRun = function()
    if finished then return end
    finished = true
    pcall(printSummary)
    print("BENCHDONE " .. json({ failures = failures, results = #results }))
    setServerConfigSetting("server_logic_fps_limit", "0", false)
    setTimer(function() shutdown("pgbench finished") end, 500, 1)
end

local function main()
    local v = getVersion()
    local modVer, libpqVer = pgVersion()
    meta = { mta = v.tag, mtaSortable = v.sortable, module = modVer, libpq = libpqVer, fpsLimit = CFG.fpsLimit, cfg = CFG }
    log("starting; MTA %s, ml_pgsql %s", tostring(v.tag), tostring(modVer))

    wIdle("idle_frames_default", 2000)
    setFpsLimit(CFG.fpsLimit)
    sleepMs(500)
    wIdle("idle_frames", 2000)

    for _, b in ipairs(BACKENDS) do
        log("---- %s: %s", b.id, b.label)
        runBackend(b)
    end

    print("BENCHMETA " .. json(meta))
    finishRun()
end

addEventHandler("onResourceStart", resourceRoot, function()
    setTimer(frameTick, 0, 0)
    setTimer(function()
        print("BENCHERROR watchdog expired")
        failures = failures + 1
        finishRun()
    end, CFG.watchdogMs, 1)
    co = coroutine.create(main)
    setTimer(resumeCo, 1000, 1)  -- let the server finish starting up
end)
