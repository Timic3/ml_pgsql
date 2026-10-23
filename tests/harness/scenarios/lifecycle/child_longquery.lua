-- One very long query (or a hung server) on a connection with a short drainTimeout.
-- ARGS: app, drainTimeout, conninfo
local db = assert(pgConnect(ARGS.conninfo or CONNINFO, { applicationName = ARGS.app, drainTimeout = ARGS.drainTimeout }))
pgQuery(db, function(...) harness.counter(ARGS.app .. ":cb", 1) end, "SELECT pg_sleep(30)")
pgExec(db, "SELECT 1")
keep = db
