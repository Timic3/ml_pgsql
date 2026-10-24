-- ml_pgsql integration tests, run inside the real MTA server (see tests/run.sh).
-- Output protocol: "PGTEST PASS <name>", "PGTEST FAIL <name>: <reason>", "PGTEST SUMMARY ...".

local CONNINFO = "host=postgres user=mta password=mta dbname=mta"

local tests = {}
local current
local passed, failed = 0, 0
local debugLog = {}
local DB

local function test(name, fn, timeout)
    tests[#tests + 1] = { name = name, fn = fn, timeout = timeout }
end

addEventHandler("onDebugMessage", root, function(message, level)
    debugLog[#debugLog + 1] = { msg = tostring(message), level = level }
end)

local function findDebug(pattern, level)
    for _, entry in ipairs(debugLog) do
        if entry.msg:find(pattern, 1, true) and (not level or entry.level == level) then
            return entry
        end
    end
end

-- ---------------------------------------------------------------------------------------
-- coroutine helpers
-- ---------------------------------------------------------------------------------------

local function resumeCo(co, ...)
    if coroutine.status(co) ~= "suspended" then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok and current and current.co == co then
        current.err = current.err or tostring(err)
    end
end

local function wait(ms)
    local co = coroutine.running()
    -- MTA timers cannot pass coroutines as arguments; capture it instead
    setTimer(function() resumeCo(co) end, math.max(ms, 50), 1)
    coroutine.yield()
end

local function waitUntil(cond, timeoutMs, what)
    local deadline = getTickCount() + (timeoutMs or 5000)
    while not cond() do
        if getTickCount() > deadline then error("timeout waiting for " .. (what or "condition"), 2) end
        wait(50)
    end
end

local function check(cond, msg)
    if not cond then error(msg or "check failed", 2) end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s (%s), got %s (%s)", msg or "value", tostring(expected), type(expected),
            tostring(actual), type(actual)), 2)
    end
end

local function pack(...) return { n = select("#", ...), ... } end

-- pgQuery wrapped so a test reads like straight-line code
local function q(db, sql, ...)
    local co, res = coroutine.running(), nil
    local ok, err = pgQuery(db, function(...) res = pack(...); resumeCo(co) end, sql, ...)
    if not ok then return false, err end
    if not res then coroutine.yield() end
    return unpack(res, 1, res.n)
end

local function tx(db, statements)
    local co, res = coroutine.running(), nil
    local ok, err = pgTransaction(db, statements, function(...) res = pack(...); resumeCo(co) end)
    if not ok then return false, err end
    if not res then coroutine.yield() end
    return unpack(res, 1, res.n)
end

local function scalar(db, sql, ...)
    local rows, err = q(db, sql, ...)
    check(rows, "query failed: " .. tostring(err))
    local _, v = next(rows[1] or {})
    return v
end

local function backendCount(app)
    return scalar(DB, "SELECT count(*)::int AS n FROM pg_stat_activity WHERE application_name = $1", app)
end

-- ---------------------------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------------------------

local runNext
local index = 0

local function finishTest(ok, msg)
    local t = current
    current = nil
    if isTimer(t.watchdog) then killTimer(t.watchdog) end
    local ms = getTickCount() - t.started
    if ok then
        passed = passed + 1
        print(string.format("PGTEST PASS %s (%d ms)", t.name, ms))
    else
        failed = failed + 1
        print(string.format("PGTEST FAIL %s: %s", t.name, tostring(msg)))
    end
    setTimer(runNext, 50, 1)
end

local function shutdownPhase()
    -- Queue a burst of writes and shut the server down immediately: the module must drain
    -- them before the process exits (tests/run.sh counts the rows afterwards).
    for i = 1, 3000 do
        pgExec(DB, "INSERT INTO drain_test(v) VALUES ($1)", i)
    end
    print("PGTEST DRAIN queued=3000")
    shutdown("pgtest finished")
end

runNext = function()
    index = index + 1
    local t = tests[index]
    if not t then
        print(string.format("PGTEST SUMMARY passed=%d failed=%d", passed, failed))
        setTimer(shutdownPhase, 200, 1)
        return
    end
    local rec = { name = t.name, started = getTickCount() }
    rec.co = coroutine.create(function()
        t.fn()
        rec.done = true
    end)
    current = rec
    local logStart = #debugLog
    rec.watchdog = setTimer(function()
        if current ~= rec then return end
        if coroutine.status(rec.co) == "dead" then
            if rec.done and not rec.err then
                finishTest(true)
            else
                local reason = rec.err
                if not reason then
                    for i = logStart + 1, #debugLog do
                        if debugLog[i].level == 1 then reason = debugLog[i].msg end
                    end
                end
                finishTest(false, reason or "test coroutine died")
            end
        elseif getTickCount() - rec.started > (t.timeout or 30000) then
            finishTest(false, "timeout")
        end
    end, 50, 0)
    resumeCo(rec.co)
end

-- ---------------------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------------------

test("connect: main connection and schema", function()
    local db, err = pgConnect(CONNINFO)
    check(db, "pgConnect failed: " .. tostring(err))
    DB = db
    check(tostring(db):find("pgsql-connection", 1, true), "tostring")
    local module, libpq, tls = pgVersion()
    check(type(module) == "string" and libpq >= 170000, "pgVersion")
    eq(tls, "OpenSSL", "pgVersion TLS library")
    local ok, err2 = pgQuerySync(DB, [==[
        DROP TABLE IF EXISTS ord, tx_test, ms_test, child_marker, drain_test, uniq;
        CREATE TABLE ord(id serial PRIMARY KEY, seq int);
        CREATE TABLE tx_test(id serial PRIMARY KEY, v int UNIQUE);
        CREATE TABLE ms_test(x int);
        CREATE TABLE child_marker(id serial PRIMARY KEY, note text);
        CREATE TABLE drain_test(v int);
        CREATE TABLE uniq(k int PRIMARY KEY);
    ]==])
    check(ok, "schema: " .. tostring(err2))
end)

test("connect: invalid connection string", function()
    local db, err = pgConnect("host='unterminated")
    check(not db, "should fail")
    check(err:find("invalid connection string", 1, true), err)
end)

test("connect: wrong password fails fast", function()
    local t0 = getTickCount()
    local db, err = pgConnect("host=postgres user=mta password=wrong dbname=mta")
    check(not db, "should fail")
    check(err:find("password authentication failed", 1, true), err)
    check(getTickCount() - t0 < 3000, "took too long")
end)

test("connect: unreachable host respects connectTimeout", function()
    local t0 = getTickCount()
    local db, err = pgConnect("host=10.255.255.1 user=mta dbname=mta", { connectTimeout = 500 })
    check(not db, "should fail")
    check(getTickCount() - t0 < 2500, "took " .. (getTickCount() - t0) .. " ms: " .. tostring(err))
end)

test("connect: lazy connection to a closed port fails queries with 08001", function()
    local db = pgConnect("host=postgres port=1 user=mta dbname=mta", { lazy = true })
    check(db, "lazy connect returns a handle")
    local rows, err, state = q(db, "SELECT 1")
    eq(rows, false, "rows")
    eq(state, "08001", "sqlstate (" .. tostring(err) .. ")")
    pgClose(db)
end)

test("connect: bad arguments raise", function()
    check(not pcall(pgConnect), "no args")
    check(not pcall(pgConnect, CONNINFO, { poolSize = 0 }), "poolSize 0")
    check(not pcall(pgConnect, CONNINFO, { poolSize = "x" }), "poolSize type")
    check(not pcall(pgConnect, CONNINFO, { int64 = "huge" }), "int64 mode")
    local ok, err = pcall(pgQuery, "not a connection", function() end, "SELECT 1")
    check(not ok and err:find("ml_pgsql.connection", 1, true), tostring(err))
end)

test("types: scalars", function()
    local rows, err = q(DB, [==[SELECT true AS t, false AS f, 1::int2 AS i2, (-2147483648)::int4 AS i4,
        9007199254740992::int8 AS i8safe, 9007199254740993::int8 AS i8big, -9007199254740993::int8 AS i8neg,
        1.5::float4 AS f4, 'NaN'::float8 AS nan, 'Infinity'::float8 AS inf, '-Infinity'::float8 AS ninf,
        12345.678::numeric AS num, 'héllo'::text AS txt, NULL::int AS nul, '{"a":1}'::jsonb AS js,
        '2024-01-02 03:04:05'::timestamp AS ts, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS id, ''::text AS empty]==])
    check(rows and #rows == 1, "one row: " .. tostring(err))
    local r = rows[1]
    eq(r.t, true, "bool true"); eq(r.f, false, "bool false")
    eq(r.i2, 1, "int2"); eq(r.i4, -2147483648, "int4")
    eq(r.i8safe, 9007199254740992, "int8 safe"); eq(r.i8big, "9007199254740993", "int8 big")
    eq(r.i8neg, "-9007199254740993", "int8 neg big")
    eq(r.f4, 1.5, "float4"); check(r.nan ~= r.nan, "NaN"); eq(r.inf, math.huge, "inf"); eq(r.ninf, -math.huge, "-inf")
    eq(r.num, 12345.678, "numeric"); eq(r.txt, "héllo", "text"); eq(r.nul, nil, "NULL")
    eq(r.js, '{"a": 1}', "jsonb"); eq(r.ts, "2024-01-02 03:04:05", "timestamp")
    eq(r.id, "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "uuid"); eq(r.empty, "", "empty string")
end)

test("types: int64 and numeric modes", function()
    local s = pgConnect(CONNINFO, { int64 = "string", numeric = "string" })
    local rows = q(s, "SELECT 5::int8 AS a, 1.10::numeric AS n")
    eq(rows[1].a, "5", "int64=string"); eq(rows[1].n, "1.10", "numeric=string")
    pgClose(s)
    local n = pgConnect(CONNINFO, { int64 = "number" })
    rows = q(n, "SELECT 9007199254740993::int8 AS a")
    eq(type(rows[1].a), "number", "int64=number")
    pgClose(n)
end)

test("types: bytea round trip of all byte values", function()
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
    local blob = table.concat(bytes)
    local rows, err = q(DB, "SELECT $1::bytea AS b, length($1::bytea) AS n, ''::bytea AS e", pgBytea(blob))
    check(rows, err)
    eq(rows[1].n, 256, "length"); eq(rows[1].b, blob, "bytes"); eq(rows[1].e, "", "empty bytea")
    local ok, perr = pcall(pgQuery, DB, function() end, "SELECT $1", "nul\0byte")
    check(not ok and perr:find("NUL", 1, true), "NUL in text param must raise: " .. tostring(perr))
end)

test("types: arrays", function()
    local rows, err = q(DB, [==[SELECT ARRAY[1,2,3] AS a, ARRAY[[1,2],[3,4]] AS m,
        ARRAY['x','a,b','q"t','back\slash','{brace}',NULL,'NULL']::text[] AS s, '{}'::int[] AS e,
        ARRAY[true,false] AS b, ARRAY[1.5,NULL]::float8[] AS f, '[0:1]={7,8}'::int[] AS lb,
        ARRAY[9007199254740993]::int8[] AS big]==])
    check(rows, err)
    local r = rows[1]
    eq(#r.a, 3, "#a"); eq(r.a[3], 3, "a[3]")
    eq(r.m[2][1], 3, "m[2][1]")
    eq(r.s[1], "x", "s1"); eq(r.s[2], "a,b", "s2"); eq(r.s[3], 'q"t', "s3"); eq(r.s[4], "back\\slash", "s4")
    eq(r.s[5], "{brace}", "s5"); eq(r.s[6], nil, "s6 NULL"); eq(r.s[7], "NULL", "s7 'NULL' string")
    eq(next(r.e), nil, "empty array")
    eq(r.b[1], true, "bool[]"); eq(r.f[1], 1.5, "float[]"); eq(r.f[2], nil, "float[] NULL")
    eq(r.lb[1], 7, "lower bound decoration"); eq(r.big[1], "9007199254740993", "int8[] auto")
end)

test("params: values and arrays", function()
    local rows, err = q(DB, "SELECT $1::int AS a, $2::text AS b, $3::bool AS c, $4::float8 AS d, $5::int AS e, " ..
        "$6::int[] AS f, $7::text[] AS g, $8::int8 AS h, $9::float8 AS i, $10::int[] AS j",
        42, "it's \"quoted\" ünïcode", true, 0.1, nil, { 1, 2, 3 }, { "a", PG_NULL, 'x"y' }, 2 ^ 53, -1.25e-7, { { 1, 2 }, { 3, 4 } })
    check(rows, err)
    local r = rows[1]
    eq(r.a, 42, "int"); eq(r.b, "it's \"quoted\" ünïcode", "text"); eq(r.c, true, "bool"); eq(r.d, 0.1, "float")
    eq(r.e, nil, "nil"); eq(r.f[3], 3, "int[]"); eq(r.g[1], "a", "text[] 1"); eq(r.g[2], nil, "PG_NULL in array")
    eq(r.g[3], 'x"y', "text[] quote"); eq(r.h, 9007199254740992, "2^53"); eq(r.i, -1.25e-7, "small float")
    eq(r.j[2][2], 4, "2-D array param")
    eq(scalar(DB, "SELECT count(*)::int AS n FROM generate_series(1, 10) s WHERE s = ANY($1)", { 2, 4, 6 }), 3, "ANY($1)")
end)

test("params: invalid values raise", function()
    local function raises(pattern, ...)
        local ok, err = pcall(pgQuery, DB, function() end, "SELECT $1", ...)
        check(not ok, "expected an error for " .. pattern)
        check(tostring(err):find(pattern, 1, true), "error '" .. tostring(err) .. "' lacks '" .. pattern .. "'")
    end
    raises("unsupported parameter type", function() end)
    raises("must be arrays", { a = 1 })
    raises("nested too deeply", { { { { { { { 1 } } } } } } })
    local cyclic = {}
    cyclic[1] = cyclic
    raises("nested too deeply", cyclic)
    check(not pcall(pgQuery, DB, "not a function", "SELECT 1"), "callback type")
end)

test("params: many parameters and a large array", function()
    local parts, values = {}, {}
    for i = 1, 1000 do
        parts[i] = "$" .. i .. "::int"
        values[i] = i
    end
    eq(scalar(DB, "SELECT " .. table.concat(parts, "+") .. " AS s", unpack(values)), 500500, "1000 params")
    local big = {}
    for i = 1, 100000 do big[i] = i end
    eq(scalar(DB, "SELECT array_length($1::int[], 1) AS n", big), 100000, "100k element array")
end)

test("errors: sqlstate codes", function()
    local rows, err, state = q(DB, "SELECT * FROM missing_table")
    eq(rows, false, "rows"); eq(state, "42P01", "undefined table"); check(err:find("missing_table", 1, true), err)
    rows, err, state = q(DB, "SELEC 1")
    eq(state, "42601", "syntax error")
    q(DB, "INSERT INTO uniq VALUES (1)")
    rows, err, state = q(DB, "INSERT INTO uniq VALUES (1)")
    eq(state, "23505", "unique violation")
end)

test("callback errors are reported and do not break the connection", function()
    pgQuery(DB, function() error("boom-in-callback") end, "SELECT 1")
    waitUntil(function() return findDebug("boom-in-callback", 1) end, 3000, "callback error report")
    eq(scalar(DB, "SELECT 1 AS x"), 1, "connection still works")
end)

test("exec: failures are logged with the call site", function()
    pgExec(DB, "SELECT * FROM missing_table_exec")
    waitUntil(function() return findDebug("missing_table_exec", 2) end, 3000, "pgExec warning")
    check(findDebug("pgtest/server.lua:", 2), "warning names the calling file and line")
end)

test("exec: multi-statement scripts and multiple results", function()
    pgExec(DB, "TRUNCATE ms_test; INSERT INTO ms_test VALUES (1), (2);")
    eq(scalar(DB, "SELECT count(*)::int AS n FROM ms_test"), 2, "both statements ran")
    local rows = q(DB, "SELECT 1 AS a; SELECT 2 AS a")
    eq(rows[1].a, 2, "last result is returned")
end)

test("COPY FROM STDIN fails cleanly and the connection survives", function()
    local rows, err = q(DB, "COPY ms_test FROM STDIN")
    eq(rows, false, "COPY FROM STDIN must fail")
    check(err:find("not supported", 1, true), err)
    eq(scalar(DB, "SELECT 5 AS x"), 5, "connection still works")
    local out, err2 = q(DB, "COPY ms_test TO STDOUT")
    check(out, "COPY TO STDOUT: " .. tostring(err2))
    eq(scalar(DB, "SELECT 6 AS x"), 6, "connection still works after COPY OUT")
end)

test("transaction: commit, results and affected rows", function()
    local results, err, affected = tx(DB, {
        "TRUNCATE tx_test",
        { "INSERT INTO tx_test(v) VALUES ($1), ($2) RETURNING id, v", 1, 2 },
        "SELECT count(*)::int AS n FROM tx_test",
    })
    check(results, err)
    eq(#results[2], 2, "RETURNING rows"); eq(results[2][2].v, 2, "returned value")
    eq(results[3][1].n, 2, "visible inside the transaction"); eq(affected[2], 2, "affected")
end)

test("transaction: failure rolls everything back", function()
    local results, err, state, index = tx(DB, {
        { "INSERT INTO tx_test(v) VALUES ($1)", 100 },
        { "INSERT INTO tx_test(v) VALUES ($1)", 1 },
        { "INSERT INTO tx_test(v) VALUES ($1)", 101 },
    })
    eq(results, false, "must fail"); eq(state, "23505", "sqlstate"); eq(index, 2, "failed statement index")
    eq(scalar(DB, "SELECT count(*)::int AS n FROM tx_test WHERE v IN (100, 101)"), 0, "rolled back")
end)

test("transaction: control statements and bad shapes are rejected", function()
    local ok, err = pcall(pgTransaction, DB, { "BEGIN", "SELECT 1" }, function() end)
    check(not ok and err:find("not allowed", 1, true), tostring(err))
    ok, err = pcall(pgTransaction, DB, {}, function() end)
    check(not ok and err:find("empty", 1, true), tostring(err))
    ok, err = pcall(pgTransaction, DB, { 42 }, function() end)
    check(not ok, "non-string statement")
    local results, terr = pgTransactionSync(DB, { { "SELECT $1::int AS a, $2::int AS b, $3::int AS c", 1, nil, 3 } })
    check(results, terr)
    eq(results[1][1].b, nil, "nil hole in statement params")
    eq(results[1][1].c, 3, "param after a nil hole")
end)

test("sessions never stay inside a transaction block", function()
    local ok, err = pcall(pgExec, DB, "BEGIN")
    check(not ok and tostring(err):find("pgTransaction", 1, true), "standalone BEGIN must raise: " .. tostring(err))
    check(not pcall(pgQuery, DB, function() end, "START TRANSACTION"), "START TRANSACTION must raise")
    -- a script that opens a block and never commits is rolled back and reported
    local rows, e1, s1 = q(DB, "BEGIN; INSERT INTO ms_test VALUES (42);")
    eq(rows, false, "open block must fail"); eq(s1, "25000", "sqlstate (" .. tostring(e1) .. ")")
    eq(scalar(DB, "SELECT count(*)::int AS n FROM ms_test WHERE x = 42"), 0, "rolled back")
    eq(scalar(DB, "SELECT pg_current_xact_id_if_assigned() IS NULL AS fresh"), true, "next query runs outside the old block")
    -- a failing script must not poison the session with 25P02
    q(DB, "DELETE FROM uniq")
    local r2, e2, s2 = q(DB, "BEGIN; INSERT INTO uniq VALUES (7); INSERT INTO uniq VALUES (7); COMMIT;")
    eq(r2, false, "failing script"); eq(s2, "23505", "sqlstate (" .. tostring(e2) .. ")")
    eq(scalar(DB, "SELECT count(*)::int AS n FROM uniq WHERE k = 7"), 0, "nothing committed, session usable")
    -- a complete script still works
    local r3, e3 = q(DB, "BEGIN; INSERT INTO uniq VALUES (8); COMMIT;")
    check(r3, e3)
    eq(scalar(DB, "SELECT count(*)::int AS n FROM uniq WHERE k = 8"), 1, "script committed")
end)

test("transaction: atomic even for statements that cannot run in a block", function()
    local res, err = tx(DB, { "VACUUM uniq", "SELECT 1" })
    eq(res, false, "VACUUM inside pgTransaction must fail")
    check(err:find("transaction block", 1, true), err)
    -- COMMIT-time failures (deferred constraints) fail the transaction
    pgQuerySync(DB, "DROP TABLE IF EXISTS deferred_test; CREATE TABLE deferred_test(k int UNIQUE DEFERRABLE INITIALLY DEFERRED)")
    local r2, e2, s2 = tx(DB, { { "INSERT INTO deferred_test VALUES ($1)", 1 }, { "INSERT INTO deferred_test VALUES ($1)", 1 } })
    eq(r2, false, "deferred violation at COMMIT"); eq(s2, "23505", "sqlstate (" .. tostring(e2) .. ")")
    eq(scalar(DB, "SELECT count(*)::int AS n FROM deferred_test"), 0, "nothing committed")
    eq(scalar(DB, "SELECT 1 AS x"), 1, "session usable")
end)

test("await: query, transaction and errors", function()
    local rows, err = pgQueryAwait(DB, "SELECT 7 AS x")
    check(rows, err)
    eq(rows[1].x, 7, "await result")
    local r2, e2, s2 = pgQueryAwait(DB, "SELECT 1/0")
    eq(r2, false, "await error"); eq(s2, "22012", "sqlstate")
    local tr = pgTransactionAwait(DB, { "SELECT 1 AS a", "SELECT 2 AS b" })
    eq(tr[2][1].b, 2, "transaction await")
    local m = DB:queryAwait("SELECT 3 AS c")
    eq(m[1].c, 3, "method syntax")
end)

test("await: outside a coroutine and across pcall raise without leaking", function()
    local result
    setTimer(function() result = pack(pcall(pgQueryAwait, DB, "SELECT 1")) end, 50, 1)
    waitUntil(function() return result end, 2000, "timer")
    check(not result[1] and tostring(result[2]):find("inside a coroutine", 1, true), tostring(result[2]))
    for _ = 1, 200 do
        local ok, err = pcall(pgQueryAwait, DB, "SELECT 1")
        check(not ok and tostring(err):find("yield", 1, true), "yield across pcall must raise: " .. tostring(err))
    end
    local rows = pgQueryAwait(DB, "SELECT 8 AS x")
    eq(rows[1].x, 8, "await still works afterwards")
end)

test("await results survive GC finalizers running during delivery", function()
    collectgarbage("setpause", 50)
    collectgarbage("setstepmul", 1000)
    local good = 0
    for _ = 1, 30 do
        coroutine.wrap(function()
            local rows = pgQueryAwait(DB, "SELECT g, 'row' || g AS s FROM generate_series(1, 40) g")
            if rows and #rows == 40 and rows[40].s == "row40" and rows[1].g == 1 then good = good + 1 end
        end)()
        for _ = 1, 3 do
            pgConnect(CONNINFO, { lazy = true })  -- garbage with a __gc finalizer
        end
    end
    waitUntil(function() return good == 30 end, 15000, "all awaits with intact results")
    collectgarbage("setpause", 200)
    collectgarbage("setstepmul", 200)
end, 30000)

test("hidden transaction control is detected (nested comments, empty statements)", function()
    local ok, err = pcall(pgExec, DB, "/* a /* b */ c */ BEGIN")
    check(not ok and tostring(err):find("pgTransaction", 1, true), "nested-comment BEGIN must raise: " .. tostring(err))
    ok, err = pcall(pgTransaction, DB, { "SELECT 1", "; COMMIT", "SELECT 1/0" }, function() end)
    check(not ok and tostring(err):find("not allowed", 1, true), "empty-statement COMMIT must raise: " .. tostring(err))
    ok, err = pcall(pgTransaction, DB, { "/* x /* y */ */ ROLLBACK" }, function() end)
    check(not ok, "nested-comment ROLLBACK must raise")
    local rows = q(DB, "SELECT")
    eq(#rows, 1, "zero-column result keeps its row")
    eq(next(rows[1]), nil, "row without columns")
end)

test("sync: results, syncTimeout and dropped late result", function()
    local rows = pgQuerySync(DB, "SELECT 9 AS x")
    eq(rows[1].x, 9, "sync result")
    local db = pgConnect(CONNINFO, { syncTimeout = 300 })
    local t0 = getTickCount()
    local ok, err = pgQuerySync(db, "SELECT pg_sleep(1)")
    eq(ok, false, "must time out")
    check(err:find("timed out", 1, true), err)
    check(getTickCount() - t0 < 1000, "returned after syncTimeout")
    wait(1000)
    eq(pgQuerySync(db, "SELECT 10 AS x")[1].x, 10, "connection usable after a timed-out sync call")
    pgClose(db)
end)

test("queryTimeout cancels long statements (57014)", function()
    local db = pgConnect(CONNINFO, { queryTimeout = 200 })
    local rows, err, state = q(db, "SELECT pg_sleep(2)")
    eq(rows, false, "must fail"); eq(state, "57014", "sqlstate (" .. tostring(err) .. ")")
    eq(scalar(db, "SELECT 1 AS x"), 1, "next query fine")
    pgClose(db)
end)

test("ordering: poolSize=1 preserves submission order and pipelines", function()
    local before = pgStats(DB).roundTrips
    for i = 1, 2000 do
        pgExec(DB, "INSERT INTO ord(seq) VALUES ($1)", i)
    end
    local rows = q(DB, "SELECT seq FROM ord ORDER BY id")
    eq(#rows, 2000, "row count")
    for i = 1, 2000 do
        if rows[i].seq ~= i then error("out of order at " .. i .. ": " .. tostring(rows[i].seq)) end
    end
    local trips = pgStats(DB).roundTrips - before
    check(trips < 200, "2000 queries took " .. trips .. " round trips (pipelining not effective)")
end)

test("poolSize=4 runs queries in parallel", function()
    local db = pgConnect(CONNINFO, { poolSize = 4 })
    waitUntil(function() return pgStats(db).connected == 4 end, 3000, "4 connections")
    local done, t0 = 0, getTickCount()
    for _ = 1, 4 do
        pgQuery(db, function() done = done + 1 end, "SELECT pg_sleep(0.5)")
    end
    waitUntil(function() return done == 4 end, 5000, "4 sleeps")
    local elapsed = getTickCount() - t0
    check(elapsed < 1200, "4 x 0.5s took " .. elapsed .. " ms")
    pgClose(db)
end)

test("maxQueue applies backpressure", function()
    local db = pgConnect(CONNINFO, { maxQueue = 5 })
    local accepted, rejected, fired = 0, 0, 0
    pgQuery(db, function() fired = fired + 1 end, "SELECT pg_sleep(0.3)")
    wait(100)
    for _ = 1, 20 do
        local ok, err = pgQuery(db, function() fired = fired + 1 end, "SELECT 1")
        if ok then accepted = accepted + 1 else
            rejected = rejected + 1
            check(err:find("queue is full", 1, true), err)
        end
    end
    -- maxQueue counts every undelivered query, including the one that is running
    eq(accepted, 4, "accepted"); eq(rejected, 16, "rejected")
    waitUntil(function() return fired == 5 end, 3000, "accepted callbacks")
    eq(pgStats(db).outstanding, 0, "nothing outstanding afterwards")
    pgClose(db)
end)

test("reconnect: idle session killed by the server", function()
    local db = pgConnect(CONNINFO, { applicationName = "pgtest_kill" })
    eq(scalar(db, "SELECT 1 AS x"), 1, "before")
    q(DB, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'pgtest_kill'")
    wait(200)
    local rows, err = q(db, "SELECT 2 AS x")
    check(rows, "query after kill failed: " .. tostring(err))
    eq(rows[1].x, 2, "after")
    eq(pgStats(db).reconnects, 1, "reconnects")
    pgClose(db)
end)

test("reconnect: session killed during a query", function()
    local db = pgConnect(CONNINFO, { applicationName = "pgtest_kill2" })
    local res
    pgQuery(db, function(...) res = pack(...) end, "SELECT pg_sleep(5)")
    wait(300)
    q(DB, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'pgtest_kill2'")
    waitUntil(function() return res end, 3000, "failed callback")
    eq(res[1], false, "query must fail")
    check(res[3] == "57P01" or res[3] == "08006", "sqlstate " .. tostring(res[3]) .. " / " .. tostring(res[2]))
    eq(scalar(db, "SELECT 3 AS x"), 3, "next query reconnects")
    pgClose(db)
end)

test("pool keeps serving when one of its sessions is killed", function()
    local db = pgConnect(CONNINFO, { poolSize = 4, applicationName = "pgtest_pool_kill" })
    waitUntil(function() return pgStats(db).connected == 4 end, 3000, "4 connections")
    q(DB, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'pgtest_pool_kill' LIMIT 1")
    wait(200)
    local ok, bad = 0, 0
    for i = 1, 200 do
        pgQuery(db, function(rows, err) if rows then ok = ok + 1 else bad = bad + 1; print("pool-kill failure: " .. tostring(err)) end end, "SELECT $1::int AS v", i)
    end
    waitUntil(function() return ok + bad == 200 end, 10000, "all queries")
    eq(bad, 0, "failed queries")
    pgClose(db)
end)

test("pgClose: pending callbacks still fire, later calls fail", function()
    local db = pgConnect(CONNINFO)
    local fired = 0
    for _ = 1, 10 do
        pgQuery(db, function(rows) if rows then fired = fired + 1 end end, "SELECT pg_sleep(0.02)")
    end
    eq(pgClose(db), true, "close")
    waitUntil(function() return fired == 10 end, 3000, "pending callbacks")
    local ok, err = pgQuery(db, function() end, "SELECT 1")
    eq(ok, false, "closed"); check(err:find("closed", 1, true), err)
    eq(pgClose(db), false, "second close")
    check(tostring(db):find("closed", 1, true), tostring(db))
    check(not pgStats(db), "stats on closed connection")
end)

test("garbage-collected connections are closed", function()
    local function open() check(pgConnect(CONNINFO, { applicationName = "pgtest_gc" }), "connect") end
    open()
    eq(backendCount("pgtest_gc"), 1, "connected")
    collectgarbage()
    collectgarbage()
    waitUntil(function() return backendCount("pgtest_gc") == 0 end, 5000, "GC to close the connection")
end)

test("TLS: sslmode=require and verify-full against a custom CA", function()
    local db, err = pgConnect(CONNINFO .. " sslmode=require")
    check(db, "require: " .. tostring(err))
    eq(scalar(db, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"), true, "encrypted")
    pgClose(db)
    db, err = pgConnect(CONNINFO .. " sslmode=verify-full sslrootcert=/certs/ca.crt")
    check(db, "verify-full: " .. tostring(err))
    eq(scalar(db, "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()"):sub(1, 4), "TLSv", "protocol")
    pgClose(db)
    db, err = pgConnect(CONNINFO .. " sslmode=verify-full sslrootcert=/certs/server.crt")
    check(not db, "a certificate that does not chain to sslrootcert must be rejected")
    check(err:find("certificate", 1, true), err)
end)

test("helpers", function()
    eq(pgQuoteIdent('my"table'), '"my""table"', "pgQuoteIdent")
    eq(pgBytea("\0\255"), "\\x00ff", "pgBytea")
    check(type(PG_NULL) == "userdata", "PG_NULL")
    local s = DB:stats()
    for _, k in ipairs({ "poolSize", "connected", "queued", "inFlight", "outstanding", "submitted", "succeeded", "failed", "reconnects", "roundTrips", "avgLatencyMs" }) do
        check(type(s[k]) == "number", "stats." .. k)
    end
end)

test("large result set", function()
    local t0 = getTickCount()
    local rows, err = q(DB, "SELECT g AS id, md5(g::text) AS h FROM generate_series(1, 100000) g")
    check(rows, err)
    eq(#rows, 100000, "rows"); eq(rows[100000].id, 100000, "last id")
    print(string.format("PGTEST INFO 100k-row result in %d ms", getTickCount() - t0))
end)

test("throughput: 20000 callback queries", function()
    local n, got, bad = 20000, 0, 0
    local t0 = getTickCount()
    for i = 1, n do
        pgQuery(DB, function(rows) got = got + 1; if not rows or rows[1].v ~= i then bad = bad + 1 end end, "SELECT $1::int AS v", i)
    end
    local submitMs = getTickCount() - t0
    waitUntil(function() return got == n end, 20000, "all callbacks")
    eq(bad, 0, "wrong results")
    local ms = math.max(getTickCount() - t0, 1)
    print(string.format("PGTEST INFO %d queries in %d ms (%.0f/s), submit loop %d ms", n, ms, n * 1000 / ms, submitMs))
end, 30000)

test("resource stop with queries in flight drains and keeps onResourceStop writes", function()
    local child = getResourceFromName("pgtest_child")
    check(child, "pgtest_child resource")
    check(startResource(child), "start child")
    wait(150)
    check(stopResource(child), "stop child")
    waitUntil(function() return scalar(DB, "SELECT count(*)::int AS n FROM child_marker") == 1 end, 10000, "onResourceStop write")
    waitUntil(function() return backendCount("pgtest_child") == 0 end, 10000, "child connections to close")
end, 30000)

test("resource restart cycles with work in flight", function()
    local child = getResourceFromName("pgtest_child")
    for _ = 1, 10 do
        startResource(child)
        wait(60)
        stopResource(child)
        wait(60)
    end
    waitUntil(function() return scalar(DB, "SELECT count(*)::int AS n FROM child_marker") == 11 end, 20000, "all onResourceStop writes")
    waitUntil(function() return backendCount("pgtest_child") == 0 end, 20000, "child connections to close")
end, 60000)

test("ACL can deny module functions", function()
    local res = getResourceFromName("pgtest_acl")
    startResource(res)
    waitUntil(function() return findDebug("ACLRESULT", nil) end, 3000, "acl resource output")
    local entry = findDebug("ACLRESULT", nil)
    check(entry.msg:find("ACLRESULT nil", 1, true) or entry.msg:find("ACLRESULT false", 1, true), entry.msg)
    stopResource(res)
end)

addEventHandler("onResourceStart", resourceRoot, function()
    setTimer(runNext, 200, 1)
end)
