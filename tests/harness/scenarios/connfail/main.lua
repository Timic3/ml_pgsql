-- Scenario 4: connection failures, outages, killed sessions, hung server.
-- A TCP proxy inside the host (127.0.0.1:15432 -> postgres) simulates outages:
--   refuse = server down, blackhole = server hung, proxyKill = network drop / server crash.
local PROXY_PORT = 15432
local PROXY = ("host=127.0.0.1 port=%d user=mta password=mta dbname=mta sslmode=disable"):format(PROXY_PORT)

local function elapsed(fn, ...)
    local t0 = harness.now()
    local r = pack(fn(...))
    return harness.now() - t0, r
end

local function pidOf(db)
    local r = pgQuerySync(db, "SELECT pg_backend_pid() AS pid")
    return r and r[1].pid
end

local function terminate(pid)
    local r = pgQuerySync(T.admin(), "SELECT pg_terminate_backend($1) AS ok", pid)
    return r and r[1].ok
end

T.run({
    { "proxy up", function()
        local ok, err = harness.proxyStart(PROXY_PORT, PGHOST, PGPORT)
        T.ok(ok, "proxy started: " .. tostring(err))
        local db = pgConnect(PROXY, { applicationName = "cf-proxycheck" })
        T.ok(db, "connect through proxy")
        if db then T.eq(pgQuerySync(db, "SELECT 1 AS x"), { { x = 1 } }, "query through proxy"); pgClose(db) end
    end },

    { "pgConnect fails fast: bad host / closed port / wrong password / bad database", function()
        local ms, r = elapsed(pgConnect, "host=nonexistent-host.invalid user=mta password=mta dbname=mta", { connectTimeout = 3000 })
        T.eq(r[1], false, "bad host")
        T.match(r[2], "could not connect", "bad host message")
        T.ok(ms < 4500 * SLOW, ("bad host took %.0f ms"):format(ms))

        ms, r = elapsed(pgConnect, "host=127.0.0.1 port=1 user=mta password=mta dbname=mta")
        T.eq(r[1], false, "closed port")
        T.match(r[2], "refused", "closed port message")
        T.ok(ms < 1000 * SLOW, ("closed port took %.0f ms"):format(ms))

        ms, r = elapsed(pgConnect, (CONNINFO:gsub("password=%w+", "password=wrong")), { poolSize = 4 })
        T.eq(r[1], false, "wrong password")
        T.match(r[2], "password authentication failed", "wrong password message")
        T.ok(ms < 2000 * SLOW, ("wrong password took %.0f ms"):format(ms))

        ms, r = elapsed(pgConnect, (CONNINFO:gsub("dbname=%w+", "dbname=nope_db")))
        T.eq(r[1], false, "bad database")
        T.match(r[2], "does not exist", "bad database message")

        harness.proxyMode("blackhole")
        ms, r = elapsed(pgConnect, PROXY, { connectTimeout = 500 })
        harness.proxyMode("up")
        T.eq(r[1], false, "hung server")
        T.match(r[2], "timeout", "hung server message")
        T.ok(ms >= 450 and ms < 1700 * SLOW, ("connectTimeout honoured: %.0f ms"):format(ms))
        T.sleep(100)
        T.eq(T.backends("cf-%"), 0, "no stray backends")
    end },

    { "lazy connect to a dead server fails with 08001 and recovers", function()
        harness.proxyMode("refuse")
        local db = pgConnect(PROXY, { lazy = true, connectTimeout = 1000, applicationName = "cf-lazy" })
        T.ok(db, "lazy connect returns a handle")
        local r = pack(T.query(db, "SELECT 1 AS x"))
        T.eq({ r[1], r[3] }, { false, "08001" }, "query fails with 08001")
        T.match(r[2], "could not connect", "08001 message")
        local fails = 0
        for i = 1, 5 do
            local q = pack(T.query(db, "SELECT 1 AS x"))
            if q[3] == "08001" then fails = fails + 1 end
        end
        T.eq(fails, 5, "still failing while down")
        local x = pack(pgQuerySync(db, "SELECT 1"))
        T.eq({ x[1], x[3] }, { false, "08001" }, "sync fails with 08001 too")
        T.eq(pgStats(db).connected, 0, "not connected")

        harness.proxyMode("up")
        local t0 = harness.now()
        local okRows
        while harness.now() - t0 < 8000 * SLOW do
            local q = pack(T.query(db, "SELECT 1 AS x"))
            if q[1] then okRows = q[1] break end
            T.sleep(100)
        end
        T.eq(okRows, { { x = 1 } }, "recovered after the server came back")
        T.log(("recovered after %.0f ms"):format(harness.now() - t0))
        T.eq(pgStats(db).connected, 1, "connected")
        pgClose(db)
    end },

    { "idle session terminated -> next query reconnects transparently", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "cf-idle" }))
        local pid = pidOf(db)
        T.ok(terminate(pid), "terminated backend " .. tostring(pid))
        T.sleep(200 * SLOW)
        local r = pack(T.query(db, "SELECT pg_backend_pid() AS pid"))
        T.ok(r[1], "query after terminate succeeded: " .. tostring(r[2]) .. " " .. tostring(r[3]))
        T.ok(r[1] and r[1][1].pid ~= pid, "new backend")
        T.eq(pgStats(db).reconnects, 1, "one reconnect")
        -- the same, immediately (no grace period): the FATAL message may still be in flight
        local okImmediate, failImmediate = 0, 0
        for i = 1, 5 do
            pid = pidOf(db)
            terminate(pid)
            local q = pack(T.query(db, "SELECT 1 AS x"))
            if q[1] then okImmediate = okImmediate + 1 else failImmediate = failImmediate + 1; T.log("immediate query after terminate: " .. inspect({ q[2], q[3] })) end
        end
        T.log(("query right after terminate: %d ok, %d failed"):format(okImmediate, failImmediate))
        pgClose(db)
    end },

    { "idle connection dropped by the network -> transparent reconnect", function()
        local db = assert(pgConnect(PROXY, { applicationName = "cf-drop" }))
        T.eq(pgQuerySync(db, "SELECT 1 AS x"), { { x = 1 } }, "before")
        T.ok(harness.proxyKill() >= 1, "connection killed")
        T.sleep(100 * SLOW)
        local r = pack(T.query(db, "SELECT 2 AS x"))
        T.eq({ r[1], r[2], r[3] }, { { { x = 2 } }, nil, 1 }, "after network drop")
        T.eq(pgStats(db).reconnects, 1, "reconnected once")
        pgClose(db)
    end },

    { "session terminated during a running query", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "cf-running" }))
        local pid = pidOf(db)
        local result
        pgQuery(db, function(...) result = pack(...) end, "SELECT pg_sleep(30)")
        T.waitActive("cf-running")
        T.ok(terminate(pid), "terminated")
        T.waitFor(function() return result end, 2000 * SLOW, "callback after terminate")
        T.ok(result and result[1] == false, "query failed")
        T.ok(result and (result[3] == "57P01" or result[3] == "08006"), "sqlstate " .. tostring(result and result[3]))
        T.log("running query terminated: " .. inspect(result))
        T.eq(T.query(db, "SELECT 1 AS x"), { { x = 1 } }, "next query succeeds")
        pgClose(db)
    end },

    { "network drop during a running query -> 08006, next query fine", function()
        local db = assert(pgConnect(PROXY, { applicationName = "cf-drop-running" }))
        local result
        pgQuery(db, function(...) result = pack(...) end, "SELECT pg_sleep(30)")
        T.waitActive("cf-drop-running")
        harness.proxyKill()
        T.waitFor(function() return result end, 2000 * SLOW, "callback after drop")
        T.eq({ result and result[1], result and result[3] }, { false, "08006" }, "08006")
        T.match(result and result[2], "lost during query", "message")
        T.eq(T.query(db, "SELECT 1 AS x"), { { x = 1 } }, "next query succeeds")
        pgClose(db)
        -- the server cannot know the client vanished until pg_sleep ends: clean up
        pgQuerySync(T.admin(), "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'cf-drop-running' AND state = 'active'")
    end },

    { "network drop in the middle of a pipelined burst: nothing hangs, unsent work retried", function()
        local db = assert(pgConnect(PROXY, { applicationName = "cf-burst" }))
        local N, okc, failed, states = 400, 0, 0, {}
        for i = 1, N do
            pgQuery(db, function(rows, err, state)
                if rows and rows[1].i == i then okc = okc + 1 else failed = failed + 1; states[state or "?"] = (states[state or "?"] or 0) + 1 end
            end, "SELECT $1::int AS i, pg_sleep(0.005)", i)
        end
        T.waitActive("cf-burst")
        T.sleep(100)
        harness.proxyKill()
        T.waitFor(function() return okc + failed == N end, 20000 * SLOW, "every callback fired")
        T.log(("burst: %d ok, %d failed %s"):format(okc, failed, inspect(states)))
        T.ok(failed <= 64, "only the in-flight batch failed")
        for st in pairs(states) do T.eq(st, "08006", "failure state") end
        T.eq(T.query(db, "SELECT 1 AS x"), { { x = 1 } }, "fine afterwards")
        pgClose(db)
    end },

    { "server down with queued work, then back", function()
        local db = assert(pgConnect(PROXY, { applicationName = "cf-down", connectTimeout = 1000 }))
        harness.proxyMode("refuse")
        harness.proxyKill()
        local results = {}
        for i = 1, 50 do pgQuery(db, function(rows, err, st) results[#results + 1] = st or "ok" end, "SELECT 1") end
        T.waitFor(function() return #results == 50 end, 10000 * SLOW, "all queued queries answered while down")
        local c08001 = 0
        for _, s in ipairs(results) do if s == "08001" then c08001 = c08001 + 1 end end
        T.eq(c08001, 50, "all failed with 08001")
        harness.proxyMode("up")
        local okRows
        local t0 = harness.now()
        while harness.now() - t0 < 8000 * SLOW do
            local q = T.query(db, "SELECT 1 AS x")
            if q then okRows = q break end
            T.sleep(100)
        end
        T.eq(okRows, { { x = 1 } }, "recovered")
        pgClose(db)
    end },

    { "hung server: sync timeout, close cancels after drainTimeout", function()
        local db = assert(pgConnect(PROXY, { applicationName = "cf-hung", drainTimeout = 500, syncTimeout = 300 }))
        T.eq(pgQuerySync(db, "SELECT 1 AS x"), { { x = 1 } }, "before")
        harness.proxyMode("blackhole")
        local ms, r = elapsed(pgQuerySync, db, "SELECT 2 AS x")
        T.eq(r[1], false, "sync on hung server times out")
        T.ok(ms < 300 + 300 * SLOW, ("after %.0f ms"):format(ms))
        local result
        pgQuery(db, function(...) result = pack(...) end, "SELECT 3 AS x")
        local t0 = harness.now()
        T.eq(pgClose(db), true, "close")
        T.waitFor(function() return result end, 5000 * SLOW, "callback of the hung query")
        local took = harness.now() - t0
        T.eq({ result and result[1], result and result[3] }, { false, "57014" }, "canceled at drainTimeout")
        T.log(("hung query canceled %.0f ms after pgClose: %s"):format(took, inspect(result)))
        T.ok(took >= 450 and took < 500 + 2000 * SLOW, "cancel timing")
        harness.proxyMode("up")
        harness.proxyKill()
        T.waitBackends("cf-hung", 0, 5000 * SLOW, "hung connection gone")
    end },

    { "no leftovers", function()
        T.sleep(300 * SLOW)
        T.eq(T.backends("cf-%"), 0, "no cf-* backends left")
    end },
})
