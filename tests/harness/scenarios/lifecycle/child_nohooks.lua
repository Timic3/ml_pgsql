-- Pending work in a VM that is destroyed without ResourceStopping/ResourceStopped.
-- ARGS: app, syncFirst
local app = ARGS.app
local function count(what) harness.counter(app .. ":" .. what, 1) end
db = assert(pgConnect(CONNINFO, { applicationName = app, poolSize = 2 }))
local spare = assert(pgConnect(CONNINFO, { applicationName = app }))
for i = 1, 5 do
    pgQuery(db, function() count("cb"); outputDebugString("NOHOOKS CALLBACK RAN in " .. resourceName, 1) end, "SELECT pg_sleep(0.3)")
end
for i = 1, 3 do
    coroutine.wrap(function() pgQueryAwait(db, "SELECT pg_sleep(0.3)"); count("await") end)()
end
for i = 1, 3 do pgExec(db, "SELECT pg_sleep(0.3), 1/0") end
pgQuery(spare, function() count("sparecb") end, "SELECT 1")
if ARGS.syncFirst then
    -- completions of the query above get stashed for the next pulse while this waits
    pgQuerySync(spare, "SELECT pg_sleep(0.05)")
end
setTimer(function() end, 1000000, 1, db, spare) -- registry refs held by the host
count("loaded")
