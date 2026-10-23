-- Started and stopped by pgtest while it has queries in flight.
local db

addEventHandler("onResourceStart", resourceRoot, function()
    db = pgConnect("host=postgres user=mta password=mta dbname=mta", { applicationName = "pgtest_child", poolSize = 2 })
    for i = 1, 10 do
        pgQuery(db, function() end, "SELECT pg_sleep(0.1)")
    end
    coroutine.wrap(function()
        pgQueryAwait(db, "SELECT pg_sleep(0.3)")
    end)()
end)

addEventHandler("onResourceStop", resourceRoot, function()
    -- must still land in the database although the VM is about to be destroyed
    pgExec(db, "INSERT INTO child_marker(note) VALUES ($1)", "stopped")
end)
