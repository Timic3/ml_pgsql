--[[
pgsoak: memory soak test for ml_pgsql inside the real MTA server. Started by tests/soak.sh
(MLPG_SUITE=soak), which samples the server process from outside (RSS, threads, fds) and
decides pass/fail. This resource produces a steady, rate-limited mixed load, verifies every
result and reports the Lua side.

Phases, each announced with "PGSOAK PHASE <name>":
  setup     read the configuration, create the schema, then close every connection; lasts
            until CFG.settleSeconds after the server started (MTA's own startup HTTP requests
            keep sockets and pipes open for about 70 s)
  baseline  idle with no connection open: the reference for threads and fds
  load      CFG.rate operations per second for CFG.loadSeconds, on pool A (poolSize 1) and
            pool B (poolSize 4), plus connection churn, backend kills and child resource cycles
            (each of those opens connections: the soak sees about 10 new ones per minute)
  drain     stop issuing, wait for every result, audit the database, close every pool
  final     idle again with no connection open; tests/soak.sh compares it with baseline
  shutdown  queue CFG.drainRows writes and call shutdown(); tests/soak.sh counts the rows

Output (console lines, parsed by tests/soak.sh):
  PGSOAK CONFIG {json}   effective configuration and versions
  PGSOAK PHASE <name> t=<getTickCount()>
  PGSOAK STAT {json}     every CFG.sampleSeconds, see stat() (t is getTickCount())
  PGSOAK FAIL <msg>      a check failed (the first 100 are printed, all are counted)
  PGSOAK REPORT {json}   summary after the drain; "ok" is false if anything failed
  PGSOAK OPS {json}      per-operation counts

Configuration: the defaults in CFG, overridden by rows of table soak_config(key, value) that
tests/soak.sh writes before the server starts (resources are mounted read-only, and scripts
cannot read the environment).

CFG.mode = "control" runs the same Lua-side churn (tables, closures, coroutines, timers,
result-sized tables) without calling the module during the load, to tell MTA's own memory
behaviour apart from the module's.
]]

local CFG = {
    loadSeconds = 1800,
    rate = 2000,           -- operations started per second (fire-and-forget writes included)
    maxPending = 5000,     -- operations without a result; beyond it the load pauses (counted)
    sampleSeconds = 10,    -- PGSOAK STAT interval
    settleSeconds = 90,    -- the baseline starts this long after the server started
    baselineSeconds = 25,
    finalSeconds = 25,
    killSeconds = 20,      -- pg_terminate_backend one backend of pool A or B (alternating)
    -- Open a short-lived connection, use it, close or drop it. Connection churn this fast
    -- grows RSS through glibc, not the module: after large blocks are freed glibc raises its
    -- mmap/trim thresholds, and every new connection's buffers then end up cached in the
    -- per-thread malloc arenas (~0.6 MB/min at 1000 ms, flat with MALLOC_ARENA_MAX=2 or pinned
    -- thresholds; see README "Memory soak"). The default stands for servers that reconnect
    -- or restart resources now and then; SOAK_CFG_churnMs=1000 reproduces the stress case.
    churnMs = 30000,
    childSeconds = 15,     -- start pgtest_child and stop it while its queries are in flight
    largeRows = 10000,     -- large results have largeRows..2*largeRows rows, one at a time
    lostSeconds = 60,      -- an operation without a result after this long is a failure
    fpsLimit = 100,        -- server_logic_fps_limit (an idle server otherwise runs 40 ms frames)
    drainRows = 3000,      -- writes queued right before shutdown()
    seed = 1,
    mode = "module",       -- or "control"
    sslmode = "",          -- "require", or "disable" to run without TLS; default: require if the
                           -- module has TLS support (pgVersion), else disable
    hostaddr = "",         -- "server": connect to the server's IP (no host name lookups)
}

local CONNINFO, CONNINFO_VERIFY  -- set from CFG.sslmode in setup()

-- SQLSTATEs a query may fail with when its backend was terminated: 57P01 from the server,
-- 08006 when the connection broke with the query sent, 08001 if no connection could be made.
local KILL_STATES = { ["08006"] = true, ["57P01"] = true, ["08001"] = true }
local KILL_GRACE_MS = 5000  -- a kill may still fail queries issued this long after it returned

local SCHEMA = [==[
    DROP TABLE IF EXISTS soak_exec, soak_tx, soak_kv, soak_uniq, soak_drain, child_marker;
    CREATE TABLE soak_exec(id bigint PRIMARY KEY, pool smallint NOT NULL);
    CREATE TABLE soak_tx(k bigint PRIMARY KEY, v int NOT NULL);
    CREATE TABLE soak_kv(k int PRIMARY KEY, v text NOT NULL);
    CREATE TABLE soak_uniq(k int PRIMARY KEY);
    INSERT INTO soak_uniq VALUES (1);
    CREATE TABLE soak_drain(v int);
    CREATE TABLE child_marker(id serial PRIMARY KEY, note text);
]==]

local CONTROL = false
local D = {}               -- driver: the module, or a stand-in in control mode
local TAG = {              -- callbacks capture these instead of the connection, so dropped
    { name = "pgsoak-a", code = 1 },      -- connections can be garbage-collected while
    { name = "pgsoak-b", code = 2 },      -- their queries are still running
    { name = "pgsoak-churn", code = 3 },
}
local POOL = {}            -- per tag code: jobs submitted, failed results seen, writes
for code = 1, 3 do POOL[code] = { submitted = 0, cbFail = 0, exec = 0, execFail = 0 } end

local CONN = {}            -- [1] pool A, [2] pool B: { db = , tag = }
local adminDb              -- kills, backend counts and audits; not part of the load
local child = getResourceFromName("pgtest_child")

local M = {
    issued = 0, completed = 0, ok = 0, expectedErrors = 0, killFailures = 0, lost = 0,
    throttled = 0, maxPending = 0, exec = 0, execWarnings = 0,
    kills = 0, killsHit = 0, churnOpened = 0, churnClosed = 0, churnDropped = 0, churnSkipped = 0,
    childStarts = 0, childStops = 0,
}
local byOp = {}            -- per operation: issued, ok, expected errors, kill failures
local killStates = {}      -- SQLSTATE -> failures attributed to kills
local failures, failPrinted = 0, 0
local phaseName = "start"

---------------------------------------------------------------------------------------------
-- utilities
---------------------------------------------------------------------------------------------

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
        if next(v) == nil then return "{}" end
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

local function fail(fmt, ...)
    failures = failures + 1
    if failPrinted < 100 then
        failPrinted = failPrinted + 1
        print("PGSOAK FAIL " .. string.format(fmt, ...))
    end
end

local function phase(name)
    phaseName = name
    print("PGSOAK PHASE " .. name .. " t=" .. getTickCount())
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Live entries of the Lua registry. luaL_unref leaves a number in a freed slot, so only
-- non-number values are references (callbacks and coroutines waiting for results among them).
local function registrySize()
    if not (debug and debug.getregistry) then return nil end
    local n = 0
    for _, v in pairs(debug.getregistry()) do
        if type(v) ~= "number" then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------------------------
-- main coroutine
---------------------------------------------------------------------------------------------

local mainCo, abort

local function resumeMain()
    if not mainCo or coroutine.status(mainCo) ~= "suspended" then return end
    local ok, err = coroutine.resume(mainCo)
    if not ok then
        fail("soak script error: %s", tostring(err))
        print(debug.traceback(mainCo))
        abort()
    end
end

local function sleep(ms)
    setTimer(resumeMain, math.max(ms, 50), 1)
    coroutine.yield()
end

local function waitUntil(cond, timeoutMs)
    local deadline = getTickCount() + timeoutMs
    while not cond() do
        if getTickCount() > deadline then return false end
        sleep(100)
    end
    return true
end

-- pgQuery for the main coroutine. It is resumed through resumeMain (not by the module, as
-- pgQueryAwait would), so an error in the code that follows is caught and aborts the run.
local function q(db, sql, ...)
    local res
    local ok, err = pgQuery(db, function(...)
        res = { n = select("#", ...), ... }
        resumeMain()
    end, sql, ...)
    if not ok then return false, err end
    if not res then coroutine.yield() end
    return unpack(res, 1, res.n)
end

-- Setup and audit queries on the admin connection (main coroutine only).
local function adminQuery(sql, ...)
    local rows, err, state = q(adminDb, sql, ...)
    if not rows then error(("admin query failed: %s [%s] -- %s"):format(tostring(err), tostring(state), sql), 2) end
    return rows
end

---------------------------------------------------------------------------------------------
-- operations
---------------------------------------------------------------------------------------------

local pending, pendingOp, pendingN, nextId = {}, {}, 0, 0
local killWin = {}         -- pool name -> { from = tick, to = tick when the kill query returned }

-- Did a kill of this pool's backends overlap an operation issued at t0?
local function killWindow(tag, t0)
    local w = killWin[tag.name]
    return w ~= nil and t0 <= (w.to or math.huge) + KILL_GRACE_MS
end

local function opStats(name)
    local s = byOp[name]
    if not s then
        s = { n = 0, ok = 0, xerr = 0, kfail = 0, pending = 0 }
        byOp[name] = s
    end
    return s
end

local function begin(tag, name)
    nextId = nextId + 1
    pending[nextId] = getTickCount()
    pendingOp[nextId] = name
    pendingN = pendingN + 1
    M.issued = M.issued + 1
    POOL[tag.code].submitted = POOL[tag.code].submitted + 1
    local s = opStats(name)
    s.n, s.pending = s.n + 1, s.pending + 1
    return nextId
end

local function rejected(id, tag, name, err)
    pending[id], pendingOp[id] = nil, nil
    pendingN = pendingN - 1
    M.issued = M.issued - 1
    POOL[tag.code].submitted = POOL[tag.code].submitted - 1
    local s = opStats(name)
    s.n, s.pending = s.n - 1, s.pending - 1
    fail("%s on %s: submit failed: %s", name, tag.name, tostring(err))
end

-- Classifies a result. Success: check(rows, affected) must return true (or a reason).
-- Expected error (expect = SQLSTATE): check(false, err, state, failedStatement) must return true.
-- Results are callback(rows, nil, affected) or callback(false, err, sqlstate[, index]).
local function outcome(id, tag, name, expect, check, res, err, x, idx)
    local t0 = pending[id]
    if not t0 then
        fail("%s on %s: result delivered twice, or after it was declared lost", name, tag.name)
        return
    end
    pending[id], pendingOp[id] = nil, nil
    pendingN = pendingN - 1
    M.completed = M.completed + 1
    local s = byOp[name]
    s.pending = s.pending - 1
    if CONTROL then
        s.ok = s.ok + 1
        M.ok = M.ok + 1
        return
    end
    if not res then POOL[tag.code].cbFail = POOL[tag.code].cbFail + 1 end
    if res and not expect then
        local okc, why = pcall(check, res, x)
        if okc and why == true then
            s.ok = s.ok + 1
            M.ok = M.ok + 1
        else
            fail("%s on %s: wrong result: %s", name, tag.name, tostring(why))
        end
    elseif not res and expect and x == expect then
        local okc, why = pcall(check, false, err, x, idx)
        if okc and why == true then
            s.xerr = s.xerr + 1
            M.expectedErrors = M.expectedErrors + 1
        else
            fail("%s on %s: wrong error: %s", name, tag.name, tostring(why))
        end
    elseif not res and KILL_STATES[x] and killWindow(tag, t0) then
        s.kfail = s.kfail + 1
        M.killFailures = M.killFailures + 1
        killStates[x] = (killStates[x] or 0) + 1
    elseif res then
        fail("%s on %s: succeeded, expected SQLSTATE %s", name, tag.name, expect)
    else
        fail("%s on %s: %s [%s]", name, tag.name, tostring(err), tostring(x))
    end
end

-- how: "cb" (pgQuery), "await" (pgQueryAwait in a new coroutine) or "sync" (pgQuerySync).
-- shape: size of the result, used by the control-mode stand-in.
local function run(c, how, name, expect, check, shape, sql, ...)
    local tag = c.tag
    local id = begin(tag, name)
    if how == "cb" then
        local ok, err = D.query(c.db, shape, function(res, e, x, idx) outcome(id, tag, name, expect, check, res, e, x, idx) end, sql, ...)
        if not ok then rejected(id, tag, name, err) end
    elseif how == "await" then
        coroutine.wrap(function(db, ...)
            outcome(id, tag, name, expect, check, D.queryAwait(db, shape, sql, ...))
        end)(c.db, ...)
    else
        outcome(id, tag, name, expect, check, D.querySync(c.db, shape, sql, ...))
    end
end

local function runTx(c, how, name, expect, check, shape, statements)
    local tag = c.tag
    local id = begin(tag, name)
    if how == "cb" then
        local ok, err = D.tx(c.db, shape, statements, function(res, e, x, idx) outcome(id, tag, name, expect, check, res, e, x, idx) end)
        if not ok then rejected(id, tag, name, err) end
    elseif how == "await" then
        coroutine.wrap(function(db)
            outcome(id, tag, name, expect, check, D.txAwait(db, shape, statements))
        end)(c.db)
    else
        outcome(id, tag, name, expect, check, D.txSync(c.db, shape, statements))
    end
end

local execSeq = 0
local function execOp(c)
    local tag = c.tag
    execSeq = execSeq + 1
    local ok, err = D.exec(c.db, "INSERT INTO soak_exec(id, pool) VALUES ($1, $2)", execSeq, tag.code)
    if not ok then
        fail("exec on %s: submit failed: %s", tag.name, tostring(err))
        return
    end
    M.issued = M.issued + 1
    M.exec = M.exec + 1
    POOL[tag.code].submitted = POOL[tag.code].submitted + 1
    POOL[tag.code].exec = POOL[tag.code].exec + 1
    local s = opStats("exec")
    s.n = s.n + 1
end

local S1 = { rows = 1, cols = 1 }
local S2 = { rows = 1, cols = 2 }
local S_TYPES = { rows = 1, cols = 8 }
local S_ARRAY = { rows = 1, cols = 4 }
local S_TX = { stmts = 3, cols = 2 }

local TEXTS = { "plain", "it's \"quoted\"", "ünïcödé ✓", "", "back\\slash", "tab\there", "line\nbreak", string.rep("long", 500) }
local ARRAY_TEXTS = { "a,b", 'q"t', "back\\slash", "{brace}", "NULL", " sp ", "ü", "" }
local ERRORS = {
    { "SELECT 1/0", "22012" },
    { "SELECT * FROM soak_missing_table", "42P01" },
    { "SELEC 1", "42601" },
    { "INSERT INTO soak_uniq VALUES (1)", "23505" },
    { "SELECT $1::int AS v", "22P02", "not a number" },
}
local TX_OK = { cb = "tx_ok", await = "tx_ok_await", sync = "tx_ok_sync" }
local TX_FAIL = { cb = "tx_fail", await = "tx_fail_await" }

local BLOBS, BLOB_WEIGHTS = {}, {}
local function makeBlobs()
    local sizes = { 0, 1, 16, 255, 1024, 1500, 4096, 4096, 8192, 16384, 65536, 262144 }
    local weights = { 4, 4, 8, 8, 8, 8, 8, 8, 4, 2, 1, 0.25 }
    for i, size in ipairs(sizes) do
        local bytes = {}
        for k = 1, size do bytes[k] = string.char(math.random(0, 255)) end
        BLOBS[i] = table.concat(bytes)
        BLOB_WEIGHTS[i] = weights[i]
    end
end
local function pickBlob()
    local total = 0
    for i = 1, #BLOB_WEIGHTS do total = total + BLOB_WEIGHTS[i] end
    local r = math.random() * total
    for i = 1, #BLOB_WEIGHTS do
        r = r - BLOB_WEIGHTS[i]
        if r <= 0 then return BLOBS[i] end
    end
    return BLOBS[1]
end

local txKey = 0

local function txOk(c, how)
    txKey = txKey + 1
    local k, a = txKey, math.random(1, 1000)
    runTx(c, how, TX_OK[how], nil, function(res, affected)
        if res[1][1].k ~= k or res[1][1].v ~= a then return "insert returned " .. tostring(res[1][1].k) end
        if res[2][1].d ~= a * 2 then return "d=" .. tostring(res[2][1].d) end
        if res[3][1].n ~= 1 then return "the inserted row is not visible inside the transaction" end
        if affected[1] ~= 1 then return "affected " .. tostring(affected[1]) end
        return true
    end, S_TX, {
        { "INSERT INTO soak_tx(k, v) VALUES ($1, $2) RETURNING k, v", k, a },
        { "SELECT $1::int * 2 AS d", a },
        { "SELECT count(*)::int AS n FROM soak_tx WHERE k = $1", k },
    })
end

-- Statement 2 fails, so statement 1's row must not be committed (soak_tx is audited).
local function txFail(c, how)
    txKey = txKey + 1
    local k = txKey
    local function second(_, _, _, idx) return idx == 2 or ("failed statement " .. tostring(idx)) end
    if math.random() < 0.5 then
        runTx(c, how, TX_FAIL[how], "23505", second, S_TX, {
            { "INSERT INTO soak_tx(k, v) VALUES ($1, 0)", k }, { "INSERT INTO soak_tx(k, v) VALUES ($1, 0)", k }, "SELECT 1" })
    else
        runTx(c, how, TX_FAIL[how], "22012", second, S_TX, {
            { "INSERT INTO soak_tx(k, v) VALUES ($1, 0)", k }, "SELECT 1/0", "SELECT 1" })
    end
end

local function cbOrAwait(p) return math.random() < p and "cb" or "await" end

-- { weight, function(conn) }
local OPS = {
    { 22, function(c)
        local x = math.random(1, 1000000)
        run(c, "cb", "add", nil, function(r) return r[1].v == x + 1 or ("v=" .. tostring(r[1].v)) end,
            S1, "SELECT $1::int + 1 AS v", x)
    end },
    { 12, function(c)
        local x = math.random(1, 1000000)
        run(c, "await", "await", nil, function(r) return r[1].v == x .. "x" or ("v=" .. tostring(r[1].v)) end,
            S1, "SELECT $1::text || 'x' AS v", x)
    end },
    { 14, execOp },
    { 5, function(c)
        local k, v = math.random(1, 500), "v" .. math.random(1, 1000000)
        run(c, "cb", "upsert", nil, function(r, n)
            return (r[1].k == k and r[1].v == v and n == 1) or ("got " .. tostring(r[1].k) .. "/" .. tostring(r[1].v) .. ", affected " .. tostring(n))
        end, S2, "INSERT INTO soak_kv(k, v) VALUES ($1, $2) ON CONFLICT (k) DO UPDATE SET v = excluded.v RETURNING k, v", k, v)
    end },
    { 4, function(c)
        local big = (math.random(0, 1073741823) * 2097152 + math.random(0, 2097151)) * (math.random() < 0.5 and -1 or 1)
        local num, b = math.random(-100000, 100000) / 4, math.random() < 0.5
        local f, s = math.random(-1000000, 1000000) + 0.5, TEXTS[math.random(#TEXTS)]
        run(c, cbOrAwait(0.7), "types", nil, function(r)
            r = r[1]
            if r.big ~= big then return "int8 " .. tostring(r.big) .. " ~= " .. string.format("%.0f", big) end
            if r.huge ~= "9007199254740993" then return "int8 beyond 2^53: " .. tostring(r.huge) end
            if r.num ~= num then return "numeric " .. tostring(r.num) end
            if r.b ~= b then return "bool" end
            if r.n ~= nil then return "NULL" end
            if r.f ~= f then return "float8 " .. tostring(r.f) end
            if r.j ~= '{"a": [1, null]}' then return "jsonb " .. tostring(r.j) end
            if r.s ~= s then return "text " .. tostring(r.s) end
            return true
        end, S_TYPES, [==[SELECT $1::int8 AS big, 9007199254740993::int8 AS huge, $2::numeric AS num, $3::bool AS b,
            NULL::int AS n, $4::float8 AS f, '{"a": [1, null]}'::jsonb AS j, $5::text AS s]==], big, num, b, f, s)
    end },
    { 5, function(c) txOk(c, "cb") end },
    { 2, function(c) txOk(c, "await") end },
    { 2, function(c) txFail(c, "cb") end },
    { 1, function(c) txFail(c, "await") end },
    { 5, function(c)
        local bin = string.char(math.random(0, 255), math.random(0, 255)) .. pickBlob()
        run(c, cbOrAwait(0.7), "bytea", nil, function(r)
            return (r[1].b == bin and r[1].n == #bin) or ("bytea mismatch: length " .. tostring(r[1].n) .. ", sent " .. #bin)
        end, S2, "SELECT $1::bytea AS b, length($1::bytea) AS n", D.bytea(bin))
    end },
    { 5, function(c)
        local txt, ints = {}, {}
        for i = 1, math.random(0, 40) do
            local base = ARRAY_TEXTS[math.random(#ARRAY_TEXTS)]  -- as is ("NULL", "") or made unique
            txt[i] = math.random() < 0.1 and PG_NULL or (math.random() < 0.3 and base or base .. i)
        end
        for i = 1, (math.random() < 0.05 and 1000 or math.random(1, 50)) do ints[i] = math.random(-1000000, 1000000) end
        local m = { { math.random(1, 9), 2 }, { 3, math.random(1, 9) } }
        run(c, "cb", "array", nil, function(r)
            r = r[1]
            if r.n ~= #txt then return "cardinality " .. tostring(r.n) .. " ~= " .. #txt end
            for i = 1, #txt do
                local want = txt[i]
                if want == PG_NULL then want = nil end
                if r.t[i] ~= want then return "text[" .. i .. "] = " .. tostring(r.t[i]) end
            end
            if #r.i ~= #ints then return "int[] length " .. #r.i end
            for i = 1, #ints do
                if r.i[i] ~= ints[i] then return "int[" .. i .. "]" end
            end
            if r.m[1][1] ~= m[1][1] or r.m[2][2] ~= m[2][2] then return "2-D array" end
            return true
        end, S_ARRAY, "SELECT $1::text[] AS t, cardinality($1::text[]) AS n, $2::int[] AS i, $3::int[] AS m", txt, ints, m)
    end },
    { 5, function(c)
        local e = ERRORS[math.random(#ERRORS)]
        local function hasMessage(_, err) return (type(err) == "string" and #err > 0) or "no error message" end
        if e[3] then
            run(c, cbOrAwait(0.6), "error", e[2], hasMessage, S1, e[1], e[3])
        else
            run(c, cbOrAwait(0.6), "error", e[2], hasMessage, S1, e[1])
        end
    end },
    { 2, function(c)
        local n = math.random(100, 500)
        run(c, "cb", "medium", nil, function(r)
            if #r ~= n then return #r .. " rows, expected " .. n end
            local i = math.random(1, n)
            local row = r[i]
            return (row.id == i and row.s == "r" .. i and row.z == nil and row.f == i / 4) or ("row " .. i)
        end, { rows = n, cols = 3 }, "SELECT g AS id, 'r' || g AS s, NULL::text AS z, g / 4.0::float8 AS f FROM generate_series(1, $1) g", n)
    end },
    { 0.1, function(c)
        -- One at a time: two or three of them in flight together would set new allocator peaks
        -- (higher RSS plateaus) at random times during the whole run.
        if byOp.large and byOp.large.pending > 0 then return end
        local n = CFG.largeRows + math.random(0, CFG.largeRows)
        run(c, "cb", "large", nil, function(r)
            if #r ~= n then return #r .. " rows, expected " .. n end
            for i = 1, n do
                if r[i].id ~= i then return "row " .. i .. " has id " .. tostring(r[i].id) end
            end
            for _ = 1, 3 do
                local i = math.random(1, n)
                local row = r[i]
                if row.h ~= md5(tostring(i)):lower() or row.b ~= (i % 7 == 0) or row.f ~= i * 0.5 then return "row " .. i end
            end
            return true
        end, { rows = n, cols = 4 }, "SELECT g AS id, md5(g::text) AS h, g % 7 = 0 AS b, g * 0.5::float8 AS f FROM generate_series(1, $1) g", n)
    end },
    { 0.05, function(c)
        if math.random() < 0.5 then
            local x = math.random(1, 1000000)
            run(c, "sync", "sync", nil, function(r) return r[1].v == x * 3 or ("v=" .. tostring(r[1].v)) end,
                S1, "SELECT $1::int * 3 AS v", x)
        else
            txOk(c, "sync")
        end
    end },
    { 0.5, function(c)
        run(c, "cb", "tls", nil, function(r) return r[1].ssl == (CFG.sslmode == "require") or "pg_stat_ssl.ssl is " .. tostring(r[1].ssl) end,
            S1, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
    end },
    { 1, function(c)
        run(c, "cb", "multi", nil, function(r) return r[1].a == 2 or ("a=" .. tostring(r[1].a)) end,
            S1, "SELECT 1 AS a; SELECT 2 AS a")
    end },
    { 0.1, function(c)
        local x = math.random(1, 1000)
        run(c, "cb", "sleep", nil, function(r) return r[1].v == x or ("v=" .. tostring(r[1].v)) end,
            S2, "SELECT pg_sleep(0.02), $1::int AS v", x)
    end },
}
local TOTAL_WEIGHT = 0
for _, op in ipairs(OPS) do TOTAL_WEIGHT = TOTAL_WEIGHT + op[1] end

local function runOp(c)
    local r = math.random() * TOTAL_WEIGHT
    for i = 1, #OPS do
        r = r - OPS[i][1]
        if r <= 0 then return OPS[i][2](c) end
    end
    return OPS[1][2](c)
end

---------------------------------------------------------------------------------------------
-- drivers
---------------------------------------------------------------------------------------------

local function useModule()
    D.connect, D.close, D.stats, D.bytea, D.exec = pgConnect, pgClose, pgStats, pgBytea, pgExec
    D.query = function(db, _, cb, sql, ...) return pgQuery(db, cb, sql, ...) end
    D.queryAwait = function(db, _, sql, ...) return pgQueryAwait(db, sql, ...) end
    D.querySync = function(db, _, sql, ...) return pgQuerySync(db, sql, ...) end
    D.tx = function(db, _, statements, cb) return pgTransaction(db, statements, cb) end
    D.txAwait = function(db, _, statements) return pgTransactionAwait(db, statements) end
    D.txSync = function(db, _, statements) return pgTransactionSync(db, statements) end
end

-- Control mode: results are tables of the same size, delivered on the next frame the way the
-- module delivers them (callbacks called, coroutines resumed).
local fakeQueue = {}
local FAKE_COLS = { "id", "h", "b", "f", "s", "t", "u", "v" }

local function fakeRows(n, cols)
    local rows = {}
    for i = 1, n do
        local row = {}
        for k = 1, cols do row[FAKE_COLS[k]] = (k % 2 == 0) and ("v" .. i) or i end
        rows[i] = row
    end
    return rows
end

local function fakeResult(shape)
    if shape.stmts then
        local res, affected = {}, {}
        for s = 1, shape.stmts do
            res[s] = fakeRows(1, shape.cols)
            affected[s] = 1
        end
        return res, nil, affected
    end
    return fakeRows(shape.rows, shape.cols), nil, shape.rows
end

local function useControl()
    local function later(target, shape) fakeQueue[#fakeQueue + 1] = { target, shape } end
    D.connect = function() return { fake = true } end
    D.close = function() return true end
    D.stats = function() return { outstanding = 0, queued = 0, connected = 1, reconnects = 0, submitted = 0, succeeded = 0, failed = 0 } end
    D.bytea = function(b) return b end
    D.exec = function() return true end
    D.query = function(_, shape, cb) later(cb, shape) return true end
    D.queryAwait = function(_, shape) later(coroutine.running(), shape) return coroutine.yield() end
    D.querySync = function(_, shape) return fakeResult(shape) end
    D.tx = function(_, shape, _, cb) later(cb, shape) return true end
    D.txAwait = D.queryAwait
    D.txSync = D.querySync
end

local function deliverFakes()
    if #fakeQueue == 0 then return end
    local queue = fakeQueue
    fakeQueue = {}
    for i = 1, #queue do
        local target, shape = queue[i][1], queue[i][2]
        if type(target) == "thread" then
            local ok, err = coroutine.resume(target, fakeResult(shape))
            if not ok then fail("control coroutine: %s", tostring(err)) end
        else
            target(fakeResult(shape))
        end
    end
end

---------------------------------------------------------------------------------------------
-- load
---------------------------------------------------------------------------------------------

local loading, budget, lastTick = false, 0, getTickCount()

local function tick()
    local now = getTickCount()
    if CONTROL then deliverFakes() end
    local elapsed = now - lastTick
    lastTick = now
    if not loading then return end
    budget = math.min(budget + elapsed * CFG.rate / 1000, CFG.rate / 4)  -- no burst after a stall
    while budget >= 1 do
        if pendingN >= CFG.maxPending then
            M.throttled = M.throttled + math.floor(budget)
            budget = 0
            break
        end
        budget = budget - 1
        runOp(CONN[math.random(1, 2)])
    end
    if pendingN > M.maxPending then M.maxPending = pendingN end
end

-- Short-lived connections: opened (blocking or lazy, require or verify-full), given a few
-- queries, then closed at once with the queries in flight, closed a little later, or dropped
-- for the garbage collector to close.
local churnOpen = {}
local gcWatch = setmetatable({}, { __mode = "k" })

local function churn()
    local now = getTickCount()
    for i = #churnOpen, 1, -1 do
        local e = churnOpen[i]
        if now >= e.closeAt then
            for _ = 1, math.random(0, 5) do runOp(e.c) end
            if not D.close(e.c.db) then fail("pgClose of a churn connection returned false") end
            M.churnClosed = M.churnClosed + 1
            table.remove(churnOpen, i)
        end
    end
    if #churnOpen + countKeys(gcWatch) >= 8 then
        M.churnSkipped = M.churnSkipped + 1  -- bound the number of backends
        collectgarbage("step", 200)
        return
    end
    local verify = math.random() < 0.25
    local db, err = D.connect(verify and CONNINFO_VERIFY or CONNINFO, {
        poolSize = math.random(1, 3), lazy = math.random() < 0.5, applicationName = TAG[3].name,
        pipeline = math.random() < 0.8, batchSize = math.random(1, 64), connectTimeout = 5000,
    })
    if not db then
        fail("churn: pgConnect failed: %s", tostring(err))
        return
    end
    M.churnOpened = M.churnOpened + 1
    local c = { db = db, tag = TAG[3] }
    for _ = 1, math.random(1, 25) do runOp(c) end
    local fate = math.random()
    if fate < 0.4 then
        if not D.close(db) then fail("pgClose of a churn connection returned false") end
        M.churnClosed = M.churnClosed + 1
    elseif fate < 0.7 then
        churnOpen[#churnOpen + 1] = { c = c, closeAt = now + math.random(500, 3000) }
    else
        gcWatch[db] = true
        M.churnDropped = M.churnDropped + 1
    end
end

local killIdx = 0
local function kill()
    killIdx = killIdx % 2 + 1
    local name = TAG[killIdx].name
    local w = { from = getTickCount() }
    killWin[name] = w
    M.kills = M.kills + 1
    pgQuery(adminDb, function(rows, err)
        w.to = getTickCount()
        if not rows then
            fail("kill query failed: %s", tostring(err))
        elseif rows[1].n > 0 then
            M.killsHit = M.killsHit + 1
        end
    end, "SELECT count(pg_terminate_backend(pid))::int AS n FROM (SELECT pid FROM pg_stat_activity WHERE application_name = $1 ORDER BY random() LIMIT 1) s", name)
end

local function childCycle()
    if not child then return end
    local state = getResourceState(child)
    if state ~= "loaded" then
        fail("pgtest_child is %s, expected loaded", tostring(state))
        return
    end
    if not startResource(child) then
        fail("startResource(pgtest_child) failed")
        return
    end
    M.childStarts = M.childStarts + 1
    setTimer(function()
        if stopResource(child) then M.childStops = M.childStops + 1 else fail("stopResource(pgtest_child) failed") end
    end, math.random(100, 400), 1)
end

local function sweep()
    local now = getTickCount()
    for id, t0 in pairs(pending) do
        if now - t0 > CFG.lostSeconds * 1000 then
            fail("%s (operation %d) got no result within %d s", tostring(pendingOp[id]), id, CFG.lostSeconds)
            byOp[pendingOp[id]].pending = byOp[pendingOp[id]].pending - 1
            pending[id], pendingOp[id] = nil, nil
            pendingN = pendingN - 1
            M.lost = M.lost + 1
        end
    end
end

---------------------------------------------------------------------------------------------
-- reporting
---------------------------------------------------------------------------------------------

local backends = {}
local function refreshBackends()
    if not adminDb or CONTROL then return end
    pgQuery(adminDb, function(rows, err)
        if not rows then
            fail("backend count failed: %s", tostring(err))
            return
        end
        backends = rows[1]
        if backends.n > 80 then fail("%d backends open (max_connections is 100)", backends.n) end
    end, [==[SELECT count(*)::int AS n, count(*) FILTER (WHERE application_name = 'pgsoak-churn')::int AS churn,
        count(*) FILTER (WHERE application_name = 'pgtest_child')::int AS child
        FROM pg_stat_activity WHERE application_name LIKE 'pgsoak%' OR application_name = 'pgtest_child']==])
end

local lastStat = { t = getTickCount(), issued = 0 }
local function stat()
    local now = getTickCount()
    local kb = collectgarbage("count")
    collectgarbage("collect")
    local s = {
        t = now, ph = phaseName,
        kb = math.floor(kb), live = math.floor(collectgarbage("count")), reg = registrySize(),
        ops = M.issued, rate = math.floor((M.issued - lastStat.issued) * 1000 / math.max(now - lastStat.t, 1)),
        ok = M.ok, xerr = M.expectedErrors, kf = M.killFailures, fail = failures, pend = pendingN, lost = M.lost,
        thr = M.throttled, kills = M.kills, churn = M.churnOpened, copen = #churnOpen, gcw = countKeys(gcWatch),
        child = M.childStops, be = backends.n, bec = backends.churn,
    }
    for code = 1, 2 do
        local c = CONN[code]
        local ps = c and D.stats(c.db)
        if ps then
            local p = code == 1 and "A" or "B"
            s["o" .. p], s["q" .. p], s["rc" .. p], s["cn" .. p] = ps.outstanding, ps.queued, ps.reconnects, ps.connected
        end
    end
    lastStat.t, lastStat.issued = now, M.issued
    print("PGSOAK STAT " .. json(s))
    refreshBackends()
end

-- Warnings and errors from any resource. The only expected ones are pgExec failures caused by
-- the backend kills (pools A and B run fire-and-forget writes).
addEventHandler("onDebugMessage", root, function(message, level)
    if level ~= 1 and level ~= 2 then return end
    message = tostring(message)
    if level == 2 and (phaseName == "load" or phaseName == "drain") then
        local state = message:match("^pgExec failed: .*%[(%w%w%w%w%w)%]")
        local inWindow = killWindow(TAG[1], getTickCount()) or killWindow(TAG[2], getTickCount())
        if state and KILL_STATES[state] and inWindow then
            M.execWarnings = M.execWarnings + 1
            return
        end
        local more = message:match("^pgExec: (%d+) more failure%(s%) were not shown")
        if more and inWindow then
            M.execWarnings = M.execWarnings + tonumber(more)
            return
        end
    end
    fail("unexpected %s: %s", level == 1 and "error" or "warning", message)
end)

---------------------------------------------------------------------------------------------
-- phases
---------------------------------------------------------------------------------------------

local loadTimers = {}

local function readConfig()
    local rows, err, state = q(adminDb, "SELECT key, value FROM soak_config")
    if not rows then
        if state ~= "42P01" then error("reading soak_config: " .. tostring(err)) end
        return  -- no overrides
    end
    for _, r in ipairs(rows) do
        local default = CFG[r.key]
        if default == nil then
            fail("unknown soak_config key %s", tostring(r.key))
        elseif type(default) == "number" then
            CFG[r.key] = tonumber(r.value) or error("soak_config " .. r.key .. " is not a number: " .. r.value)
        else
            CFG[r.key] = r.value
        end
    end
end

local function setup()
    phase("setup")
    local tlsLibrary = select(3, pgVersion())
    local db, err = pgConnect("host=postgres port=5432 dbname=mta user=mta password=mta sslmode=" .. (tlsLibrary and "require" or "disable"),
        { applicationName = "pgsoak-admin" })
    if not db then error("cannot connect: " .. tostring(err)) end
    adminDb = db
    readConfig()
    if CFG.sslmode == "" then CFG.sslmode = tlsLibrary and "require" or "disable" end
    CONNINFO = "host=postgres port=5432 dbname=mta user=mta password=mta sslmode=" .. CFG.sslmode
    if CFG.hostaddr == "server" then
        CONNINFO = CONNINFO .. " hostaddr=" .. adminQuery("SELECT host(inet_server_addr()) AS ip")[1].ip
    end
    CONNINFO_VERIFY = CFG.sslmode == "require" and (CONNINFO:gsub("sslmode=require", "sslmode=verify-full sslrootcert=/certs/ca.crt")) or CONNINFO
    math.randomseed(CFG.seed)
    CONTROL = CFG.mode == "control"
    if CONTROL then useControl() elseif CFG.mode == "module" then useModule() else error("unknown mode " .. CFG.mode) end
    local ok, serr = pgQuerySync(adminDb, SCHEMA)
    if not ok then error("schema: " .. tostring(serr)) end
    local tls = adminQuery("SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid()")[1]
    if tls.ssl ~= (tlsLibrary ~= nil) then fail("admin connection: pg_stat_ssl.ssl is %s", tostring(tls.ssl)) end
    local moduleVersion, libpq = pgVersion()
    local v = getVersion()
    print("PGSOAK CONFIG " .. json({ cfg = CFG, module = moduleVersion, libpq = libpq, mta = v.tag, tls = tls.version or "none",
        tlsLibrary = tlsLibrary,
        registry = registrySize() ~= nil, child = child ~= nil }))
    if not child and not CONTROL then fail("resource pgtest_child not found") end
    makeBlobs()
    setTimer(stat, CFG.sampleSeconds * 1000, 0)
    if not setServerConfigSetting("server_logic_fps_limit", tostring(CFG.fpsLimit), false) then
        fail("setServerConfigSetting(server_logic_fps_limit) failed")
    end
    pgClose(adminDb)
    adminDb = nil
    collectgarbage()
    sleep(3000)  -- the pool's thread exits and is joined
end

local function startLoad()
    phase("load")
    for code = 1, 2 do
        local tag = TAG[code]
        local db, err = D.connect(CONNINFO, { poolSize = code == 1 and 1 or 4, applicationName = tag.name })
        if not db then error("cannot open " .. tag.name .. ": " .. tostring(err)) end
        CONN[code] = { db = db, tag = tag }
    end
    if not CONTROL then
        local db, err = pgConnect(CONNINFO, { applicationName = "pgsoak-admin" })
        if not db then error("cannot open the admin connection: " .. tostring(err)) end
        adminDb = db
    end
    lastTick, budget, loading = getTickCount(), 0, true
    loadTimers = {
        setTimer(sweep, 5000, 0),
        setTimer(churn, CFG.churnMs, 0),
    }
    if not CONTROL then
        loadTimers[#loadTimers + 1] = setTimer(kill, CFG.killSeconds * 1000, 0)
        if child then loadTimers[#loadTimers + 1] = setTimer(childCycle, CFG.childSeconds * 1000, 0) end
    end
end

local function stopLoad()
    loading = false
    for _, t in ipairs(loadTimers) do
        if isTimer(t) then killTimer(t) end
    end
    loadTimers = {}
end

local function auditPools()
    for code = 1, 2 do
        local c, p = CONN[code], POOL[code]
        if not waitUntil(function() return D.stats(c.db).outstanding == 0 end, 30000) then
            fail("%s: outstanding stays at %d after the load stopped", c.tag.name, D.stats(c.db).outstanding)
        end
        local s = D.stats(c.db)
        if s.submitted ~= p.submitted then
            fail("%s: the module counted %d submitted jobs, the script %d", c.tag.name, s.submitted, p.submitted)
        end
        if s.succeeded + s.failed ~= s.submitted then
            fail("%s: %d succeeded + %d failed ~= %d submitted", c.tag.name, s.succeeded, s.failed, s.submitted)
        end
        -- failed jobs the script did not see a result for are fire-and-forget writes
        p.execFail = s.failed - p.cbFail
        if p.execFail < 0 then fail("%s: %d failed jobs, but the script saw %d failed results", c.tag.name, s.failed, p.cbFail) end
        p.reconnects, p.outstanding = s.reconnects, s.outstanding
    end
end

local function auditDatabase()
    local landed = { 0, 0, 0 }
    for _, r in ipairs(adminQuery("SELECT pool, count(*)::int AS n FROM soak_exec GROUP BY pool")) do landed[r.pool] = r.n end
    for code = 1, 3 do
        local p = POOL[code]
        p.landed = landed[code]
        -- a write that failed with 08006 may or may not have run
        if landed[code] > p.exec or landed[code] < p.exec - p.execFail then
            fail("%s: %d of %d pgExec writes landed (%d failed)", TAG[code].name, landed[code], p.exec, p.execFail)
        end
    end
    if M.execWarnings > POOL[1].execFail + POOL[2].execFail then
        fail("%d pgExec warnings for %d failed writes", M.execWarnings, POOL[1].execFail + POOL[2].execFail)
    end

    local txRows = adminQuery("SELECT count(*)::int AS n FROM soak_tx")[1].n
    local okTx, unknownTx = 0, 0
    for _, name in pairs(TX_OK) do
        local s = byOp[name]
        if s then okTx, unknownTx = okTx + s.ok, unknownTx + s.kfail end
    end
    M.txCommitted, M.txRows, M.txUnknown = okTx, txRows, unknownTx
    if txRows < okTx or txRows > okTx + unknownTx then
        fail("soak_tx has %d rows: %d transactions committed, %d with unknown outcome (failed transactions must leave nothing)", txRows, okTx, unknownTx)
    end

    if child then
        waitUntil(function() return getResourceState(child) == "loaded" end, 5000)
        local markers = 0
        waitUntil(function()
            markers = adminQuery("SELECT count(*)::int AS n FROM child_marker")[1].n
            return markers >= M.childStops
        end, 30000)
        M.childMarkers = markers
        if markers ~= M.childStops then fail("%d onResourceStop writes from pgtest_child for %d stops", markers, M.childStops) end
    end

    collectgarbage()
    collectgarbage()
    local left = 0
    if not waitUntil(function()
        left = adminQuery("SELECT count(*)::int AS n FROM pg_stat_activity WHERE application_name IN ('pgsoak-churn', 'pgtest_child')")[1].n
        return left == 0
    end, 30000) then
        fail("%d churn/child backends still open 30 s after the load stopped", left)
    end
end

local function drain()
    stopLoad()
    phase("drain")
    for i = #churnOpen, 1, -1 do
        D.close(churnOpen[i].c.db)
        M.churnClosed = M.churnClosed + 1
        churnOpen[i] = nil
    end
    if not waitUntil(function() return pendingN == 0 end, 120000) then
        local names = {}
        for _, name in pairs(pendingOp) do names[name] = (names[name] or 0) + 1 end
        fail("%d operations still without a result after the load stopped: %s", pendingN, json(names))
    end
    if not CONTROL then
        auditPools()
        auditDatabase()
    end
    for code = 1, 2 do
        D.close(CONN[code].db)
        CONN[code] = nil
    end
    if adminDb then
        pgClose(adminDb)
        adminDb = nil
    end
    collectgarbage()
    collectgarbage()
    local dropped = countKeys(gcWatch)
    if dropped > 0 then fail("%d dropped connections were never garbage-collected", dropped) end
    sleep(5000)  -- every pool's threads exit and are joined
end

local function report()
    local r = {
        ok = failures == 0, failures = failures, mode = CFG.mode, loadSeconds = CFG.loadSeconds,
        ops = M.issued, completed = M.completed, okResults = M.ok, expectedErrors = M.expectedErrors,
        killFailures = M.killFailures, killStates = killStates, lost = M.lost, throttled = M.throttled,
        maxPending = M.maxPending, kills = M.kills, killsHit = M.killsHit,
        churn = { opened = M.churnOpened, closed = M.churnClosed, dropped = M.churnDropped, skipped = M.churnSkipped },
        child = { starts = M.childStarts, stops = M.childStops, markers = M.childMarkers },
        execWarnings = M.execWarnings, tx = { committed = M.txCommitted, rows = M.txRows, unknown = M.txUnknown },
        luaKB = math.floor(collectgarbage("count")), registry = registrySize(),
    }
    for code = 1, 3 do
        local p = POOL[code]
        r[TAG[code].name] = { submitted = p.submitted, exec = p.exec, landed = p.landed, execFail = p.execFail,
            reconnects = p.reconnects, outstanding = p.outstanding }
    end
    print("PGSOAK REPORT " .. json(r))
    print("PGSOAK OPS " .. json(byOp))
end

local function finishWithShutdown()
    phase("shutdown")
    -- Queue a burst of writes and shut down at once: the module must drain them before the
    -- process exits (tests/soak.sh counts the rows afterwards).
    local db = pgConnect(CONNINFO, { applicationName = "pgsoak-drain" })
    if db then
        for i = 1, CFG.drainRows do pgExec(db, "INSERT INTO soak_drain(v) VALUES ($1)", i) end
    else
        fail("cannot open the drain connection")
    end
    print("PGSOAK DRAIN queued=" .. CFG.drainRows)
    setServerConfigSetting("server_logic_fps_limit", "0", false)
    shutdown("pgsoak finished")
end

local aborted = false
abort = function()
    if aborted then return end
    aborted = true
    stopLoad()
    report()
    setTimer(function() shutdown("pgsoak aborted") end, 2000, 1)
end

local started = getTickCount()

local function main()
    setup()
    sleep(math.max(0, started + CFG.settleSeconds * 1000 - getTickCount()))
    phase("baseline")
    sleep(CFG.baselineSeconds * 1000)
    startLoad()
    sleep(CFG.loadSeconds * 1000)
    drain()
    report()
    phase("final")
    sleep(CFG.finalSeconds * 1000)
    finishWithShutdown()
end

addEventHandler("onResourceStart", resourceRoot, function()
    setTimer(tick, 0, 0)
    mainCo = coroutine.create(main)
    setTimer(resumeMain, 1000, 1)  -- let the server finish starting up
end)
