-- A resource that is stopped while it has lots of work in flight.
-- ARGS: app, table, n, poolSize
local app, tbl = ARGS.app, ARGS.table
local db = assert(pgConnect(CONNINFO, { applicationName = app, poolSize = ARGS.poolSize or 1 }))
local function count(what) harness.counter(app .. ":" .. what, 1) end

for i = 1, ARGS.n do
    pgQuery(db, function(rows) count("cb") end, "SELECT pg_sleep(0.001), $1::int AS i", i)
end
for i = 1, 100 do
    coroutine.wrap(function()
        pgQueryAwait(db, "SELECT pg_sleep(0.002)")
        count("await")
    end)()
end
for i = 1, 100 do
    pgTransaction(db, { "SELECT 1", { "SELECT $1::int", i } }, function() count("tx") end)
end
for i = 1, 100 do pgExec(db, "SELECT pg_sleep(0.001), 1/0") end -- failures would be reported to the VM

function onStop()
    -- onResourceStop saves: must reach the database although the VM dies right after
    for i = 1, 50 do pgExec(db, "INSERT INTO " .. tbl .. " (src, n) VALUES ($1, $2)", app, i) end
    pgQuery(db, function() count("stopcb") end, "INSERT INTO " .. tbl .. " (src, n) VALUES ($1, 999)", app)
    pgTransaction(db, { { "INSERT INTO " .. tbl .. " (src, n) VALUES ($1, 1000)", app } }, function() count("stopcb") end)
    coroutine.wrap(function() pgQueryAwait(db, "INSERT INTO " .. tbl .. " (src, n) VALUES ($1, 1001)", app); count("stopcb") end)()
    count("onstop")
end
count("started")
