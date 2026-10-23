-- Stress worker: keeps up to ARGS.inflight random operations in flight, validates every
-- result, and periodically closes / drops / reopens its connections.
-- ARGS: id, seed, inflight, table, proxy (conninfo through the chaos proxy), counterName
local id, tbl = ARGS.id, ARGS.table
local OPS = ARGS.counterName or "stress:ops"
local ALLOWED = { ["08006"] = true, ["08001"] = true, ["57014"] = true, ["57P01"] = true, ["55000"] = true }
math.randomseed(ARGS.seed)

local conns = {}         -- { db=, proxied=, name= }
local inflight = 0
local generation = 0      -- bumped when the module was reloaded (pending work was dropped)
local stats = { ok = 0, allowedFail = 0, closed = 0, reopened = 0, dropped = 0 }

local function open(i)
    local proxied = ARGS.proxy and (i == 1)
    local name = ("stress-%s-%d"):format(id, i)
    local db, err = pgConnect(proxied and ARGS.proxy or CONNINFO, {
        applicationName = name, poolSize = math.random(1, 4), lazy = proxied, connectTimeout = 2000,
        pipeline = math.random() < 0.9, batchSize = math.random(1, 128), drainTimeout = 2000,
        int64 = ({ "auto", "number", "string" })[math.random(1, 3)],
    })
    if not db then T.fail("worker " .. id .. " cannot connect: " .. tostring(err)) return end
    conns[i] = { db = db, proxied = proxied }
end

for i = 1, 3 do open(i) end

local function done(gen)
    if gen ~= generation then return false end
    inflight = inflight - 1
    harness.counter(OPS, 1)
    return true
end

local function check(conn, what, ok, rows, err, state, expectFn)
    if rows then
        if expectFn and not expectFn(rows) then T.fail(("%s: wrong result %s"):format(what, inspect(rows))) else stats.ok = stats.ok + 1 end
    elseif ALLOWED[state] or (err and err:find("connection is closed")) then
        stats.allowedFail = stats.allowedFail + 1
    else
        T.fail(("%s failed unexpectedly: %s [%s]"):format(what, tostring(err), tostring(state)))
    end
end

local function pick()
    local list = {}
    for i = 1, 3 do if conns[i] then list[#list + 1] = conns[i] end end
    return list[math.random(1, #list)]
end

local ops = {
    { 30, function(c, gen)
        local x = math.random(1, 1e6)
        local ok, err = pgQuery(c.db, function(rows, e, st)
            if done(gen) then check(c, "query", true, rows, e, st, function(r) return r[1].v == x + 1 end) end
        end, "SELECT $1::int + 1 AS v", x)
        return ok, err
    end },
    { 10, function(c, gen)
        local ok, err = pgExec(c.db, "INSERT INTO " .. tbl .. " (w, v) VALUES ($1, $2)", id, math.random(1, 100))
        if ok then done(gen) end
        return ok, err
    end },
    { 15, function(c, gen)
        local x = math.random(1, 1e6)
        coroutine.wrap(function()
            local rows, e, st = pgQueryAwait(c.db, "SELECT $1::text || 'x' AS v", x)
            if done(gen) then check(c, "await", true, rows, e, st, function(r) return r[1].v == x .. "x" end) end
        end)()
        return true
    end },
    { 10, function(c, gen)
        local a = math.random(1, 1000)
        return pgTransaction(c.db, { { "SELECT $1::int AS a", a }, "SELECT 2 AS b", { "SELECT $1::int * 2 AS c", a } }, function(res, e, st)
            if done(gen) then check(c, "tx", true, res, e, st, function(r) return r[1][1].a == a and r[3][1].c == a * 2 end) end
        end)
    end },
    { 5, function(c, gen)
        return pgQuery(c.db, function(rows, e, st)
            if done(gen) then
                if rows then T.fail("1/0 succeeded") elseif st ~= "22012" and not ALLOWED[st] then T.fail("1/0 gave " .. tostring(st) .. " " .. tostring(e)) end
            end
        end, "SELECT 1/0")
    end },
    { 5, function(c, gen)
        local arr = {}
        for i = 1, math.random(0, 50) do arr[i] = (math.random() < 0.1) and PG_NULL or ("s" .. i .. ',"\\{}') end
        return pgQuery(c.db, function(rows, e, st)
            if done(gen) then check(c, "array", true, rows, e, st, function(r)
                local got = r[1].a
                if type(got) ~= "table" then return false end
                for i = 1, #arr do if (arr[i] == PG_NULL and got[i] ~= nil) or (arr[i] ~= PG_NULL and got[i] ~= arr[i]) then return false end end
                return true
            end) end
        end, "SELECT $1::text[] AS a", arr)
    end },
    { 5, function(c, gen)
        local bin = {}
        for i = 1, math.random(0, 300) do bin[i] = string.char(math.random(0, 255)) end
        bin = table.concat(bin)
        return pgQuery(c.db, function(rows, e, st)
            if done(gen) then check(c, "bytea", true, rows, e, st, function(r) return r[1].b == bin end) end
        end, "SELECT $1::bytea AS b", pgBytea(bin))
    end },
    { 2, function(c, gen)
        return pgQuery(c.db, function(rows, e, st)
            if done(gen) then check(c, "big", true, rows, e, st, function(r) return #r == 1000 and r[1000].g == 1000 end) end
        end, "SELECT g, md5(g::text) AS h FROM generate_series(1, 1000) g")
    end },
    { 1, function(c, gen)
        local rows, e, st = pgQuerySync(c.db, "SELECT 42 AS v")
        done(gen)
        check(c, "sync", true, rows, e, st, function(r) return r[1].v == 42 end)
        return true
    end },
    { 0.3, function(c, gen)
        -- close a connection with work in flight and open a new one
        for i = 1, 3 do if conns[i] == c then pgClose(c.db); stats.closed = stats.closed + 1; open(i); stats.reopened = stats.reopened + 1 end end
        done(gen)
        return true
    end },
    { 0.2, function(c, gen)
        -- drop a connection without closing it: the GC closes it
        for i = 1, 3 do if conns[i] == c then conns[i] = nil; stats.dropped = stats.dropped + 1; open(i) end end
        collectgarbage("step", 200)
        done(gen)
        return true
    end },
}
local totalWeight = 0
for _, o in ipairs(ops) do totalWeight = totalWeight + o[1] end

local function runOne()
    local r = math.random() * totalWeight
    for _, o in ipairs(ops) do
        r = r - o[1]
        if r <= 0 then
            local c = pick()
            local gen = generation
            inflight = inflight + 1
            local ok, err = o[2](c, gen)
            if not ok then
                inflight = inflight - 1
                if not (tostring(err):find("queue is full") or tostring(err):find("connection is closed")) then
                    T.fail("submit failed: " .. tostring(err))
                end
            end
            return
        end
    end
end

local function tick()
    local budget = 64
    while inflight < ARGS.inflight and budget > 0 do
        runOne()
        budget = budget - 1
    end
end

local reloadsSeen = select(2, harness.moduleLoaded())

-- after reloadmodule everything in flight was dropped and the old handles are dead
function onModuleReloaded()
    reloadsSeen = select(2, harness.moduleLoaded())
    generation = generation + 1
    inflight = 0
    conns = {}
    for i = 1, 3 do open(i) end
    return true
end

setTimer(function()
    if select(2, harness.moduleLoaded()) ~= reloadsSeen then onModuleReloaded() end
    local ok, err = pcall(tick)
    if not ok then T.fail("worker " .. id .. " tick: " .. tostring(err)) end
end, 0, 0)

function report()
    stats.inflight = inflight
    stats.luaKB = collectgarbage("count")
    stats.refs = harness.registryCount()
    return stats
end

function onStop()
    -- final writes from onStop must still land
    for i = 1, 3 do if conns[i] then pgExec(conns[i].db, "INSERT INTO " .. tbl .. " (w, v) VALUES ($1, -1)", id) end end
end
