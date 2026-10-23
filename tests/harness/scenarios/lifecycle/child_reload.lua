-- A resource that stays alive across unloadmodule/reloadmodule.
-- ARGS: app, table
local app, tbl = ARGS.app, ARGS.table
local function count(what) harness.counter(app .. ":" .. what, 1) end

db = assert(pgConnect(CONNINFO, { applicationName = app, drainTimeout = 6000 }))
db2 = assert(pgConnect(CONNINFO, { applicationName = app .. "-b", poolSize = 2 }))
oldNull = PG_NULL
cachedQuerySync = pgQuerySync -- scripts often cache globals in locals

function startPending()
    for i = 1, 5 do pgQuery(db, function() count("cb") end, "SELECT pg_sleep(0.5)") end
    for i = 1, 5 do coroutine.wrap(function() pgQueryAwait(db2, "SELECT pg_sleep(0.5)"); count("await") end)() end
    for i = 1, 5 do pgExec(db, "INSERT INTO " .. tbl .. " (src, n) VALUES ($1, $2)", app, i) end
    -- a staged await whose yield failed (yield across pcall) is pending in the module too
    coroutine.wrap(function() pcall(pgQueryAwait, db, "SELECT 1") end)()
    return true
end

local function capture(fn, ...)
    local r = pack(pcall(fn, ...))
    return { ok = r[1], err = (not r[1]) and tostring(r[2]) or nil }
end

-- runs while the module is unloaded
function whileUnloaded()
    local out = {}
    out.globalsGone = pgQuery == nil and pgConnect == nil and PG_NULL == nil
    out.method = capture(function() return db:query(function() end, "SELECT 1") end)
    out.tostring = tostring(db)
    out.cached = capture(cachedQuerySync, db, "SELECT 1")
    collectgarbage("collect")
    collectgarbage("collect")
    return out
end

-- runs after the module was loaded again
function afterReload()
    local out = {}
    out.globalsBack = type(pgQuery) == "function" and type(PG_NULL) == "userdata"
    out.oldHandleFn = capture(pgQuery, db, function() end, "SELECT 1")
    out.oldHandleMethod = capture(function() return db:query(function() end, "SELECT 1") end)
    out.oldHandleSync = capture(pgQuerySync, db, "SELECT 1")
    out.oldHandleClose = capture(pgClose, db)
    out.oldHandleStats = capture(pgStats, db)
    out.cachedOld = capture(cachedQuerySync, db, "SELECT 1")
    out.oldNullParam = capture(function() local c = pgConnect(CONNINFO, { applicationName = app .. "-n" }); local r = pack(pcall(pgQuerySync, c, "SELECT $1::int", oldNull)); pgClose(c); assert(r[1], r[2]) return r[2] end)
    -- old handles become garbage: their __gc must not reach unloaded code
    db, db2 = nil, nil
    collectgarbage("collect")
    collectgarbage("collect")
    local fresh = pgConnect(CONNINFO, { applicationName = app .. "-new" })
    out.newConnect = fresh and true or false
    out.newQuery = fresh and pgQuerySync(fresh, "SELECT 7 AS x")[1].x
    out.cachedNew = fresh and capture(function() return assert(cachedQuerySync(fresh, "SELECT 8 AS x"))[1].x == 8 end)
    newdb = fresh
    return out
end
count("started")
