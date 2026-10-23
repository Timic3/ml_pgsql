-- Scenario 3: pgQuerySync, timeouts, backpressure, ordering, pool sizes, pipelining.
local tbl = T.uniq("sync")

local function elapsed(fn, ...)
    local t0 = harness.now()
    local r = pack(fn(...))
    return harness.now() - t0, r
end

T.run({
    { "pgQuerySync basics", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "sync-basic" }))
        T.eq(pack(pgQuerySync(db, "SELECT 1 AS a")), { n = 3, { { a = 1 } }, nil, 1 }, "rows, nil, affected")
        local e = pack(pgQuerySync(db, "SELECT 1/0"))
        T.eq({ e.n, e[1], e[3] }, { 3, false, "22012" }, "error shape")
        T.ok(pgQuerySync(db, "CREATE TABLE " .. tbl .. " (seq int, src text, id serial)"), "create table")
        -- callbacks queued before a sync call are delivered after it returns, in order
        local order = {}
        for i = 1, 5 do pgQuery(db, function() order[#order + 1] = i end, "SELECT $1::int", i) end
        local r = pgQuerySync(db, "SELECT 'sync' AS s")
        T.eq(r, { { s = "sync" } }, "sync result")
        T.eq(#order, 0, "earlier callbacks not run inside the sync call")
        T.waitFor(function() return #order == 5 end, 3000 * SLOW, "earlier callbacks delivered")
        T.eq(order, { 1, 2, 3, 4, 5 }, "earlier callbacks in order")
        -- sync inside a callback
        local inner
        T.wait(function(wake)
            pgQuery(db, function() inner = pgQuerySync(db, "SELECT 'inner' AS s"); wake() end, "SELECT 1")
        end)
        T.eq(inner, { { s = "inner" } }, "sync inside a callback")
        pgClose(db)
    end },

    { "syncTimeout: returns false in time, late result dropped safely", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "sync-timeout", syncTimeout = 300 }))
        local ms, r = elapsed(pgQuerySync, db, "SELECT pg_sleep(1.0), 'late' AS v")
        T.eq(r[1], false, "timed out")
        T.match(r[2], "timed out after 300 ms", "timeout message")
        T.ok(ms >= 290 and ms < 300 + 400 * SLOW, ("returned after %.0f ms"):format(ms))
        -- the next sync waits for the slow query (poolSize 1, FIFO) and then succeeds
        local ms2, r2 = elapsed(pgQuerySync, db, "SELECT 'next' AS v")
        T.log(("second sync: %.0f ms -> %s"):format(ms2, inspect(r2[1])))
        if r2[1] == false then
            -- still busy with the sleeping query: also a timeout, wait it out
            T.sleep(1200 * SLOW)
            r2 = pack(pgQuerySync(db, "SELECT 'next' AS v"))
        end
        T.eq(r2[1], { { v = "next" } }, "connection fine after a sync timeout")
        T.sleep(200 * SLOW)
        local s = pgStats(db)
        T.eq({ s.queued, s.inFlight }, { 0, 0 }, "nothing stuck")
        pgClose(db)
    end },

    { "queryTimeout -> 57014", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "sync-qt", queryTimeout = 200 }))
        local ms, r = elapsed(pgQuerySync, db, "SELECT pg_sleep(2)")
        T.eq({ r[1], r[3] }, { false, "57014" }, "statement timeout")
        T.match(r[2], "statement timeout", "message")
        T.ok(ms < 1500 * SLOW, ("canceled after %.0f ms"):format(ms))
        T.eq(pgQuerySync(db, "SELECT 1 AS x"), { { x = 1 } }, "connection fine")
        T.eq(pgQuerySync(db, "SHOW statement_timeout")[1].statement_timeout, "200ms", "setting applied")
        local tr = pack(pgTransactionSync(db, { "SELECT 1", "SELECT pg_sleep(2)" }))
        T.eq({ tr[1], tr[3], tr[4] }, { false, "57014", 2 }, "timeout inside a transaction")
        pgClose(db)
    end },

    { "maxQueue overflow returns false", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "sync-mq", maxQueue = 10 }))
        T.ok(pgQuery(db, function() end, "SELECT pg_sleep(1.5)"), "slow query accepted")
        T.waitActive("sync-mq")
        local st0 = pgStats(db)
        local free = 10 - (st0.outstanding or st0.queued) -- maxQueue bounds outstanding jobs (or queued ones in older builds)
        T.log("maxQueue: stats before the burst " .. inspect(st0))
        local accepted, rejected, msg = 0, 0
        local done = 0
        for i = 1, 30 do
            local ok, err = pgQuery(db, function() done = done + 1 end, "SELECT $1::int", i)
            if ok then accepted = accepted + 1 else rejected = rejected + 1; msg = err end
        end
        T.eq(accepted, free, "exactly up to maxQueue accepted")
        T.eq(rejected, 30 - free, "rest rejected")
        T.match(msg, "query queue is full", "message")
        T.eq(pack(pgExec(db, "SELECT 1")), { n = 2, false, msg }, "pgExec rejected too")
        local s = pack(pgQuerySync(db, "SELECT 1"))
        T.eq({ s[1], s[2] }, { false, msg }, "pgQuerySync rejected immediately")
        T.waitFor(function() return done == accepted end, 5000 * SLOW, "accepted ones complete")
        T.ok(pgQuery(db, function() end, "SELECT 1"), "accepting again after drain")
        pgClose(db)
    end },

    { "poolSize 1: strict submission order across every API", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "sync-order" }))
        local N = math.floor(3000 * math.max(SCALE, 0.2))
        local got, seq = {}, 0
        local pending = 0
        local function note(i) got[#got + 1] = i; pending = pending - 1 end
        for i = 1, N do
            local kind = i % 6
            pending = pending + 1
            if kind == 0 then
                pgQuery(db, function() note(i) end, "INSERT INTO " .. tbl .. " (seq, src) VALUES ($1, 'cb')", i)
            elseif kind == 1 then
                pgExec(db, "INSERT INTO " .. tbl .. " (seq, src) VALUES ($1, 'exec')", i)
                pending = pending - 1 -- no callback; its row order is checked below
            elseif kind == 2 then
                coroutine.wrap(function()
                    pgQueryAwait(db, "INSERT INTO " .. tbl .. " (seq, src) VALUES ($1, 'await')", i)
                    note(i)
                end)()
            elseif kind == 3 then
                pgTransaction(db, { { "INSERT INTO " .. tbl .. " (seq, src) VALUES ($1, 'tx')", i } }, function() note(i) end)
            elseif kind == 4 then
                -- parameterless multi-statement: simple query protocol between pipelined batches
                pgQuery(db, function() note(i) end, "INSERT INTO " .. tbl .. " (seq, src) VALUES (" .. i .. ", 'multi'); SELECT 1")
            else
                if i % 300 == 5 then
                    pgQuerySync(db, "INSERT INTO " .. tbl .. " (seq, src) VALUES ($1, 'sync')", i)
                    pending = pending - 1
                else
                    pgQuery(db, function() note(i) end, "INSERT INTO " .. tbl .. " (seq, src) VALUES ($1, 'cb2')", i)
                end
            end
        end
        T.waitFor(function() return pending == 0 end, 60000 * SLOW, "all callbacks")
        -- callbacks arrive in submission order
        local sorted = true
        for k = 2, #got do if got[k] < got[k - 1] then sorted = false; T.log("out of order at " .. k .. ": " .. got[k - 1] .. " then " .. got[k]) break end end
        T.ok(sorted, "callback order == submission order")
        local rows = pgQuerySync(db, "SELECT seq FROM " .. tbl .. " ORDER BY id")
        T.eq(#rows, N, "every row inserted")
        local inOrder = true
        for k = 1, #rows do if rows[k].seq ~= k then inOrder = false; T.log("row " .. k .. " has seq " .. rows[k].seq) break end end
        T.ok(inOrder, "rows inserted in submission order")
        local s = pgStats(db)
        T.log("poolSize 1 stats: " .. inspect(s))
        T.ok(s.roundTrips < s.submitted, "pipelining batched round trips")
        pgClose(db)
    end },

    { "poolSize 4 and pipeline=false", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "sync-pool4", poolSize = 4 }))
        T.eq(pgStats(db).poolSize, 4, "poolSize")
        T.waitFor(function() return pgStats(db).connected == 4 end, 5000 * SLOW, "4 connections")
        T.eq(T.backends("sync-pool4"), 4, "4 backends")
        local N, ok, bad = math.floor(4000 * math.max(SCALE, 0.2)), 0, 0
        local pids = {}
        for i = 1, N do
            pgQuery(db, function(rows)
                if rows and rows[1].i == i then ok = ok + 1; pids[rows[1].pid] = true else bad = bad + 1 end
            end, "SELECT $1::int AS i, pg_backend_pid() AS pid", i)
        end
        T.waitFor(function() return ok + bad == N end, 60000 * SLOW, "pool4 results")
        T.eq(bad, 0, "pool4 results correct")
        local npids = 0
        for _ in pairs(pids) do npids = npids + 1 end
        T.ok(npids >= 2, "work spread over " .. npids .. " connections")
        -- parallelism: 4 x pg_sleep(0.3) take ~0.3 s, not 1.2 s
        local done = 0
        local t0 = harness.now()
        for i = 1, 4 do pgQuery(db, function() done = done + 1 end, "SELECT pg_sleep(0.3)") end
        T.waitFor(function() return done == 4 end, 5000 * SLOW, "parallel sleeps")
        local par = harness.now() - t0
        T.ok(par < 1000 * SLOW, ("4 sleeps in parallel took %.0f ms"):format(par))
        pgClose(db)
        T.waitBackends("sync-pool4", 0, 3000 * SLOW, "pool4 closed")

        local np = assert(pgConnect(CONNINFO, { applicationName = "sync-nopipe", pipeline = false }))
        local M, okc = 200, 0
        for i = 1, M do pgQuery(np, function(rows) if rows and rows[1].i == i then okc = okc + 1 end end, "SELECT $1::int AS i", i) end
        T.waitFor(function() return okc == M end, 20000 * SLOW, "no-pipeline results")
        local s = pgStats(np)
        T.eq(s.roundTrips, s.submitted, "pipeline=false: one round trip per query")
        pgClose(np)

        local bp = assert(pgConnect(CONNINFO, { applicationName = "sync-batch", batchSize = 1000 }))
        local okb = 0
        for i = 1, 3000 do pgQuery(bp, function(rows) if rows then okb = okb + 1 end end, "SELECT $1::int AS i", i) end
        T.waitFor(function() return okb == 3000 end, 30000 * SLOW, "batchSize=1000 results")
        T.log("batchSize=1000 stats: " .. inspect(pgStats(bp)))
        pgClose(bp)
    end },

    { "cleanup", function()
        pgQuerySync(T.admin(), "DROP TABLE " .. tbl)
    end },
})
