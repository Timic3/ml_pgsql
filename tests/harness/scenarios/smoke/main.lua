-- Minimal end-to-end check of the harness itself.
local db

T.run({
    { "connect", function()
        T.log("module", pgVersion())
        db = pgConnect(CONNINFO, { applicationName = "smoke" })
        T.ok(db, "connected")
    end },
    { "callback", function()
        local rows, err, n = T.query(db, "SELECT $1::int + 1 AS x", 41)
        T.eq(rows, { { x = 42 } }, "callback rows")
        T.eq(n, 1, "affected")
    end },
    { "await", function()
        local rows, err = pgQueryAwait(db, "SELECT 'a' AS v")
        T.eq(rows, { { v = "a" } }, "await rows")
    end },
    { "sync", function()
        local rows = pgQuerySync(db, "SELECT true AS b")
        T.eq(rows, { { b = true } }, "sync rows")
    end },
})
