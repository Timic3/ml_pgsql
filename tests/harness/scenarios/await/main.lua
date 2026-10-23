-- Scenario 2: coroutine await semantics, including the yield-across-C-boundary leak case.
local db

local function liveRefs()
    collectgarbage("collect")
    collectgarbage("collect")
    local live = harness.registryCount()
    return live
end

T.run({
    { "connect", function()
        db = assert(pgConnect(CONNINFO, { applicationName = "await-main" }))
    end },

    { "basic await: results, errors, transactions, methods", function()
        local r = pack(pgQueryAwait(db, "SELECT $1::int * 2 AS x", 21))
        T.eq({ r.n, r[1], r[2], r[3] }, { 3, { { x = 42 } }, nil, 1 }, "rows, nil, affected")
        local e = pack(pgQueryAwait(db, "SELECT 1/0"))
        T.eq({ e.n, e[1], e[3] }, { 3, false, "22012" }, "error shape")
        T.match(e[2], "division by zero", "error message")
        T.eq(db:queryAwait("SELECT 'm' AS v"), { { v = "m" } }, "method form")
        local t = pack(pgTransactionAwait(db, { "SELECT 1 AS a", "SELECT 1/0" }))
        T.eq({ t.n, t[1], t[3], t[4] }, { 4, false, "22012", 2 }, "transaction await failure")
        -- chained awaits inside one coroutine
        local sum = 0
        for i = 1, 200 do sum = sum + pgQueryAwait(db, "SELECT $1::int AS i", i)[1].i end
        T.eq(sum, 200 * 201 / 2, "200 chained awaits")
    end },

    { "many concurrent coroutines get their own results", function()
        local N, done, wrong = 2000, 0, 0
        for i = 1, N do
            coroutine.wrap(function()
                local rows = pgQueryAwait(db, "SELECT $1::int AS i, pg_backend_pid() AS pid", i)
                if not rows or rows[1].i ~= i then wrong = wrong + 1 end
                done = done + 1
            end)()
        end
        T.waitFor(function() return done == N end, 30000 * SLOW, "all coroutines resumed")
        T.eq(wrong, 0, "each coroutine got its own result")
    end },

    { "await from the main state raises", function()
        local ok, err
        T.wait(function(wake)
            setTimer(function() -- timers run on the main state
                ok, err = pcall(pgQueryAwait, db, "SELECT 1")
                local ok2, err2 = pcall(pgTransactionAwait, db, { "SELECT 1" })
                T.eq(ok2, false, "pgTransactionAwait from main state")
                T.match(err2, "must be called from inside a coroutine", "tx message")
                wake()
            end, 0, 1)
        end)
        T.eq(ok, false, "pgQueryAwait from main state")
        T.match(err, "must be called from inside a coroutine", "message")
    end },

    { "errors inside a coroutine resumed by the module are reported", function()
        coroutine.wrap(function()
            pgQueryAwait(db, "SELECT 1")
            error("exploded after resume")
        end)()
        coroutine.wrap(function()
            pgQueryAwait(db, "SELECT 1")
            error({ "table error" })
        end)()
        T.eq(pgQueryAwait(db, "SELECT 2 AS x"), { { x = 2 } }, "later await still fine")
        T.sleep(20)
        T.expectDebug("error in coroutine resumed by pgsql: .*exploded after resume", 1, 1)
        T.expectDebug("error in coroutine resumed by pgsql: %(error object is not a string%)", 1, 1)
    end },

    { "a coroutine that finished or yielded elsewhere is not resumed", function()
        local co = coroutine.create(function()
            local r = pgQueryAwait(db, "SELECT pg_sleep(0.05), 1 AS x")
            return "first resume got " .. type(r)
        end)
        coroutine.resume(co)                   -- now waiting for the query
        local ok, msg = coroutine.resume(co, "manual") -- script misuse: resume it ourselves
        T.eq({ ok, coroutine.status(co) }, { true, "dead" }, "manually resumed coroutine finished")
        T.sleep(150 * SLOW)                    -- the result arrives for a dead coroutine
        T.eq(pgQueryAwait(db, "SELECT 3 AS x"), { { x = 3 } }, "module still healthy")
    end },

    { "yield across pcall: raises inside pcall, nothing submitted, nothing leaks (10k)", function()
        local before = pgStats(db).submitted
        local refs0 = liveRefs()
        local mem0 = collectgarbage("count")
        local rss0 = harness.rssKB()
        local errs, okCount = 0, 0
        local N = math.max(1000, math.floor(10000 * math.min(SCALE * 2, 1)))
        local lastErr
        for i = 1, N do
            coroutine.wrap(function()
                local ok, e = pcall(pgQueryAwait, db, "SELECT 1")
                if ok then okCount = okCount + 1 else errs = errs + 1; lastErr = e end
            end)()
            if i % 2500 == 0 then
                local ok, e = pcall(db.queryAwait, db, "SELECT 1") -- method form, from the step coroutine itself
                T.eq(ok, false, "method form inside pcall raises")
            end
        end
        T.eq(okCount, 0, "pcall never succeeds")
        T.eq(errs, N, "every call raised inside pcall")
        T.match(lastErr, "attempt to yield across metamethod/C%-call boundary", "yield error message")
        T.sleep(100 * SLOW)
        T.eq(pgStats(db).submitted, before, "no query was submitted")
        local refs1 = liveRefs()
        local mem1 = collectgarbage("count")
        local rss1 = harness.rssKB()
        T.log(("registry live refs %d -> %d, Lua heap %.0f KB -> %.0f KB, RSS %d KB -> %d KB"):format(refs0, refs1, mem0, mem1, rss0, rss1))
        T.ok(refs1 - refs0 <= 2, "registry refs bounded (" .. refs0 .. " -> " .. refs1 .. ")")
        T.ok(mem1 - mem0 < 512, "Lua heap bounded")
        -- the staged job of the last failed attempt is reclaimed by the next real await
        T.eq(pgQueryAwait(db, "SELECT 5 AS x"), { { x = 5 } }, "await works afterwards")
        T.eq(pgStats(db).submitted, before + 1, "exactly one more query submitted")
        T.ok(liveRefs() <= refs0 + 1, "staged ref released")
    end },

    { "yield across other C boundaries", function()
        -- metamethod boundary
        local mt = { __index = function(t, k) return pgQueryAwait(db, "SELECT 1 AS x") end }
        local res
        coroutine.wrap(function() res = pack(pcall(function() return setmetatable({}, mt).foo end)) end)()
        T.eq(res and res[1], false, "await inside __index raises")
        -- table.sort comparator (C function calling Lua)
        coroutine.wrap(function() res = pack(pcall(table.sort, { 3, 1, 2 }, function(a, b) pgQueryAwait(db, "SELECT 1") return a < b end)) end)()
        T.eq(res and res[1], false, "await inside sort comparator raises")
        -- inside a pgQuery callback the callback itself is not a coroutine
        local cbErr
        T.wait(function(wake)
            pgQuery(db, function()
                cbErr = pack(pcall(pgQueryAwait, db, "SELECT 1"))
                wake()
            end, "SELECT 1")
        end)
        T.eq(cbErr[1], false, "await in a plain callback raises")
        T.match(cbErr[2], "inside a coroutine", "callback message")
        -- but a coroutine started inside a callback can await
        local inner
        T.wait(function(wake)
            pgQuery(db, function()
                coroutine.wrap(function()
                    inner = pgQueryAwait(db, "SELECT 9 AS x")
                    wake()
                end)()
            end, "SELECT 1")
        end)
        T.eq(inner, { { x = 9 } }, "await in a coroutine started by a callback")
        T.eq(pgQueryAwait(db, "SELECT 6 AS x"), { { x = 6 } }, "healthy afterwards")
        T.ok(liveRefs() <= 3, "no stray refs (" .. liveRefs() .. ")")
    end },

    { "GC finalizers running while results are pushed onto a suspended coroutine", function()
        -- Collectable userdata with __gc (here: dropped connection handles; in MTA also
        -- Vector3/Matrix objects) get finalized by whichever thread allocates during a GC
        -- step. DeliverAwait allocates the result tables on the suspended coroutine.
        collectgarbage("setpause", 50)
        collectgarbage("setstepmul", 1000)
        local N, good, bad = 30, 0, 0
        for i = 1, N do
            coroutine.wrap(function()
                local rows = pgQueryAwait(db, "SELECT g, 'row' || g AS s FROM generate_series(1, 40) g")
                if type(rows) == "table" and #rows == 40 and rows[40].s == "row40" then good = good + 1 else bad = bad + 1 end
            end)()
            for k = 1, 3 do
                local garbage = pgConnect(CONNINFO, { lazy = true, applicationName = "await-garbage" })
                garbage = nil
            end
        end
        T.waitFor(function() return good + bad == N end, 10000 * SLOW, "all awaits resumed")
        collectgarbage("setpause", 200)
        collectgarbage("setstepmul", 200)
        T.eq({ good, bad }, { N, 0 }, "every coroutine got intact results")
        collectgarbage("collect")
        T.waitBackends("await-garbage", 0, 5000 * SLOW, "garbage connections closed")
    end },

    { "nested coroutines and awaits on a closed / full connection", function()
        -- inner coroutine awaits; the outer one keeps running meanwhile
        local log = {}
        local inner = coroutine.create(function()
            log[#log + 1] = "inner-start"
            local r = pgQueryAwait(db, "SELECT 1 AS x")
            log[#log + 1] = "inner-got-" .. r[1].x
        end)
        coroutine.resume(inner)
        log[#log + 1] = "outer-continues"
        T.waitFor(function() return coroutine.status(inner) == "dead" end, 5000 * SLOW, "inner finished")
        T.eq(log, { "inner-start", "outer-continues", "inner-got-1" }, "ordering")

        local c = assert(pgConnect(CONNINFO, { applicationName = "await-full", maxQueue = 2 }))
        local results = {}
        pgQuery(c, function() end, "SELECT pg_sleep(1.5)")
        T.waitActive("await-full")
        local st0 = pgStats(c)
        local free = 2 - (st0.outstanding or st0.queued)
        for i = 1, 5 do
            coroutine.wrap(function() results[i] = pack(pgQueryAwait(c, "SELECT $1::int AS i", i)) end)()
        end
        T.waitFor(function() for i = 1, 5 do if not results[i] then return false end end return true end, 5000 * SLOW, "all awaits answered")
        local full = 0
        for i = 1, 5 do
            local r = results[i]
            if r[1] then T.eq(r[1], { { i = i } }, "accepted await " .. i)
            else
                full = full + 1
                T.eq(r[3], "55000", "queue-full await sqlstate")
                T.match(r[2], "queue is full", "queue-full await message")
            end
        end
        T.eq(full, 5 - free, "awaits beyond maxQueue are resumed with an error")
        pgClose(c)
        T.eq(pack(pgQueryAwait(c, "SELECT 1")), { n = 2, false, "connection is closed" }, "await on closed connection")
        -- close while awaits are queued: they still complete (drain)
        local c2 = assert(pgConnect(CONNINFO, { applicationName = "await-close" }))
        local got = 0
        for i = 1, 50 do coroutine.wrap(function() if pgQueryAwait(c2, "SELECT pg_sleep(0.001)") then got = got + 1 end end)() end
        pgClose(c2)
        T.waitFor(function() return got == 50 end, 5000 * SLOW, "awaits queued before close complete")
    end },
})
