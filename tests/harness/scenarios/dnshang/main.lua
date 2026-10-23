-- Scenario 8 (run by run.sh in a container whose DNS server does not answer):
-- name resolution inside libpq blocks the worker thread. connectTimeout, pgClose's
-- drainTimeout and ShutdownModule must still be bounded.
local HOST = "pg-db.unresolvable-harness-test.org"
local CONN = ("host=%s port=5432 user=mta password=mta dbname=mta sslmode=disable"):format(HOST)

local function elapsed(fn, ...)
    local t0 = harness.now()
    local r = pack(fn(...))
    return harness.now() - t0, r
end

T.run({
    { "pgConnect with connectTimeout=1000 against a hanging DNS lookup", function()
        local ms, r = elapsed(pgConnect, CONN, { connectTimeout = 1000, applicationName = "dns-1" })
        T.log(("pgConnect returned after %.0f ms: %s"):format(ms, inspect({ r[1] and "handle" or r[1], r[2] })))
        T.eq(r[1], false, "fails")
        T.ok(ms < 1000 + 1500 * SLOW, ("bounded by connectTimeout (+1 s grace): %.0f ms"):format(ms))
    end },

    { "queued query on a lazy pool with a hanging DNS lookup", function()
        local db = assert(pgConnect(CONN, { lazy = true, connectTimeout = 1000, drainTimeout = 500, applicationName = "dns-2" }))
        local t0 = harness.now()
        local r = pack(T.query(db, "SELECT 1"))
        local ms = harness.now() - t0
        T.log(("query answered after %.0f ms: %s"):format(ms, inspect({ r[1], r[2], r[3] })))
        T.eq(r[3], "08001", "08001")
        T.ok(ms < 1000 + 1500 * SLOW, ("answered within connectTimeout (+grace): %.0f ms"):format(ms))
        keepDb = db
    end, timeout = 120000 },

    { "unloadmodule while a worker is stuck resolving", function()
        local db = assert(pgConnect(CONN, { lazy = true, connectTimeout = 1000, drainTimeout = 500, applicationName = "dns-3" }))
        pgQuery(db, function() end, "SELECT 1")
        T.sleep(100)
        harness.unloadModule()
        local f = harness.frame()
        T.waitFor(function() return harness.frame() >= f + 2 end, 120000, "frames")
        T._admin = nil
        local ms = harness.lastShutdownMs()
        T.log(("ShutdownModule took %.0f ms (drainTimeout 500)"):format(ms))
        T.ok(ms < 500 + 2000 * SLOW, "ShutdownModule bounded by drainTimeout + 2 s")
        harness.loadModule()
        T.waitFor(function() return harness.frame() >= f + 4 end, 120000, "frames")
    end, timeout = 300000 },
})
