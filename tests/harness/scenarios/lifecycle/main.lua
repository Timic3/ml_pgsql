-- Scenario 5: lifecycle. pgClose with pending work, resource stop with pending work, GC of
-- connections, module unload/reload with live VMs, ShutdownModule with long queries, VMs
-- destroyed without module hooks (failed resource start), address reuse.
local tbl = T.uniq("life")
local PROXY_PORT = 15433
local PROXY = ("host=127.0.0.1 port=%d user=mta password=mta dbname=mta sslmode=disable"):format(PROXY_PORT)
local c = harness.counter

local function counter(name) return c(name, 0) end

local function rowsFor(src)
    local r = pgQuerySync(T.admin(), "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE src = $1", src)
    return r and r[1].n or -1
end

local function waitFrames(n)
    local f = harness.frame()
    T.waitFor(function() return harness.frame() >= f + n end, 5000 * SLOW, "frames")
end

-- runs a queued host command (stop/unload/load/...) and waits until it has been processed
local function afterCommand(fn, ...)
    fn(...)
    waitFrames(2)
end

local function resetAdmin()
    T._admin = nil -- the old handle belongs to the previous module instance
end

T.run({
    { "setup", function()
        T.ok(pgQuerySync(T.admin(), "CREATE TABLE " .. tbl .. " (id serial, src text, n int)"), "table")
        T.ok(harness.proxyStart(PROXY_PORT, PGHOST, PGPORT), "proxy")
    end },

    { "pgClose with pending queries: every callback still fires", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "lc-close" }))
        local okc, failc, awaits, txs = 0, 0, 0, 0
        for i = 1, 500 do pgQuery(db, function(rows) if rows and rows[1].i == i then okc = okc + 1 else failc = failc + 1 end end, "SELECT $1::int AS i", i) end
        for i = 1, 50 do coroutine.wrap(function() if pgQueryAwait(db, "SELECT 1") then awaits = awaits + 1 end end)() end
        for i = 1, 50 do pgTransaction(db, { "SELECT 1" }, function(r) if r then txs = txs + 1 end end) end
        T.eq(pgClose(db), true, "pgClose returns true")
        T.eq(pack(pgQuery(db, print, "SELECT 1")), { n = 2, false, "connection is closed" }, "new queries refused")
        T.waitFor(function() return okc + failc == 500 and awaits == 50 and txs == 50 end, 20000 * SLOW, "all pending callbacks")
        T.eq({ okc, failc, awaits, txs }, { 500, 0, 50, 50 }, "pending work completed successfully")
        T.waitBackends("lc-close", 0, 3000 * SLOW, "pool closed after drain")

        -- pgClose from inside one of its own callbacks
        local db2 = assert(pgConnect(CONNINFO, { applicationName = "lc-close-cb" }))
        local n2 = 0
        for i = 1, 100 do
            pgQuery(db2, function(rows) n2 = n2 + 1; if i == 10 then pgClose(db2) end end, "SELECT 1")
        end
        T.waitFor(function() return n2 == 100 end, 10000 * SLOW, "callbacks after close-in-callback")
        T.waitBackends("lc-close-cb", 0, 3000 * SLOW, "closed")
    end },

    { "unreferenced connections are garbage-collected and closed", function()
        local fired = 0
        do
            local db = assert(pgConnect(CONNINFO, { applicationName = "lc-gc", poolSize = 3 }))
            pgQuery(db, function(rows) if rows then fired = fired + 1 end end, "SELECT pg_sleep(0.2)")
        end
        do
            local idle = assert(pgConnect(CONNINFO, { applicationName = "lc-gc-idle" }))
        end
        T.eq(T.backends("lc-gc"), 3, "3 connections while referenced")
        collectgarbage("collect")
        collectgarbage("collect")
        T.waitFor(function() return fired == 1 end, 3000 * SLOW, "callback of a collected connection still fires")
        T.waitBackends("lc-gc", 0, 3000 * SLOW, "collected pool closed")
        T.waitBackends("lc-gc-idle", 0, 3000 * SLOW, "collected idle pool closed")
    end },

    { "resource stop with lots of pending work", function()
        local n = math.floor(3000 * math.max(SCALE, 0.1))
        for round = 1, 3 do
            local app = "lc-stop-" .. round
            T.ok(harness.start("pending" .. round, "child_pending.lua", { app = app, table = tbl, n = n, poolSize = round }), "start child")
            T.eq(counter(app .. ":started"), 1, "child started")
            T.sleep((round - 1) * 30 * SLOW) -- round 1 stops immediately, later rounds after some deliveries
            local cbBefore = counter(app .. ":cb")
            afterCommand(harness.stop, "pending" .. round)
            T.eq(harness.state("pending" .. round), "loaded", "child stopped")
            T.eq(counter(app .. ":onstop"), 1, "onStop ran")
            local cbAtStop = counter(app .. ":cb")
            -- onStop saves land in the database
            T.waitFor(function() return rowsFor(app) == 53 end, 15000 * SLOW, "onStop rows for " .. app)
            T.eq(rowsFor(app), 53, "all 53 onStop rows written")
            T.waitBackends(app, 0, 15000 * SLOW, "pool of stopped resource closed")
            T.eq(counter(app .. ":cb"), cbAtStop, "no callbacks after the VM stopped")
            T.eq(counter(app .. ":stopcb"), 0, "callbacks issued in onStop never run (VM gone)")
            T.log(("round %d: %d/%d callbacks delivered before stop (%d before the stop request)"):format(round, cbAtStop, n, cbBefore))
            T.takeDebug("division by zero", 2, "pending" .. round) -- pgExec failures delivered while it was alive
        end
    end },

    { "restart the same resource repeatedly with pending work", function()
        for i = 1, 15 do
            local app = "lc-restart"
            T.ok(harness.start("restarter", "child_pending.lua", { app = app .. i, table = tbl, n = 50 }), "start " .. i)
            if i % 2 == 0 then T.sleep(5) end
            afterCommand(harness.stop, "restarter")
        end
        T.sleep(500 * SLOW)
        T.waitBackends("lc-restart%", 0, 15000 * SLOW, "all restart pools closed")
        T.takeDebug("division by zero", 2, "restarter")
        local total = pgQuerySync(T.admin(), "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE src LIKE 'lc-restart%'")
        T.eq(total and total[1].n, 15 * 53, "every onStop save landed")
    end },

    { "VM destroyed without module hooks (failed start path)", function()
        T.ok(harness.start("nh1", "child_nohooks.lua", { app = "lc-nh1" }), "start nh1")
        T.eq(counter("lc-nh1:loaded"), 1, "nh1 loaded")
        T.sleep(30)
        afterCommand(harness.destroyNoHooks, "nh1")
        T.eq(harness.state("nh1"), "loaded", "VM gone")
        T.sleep(800 * SLOW) -- results arrive for the dead VM
        T.eq({ counter("lc-nh1:cb"), counter("lc-nh1:await") }, { 0, 0 }, "no callback/await of the destroyed VM ran")
        T.waitBackends("lc-nh1", 0, 2500 * SLOW, "connections of the destroyed VM closed within ~2 s")
        T.eq(T.takeDebug(".", nil, "nh1"), 0, "nothing reported into the destroyed VM")
    end },

    { "destroyed without hooks, new VM at the SAME address right after", function()
        for _, case in ipairs({ { "nh2", "fresh2" }, { "nh3", "nh3" } }) do
            local old, new = case[1], case[2]
            local app = "lc-" .. old
            T.ok(harness.start(old, "child_nohooks.lua", { app = app }), "start " .. old)
            local addr = harness.vmAddress(old)
            T.sleep(30)
            afterCommand(harness.destroyNoHooks, old, { reuseAddress = true, thenStart = new, thenFiles = { "fresh.lua" } })
            T.eq(harness.vmAddress(new), addr, new .. " got the same lua_State address as " .. old)
            T.eq(counter(new .. ":fresh"), 1, new .. " started")
            T.sleep(800 * SLOW)
            T.eq(counter("trap"), 0, "no callback of the destroyed VM ran in the new VM (" .. new .. ")")
            T.eq(T.takeDebug("pgExec failed", nil, new), 0, "no pgExec failure of the old VM reported into " .. new)
            T.eq(T.takeDebug("TRAP", nil, new), 0, "no trap messages")
            T.waitBackends(app, 0, 2500 * SLOW, "connections of " .. old .. " closed")
            -- the new VM works normally
            T.eq(harness.call(new, "pcall", function() end), true, "new VM callable")
            afterCommand(harness.stop, new)
        end
    end },

    { "failed resource start inside a pgQuery callback (synchronous destroy during DoPulse)", function()
        local db = assert(pgConnect(CONNINFO, { applicationName = "lc-cb" }))
        local res
        T.wait(function(wake)
            pgQuery(db, function()
                res = pack(harness.start("broken1", { "child_nohooks.lua", "broken_syntax.lua" }, { app = "lc-broken1" }))
                local r2 = pack(harness.start("broken2", { "child_nohooks.lua", "broken_syntax.lua" }, { app = "lc-broken2", syncFirst = true }))
                -- a VM created right away may reuse the freed memory
                harness.start("fresh4", "fresh.lua")
                wake()
            end, "SELECT 1")
        end)
        T.eq(res[1], false, "start failed")
        T.match(res[2], "Loading script failed", "load error")
        T.eq(harness.state("broken1"), "loaded", "VM destroyed")
        T.sleep(800 * SLOW)
        T.eq(counter("lc-broken1:cb") + counter("lc-broken2:cb") + counter("lc-broken1:await") + counter("lc-broken2:await"), 0,
            "no callbacks for VMs whose start failed")
        T.eq(counter("trap"), 0, "no traps")
        T.waitBackends("lc-broken%", 0, 2500 * SLOW, "connections of failed starts closed")
        T.eq(T.takeDebug(".", nil, "broken1") + T.takeDebug(".", nil, "broken2"), 0, "nothing reported into dead VMs")
        afterCommand(harness.stop, "fresh4")
        pgClose(db)
    end },

    { "unloadmodule + loadmodule with live VMs and pending work", function()
        for _, r in ipairs({ "r1", "r2" }) do
            T.ok(harness.start(r, "child_reload.lua", { app = "lc-" .. r, table = tbl }), "start " .. r)
        end
        local mainDb = assert(pgConnect(CONNINFO, { applicationName = "lc-main-old" }))
        local threads0 = harness.threadCount()
        -- queue the work right before the unload so that it is still pending when it happens
        for _, r in ipairs({ "r1", "r2" }) do
            T.eq(select(2, harness.call(r, "startPending")), true, "pending work in " .. r)
        end
        local mainFired = 0
        pgQuery(mainDb, function() mainFired = mainFired + 1 end, "SELECT pg_sleep(0.5)")

        afterCommand(harness.unloadModule)
        resetAdmin()
        T.eq(harness.moduleLoaded(), false, "module unloaded")
        T.log(("ShutdownModule with pending work took %.0f ms"):format(harness.lastShutdownMs()))
        T.ok(harness.lastShutdownMs() < 6000 + 1000 * SLOW, "bounded by drainTimeout")
        T.eq(pgConnect, nil, "globals removed in this VM too")
        T.raises("attempt to index", function() return mainDb:query(print, "SELECT 1") end)
        T.ok(harness.threadCount() <= threads0 - 4, "worker threads exited (" .. threads0 .. " -> " .. harness.threadCount() .. ")")

        for _, r in ipairs({ "r1", "r2" }) do
            local ok, out = harness.call(r, "whileUnloaded")
            T.ok(ok, "whileUnloaded ran in " .. r .. ": " .. tostring(out))
            if ok then
                T.eq(out.globalsGone, true, "globals gone in " .. r)
                T.eq(out.method.ok, false, "method on old handle raises in " .. r)
                T.match(out.method.err, "attempt to index", "method error in " .. r)
                T.log("cached pgQuerySync while unloaded: " .. inspect(out.cached))
                T.eq(out.cached.ok, false, "a cached function reference raises while the module is unloaded")
            end
        end
        -- a resource started while the module is not loaded
        T.ok(harness.start("late", "child_late.lua", { app = "lc-late" }), "start late")

        afterCommand(harness.loadModule)
        T.eq(harness.moduleLoaded(), true, "module loaded again")
        T.eq(type(pgConnect), "function", "functions registered again in the controller")
        T.eq(select(2, harness.call("late", "check")), "late", "late-started resource got the functions")
        for _, r in ipairs({ "r1", "r2" }) do
            local ok, out = harness.call(r, "afterReload")
            T.ok(ok, "afterReload ran in " .. r .. ": " .. tostring(out))
            if ok then
                T.eq(out.globalsBack, true, "globals back in " .. r)
                T.eq(out.oldHandleFn.ok, false, "old handle rejected by pgQuery")
                T.match(out.oldHandleFn.err, "ml_pgsql.connection expected", "old handle error")
                T.eq({ out.oldHandleMethod.ok, out.oldHandleSync.ok, out.oldHandleClose.ok, out.oldHandleStats.ok }, { false, false, false, false },
                    "every use of an old handle raises")
                T.log("old PG_NULL after reload (accepted only if the module was mapped at the same address): " .. inspect(out.oldNullParam))
                T.eq({ out.newConnect, out.newQuery }, { true, 7 }, "new connection works")
                T.eq(out.cachedOld.ok, false, "cached function + old handle raises")
                T.eq(out.cachedNew and out.cachedNew.ok, true, "cached function works again with a new handle")
            end
        end
        harness.gcAll()
        T.raises("ml_pgsql.connection expected", pgQuerySync, mainDb, "SELECT 1")
        mainDb = nil
        collectgarbage("collect")
        T.sleep(500 * SLOW)
        T.eq(counter("lc-r1:cb") + counter("lc-r2:cb") + counter("lc-r1:await") + counter("lc-r2:await") + mainFired, 0,
            "callbacks pending at unload were dropped, not run")
        T.eq(rowsFor("lc-r1") + rowsFor("lc-r2"), 10, "pgExec writes queued before the unload were drained")
        T.waitBackends("lc-r_", 0, 3000 * SLOW, "old pools closed")
        for _, r in ipairs({ "r1", "r2", "late" }) do afterCommand(harness.stop, r) end
        T.waitBackends("lc-r%", 0, 3000 * SLOW, "new pools closed with their resources")
    end },

    { "reloadmodule in one step, repeated, with pending work", function()
        for i = 1, 3 do
            T.ok(harness.start("rr", "child_reload.lua", { app = "lc-rr" .. i, table = tbl }), "start rr")
            harness.call("rr", "startPending")
            afterCommand(harness.reloadModule)
            resetAdmin()
            local ok, out = harness.call("rr", "afterReload")
            T.ok(ok and out.newQuery == 7 and out.oldHandleFn.ok == false, "rr after reload " .. i .. ": " .. inspect(out))
            afterCommand(harness.stop, "rr")
        end
        T.waitBackends("lc-rr%", 0, 3000 * SLOW, "closed")
    end },

    { "ShutdownModule with a long-running query: drainTimeout, then cancel", function()
        T.ok(harness.start("long1", "child_longquery.lua", { app = "lc-long1", drainTimeout = 1000 }), "start long1")
        T.sleep(200 * SLOW)
        T.eq(T.backends("lc-long1"), 1, "long query running")
        afterCommand(harness.unloadModule)
        resetAdmin()
        local ms = harness.lastShutdownMs()
        T.log(("ShutdownModule with pg_sleep(30), drainTimeout=1000: %.0f ms"):format(ms))
        T.ok(ms >= 900 and ms < 1000 + 2000 * SLOW, "drainTimeout honoured, then canceled")
        afterCommand(harness.loadModule)
        resetAdmin()
        T.waitBackends("lc-long1", 0, 3000 * SLOW, "backend released (query canceled)")
        T.eq(counter("lc-long1:cb"), 0, "callback dropped")
        afterCommand(harness.stop, "long1")

        -- same against a hung server (cancel request cannot get through)
        harness.proxyMode("up")
        T.ok(harness.start("long2", "child_longquery.lua", { app = "lc-long2", drainTimeout = 1000, conninfo = PROXY }), "start long2")
        T.sleep(200 * SLOW)
        harness.proxyMode("blackhole")
        afterCommand(harness.unloadModule)
        resetAdmin()
        ms = harness.lastShutdownMs()
        T.log(("ShutdownModule against a hung server, drainTimeout=1000: %.0f ms"):format(ms))
        -- worst case: drainTimeout + cancel attempt (1 s) + abort grace (1 s)
        T.ok(ms >= 900 and ms < 1000 + 2500 * SLOW, "bounded even when the cancel request hangs")
        harness.proxyMode("up")
        harness.proxyKill()
        afterCommand(harness.loadModule)
        resetAdmin()
        afterCommand(harness.stop, "long2")
        -- the cancel request never reached the server: end the orphaned pg_sleep(30) ourselves
        pgQuerySync(T.admin(), "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'lc-long2'")
        T.waitBackends("lc-long%", 0, 5000 * SLOW, "long backends gone")
    end },

    { "server shutdown with a long-running query in a running resource", function()
        -- checked by the host when the scenario ends: stop resources, then ShutdownModule
        T.ok(harness.start("long3", "child_longquery.lua", { app = "lc-long3", drainTimeout = 1500 }), "start long3")
        T.sleep(200 * SLOW)
        harness.expectShutdownWithinMs(1500 + 2000 * SLOW)
        T.eq(pgQuerySync(T.admin(), "DROP TABLE " .. tbl) ~= false, true, "drop table")
    end },
})
