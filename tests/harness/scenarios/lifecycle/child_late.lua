-- Started while the module is unloaded; gets the functions when the module is loaded late.
function check()
    if not pgConnect then return "no functions" end
    local db = pgConnect(CONNINFO, { applicationName = ARGS.app })
    if not db then return "connect failed" end
    local r = pgQuerySync(db, "SELECT 'late' AS v")
    pgClose(db)
    return r and r[1].v
end
hadFunctionsAtStart = pgConnect ~= nil
