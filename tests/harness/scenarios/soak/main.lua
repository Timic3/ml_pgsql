-- Scenario 7: soak. Steady mixed load with connection churn, network cuts and resource
-- restarts; RSS / threads / fds / Lua heap / registry refs are sampled and must stay flat.
local DURATION = tonumber(harness.getenv("MLPG_SOAK_SECONDS") or "120") * 1000
local SAMPLE_EVERY = 5000
local PROXY_PORT = 15435
local PROXY = ("host=127.0.0.1 port=%d user=mta password=mta dbname=mta sslmode=disable"):format(PROXY_PORT)
local tbl = T.uniq("soak")
local W = 2
local gen = {}

local function startWorker(i)
    gen[i] = (gen[i] or 0) + 1
    local ok, err = harness.start("s" .. i, "../stress/worker.lua", {
        id = "soak" .. i .. "g" .. gen[i], seed = i * 7919 + gen[i], inflight = 100, table = tbl, proxy = PROXY, counterName = "soak:ops",
    })
    if not ok then T.fail("cannot start soak worker: " .. tostring(err)) end
end

local function waitFrames(n)
    local f = harness.frame()
    T.waitFor(function() return harness.frame() >= f + n end, 5000 * SLOW, "frames")
end

local samples = {}
local base = {}

T.run({
    { "setup", function()
        local ok, err = pgQuerySync(T.admin(), "CREATE TABLE " .. tbl .. " (id bigserial, w text, v int)")
        T.ok(ok, "create table: " .. tostring(err))
        T.ok(harness.proxyStart(PROXY_PORT, PGHOST, PGPORT), "proxy")
        base.threads = harness.threadCount()
        base.fds = harness.fdCount()
        for i = 1, W do startWorker(i) end
    end },

    { "soak", function()
        local t0 = harness.now()
        local nextSample, nextKill, nextRestart, nextTrim = t0, t0 + 10000, t0 + 15000, t0 + 3000
        local lastOps = 0
        local restartIdx = 0
        while harness.now() - t0 < DURATION do
            T.sleep(250)
            local now = harness.now()
            if now >= nextKill then harness.proxyKill(); nextKill = now + 10000 end
            if now >= nextTrim then
                -- keep the table small so the database does not slow down over time
                pgExec(T.admin(), "DELETE FROM " .. tbl)
                nextTrim = now + 3000
            end
            if now >= nextRestart then
                restartIdx = restartIdx % W + 1
                harness.stop("s" .. restartIdx)
                waitFrames(2)
                startWorker(restartIdx)
                nextRestart = now + 15000
            end
            if now >= nextSample then
                nextSample = now + SAMPLE_EVERY
                local ops = harness.counter("soak:ops")
                local s = {
                    t = math.floor((now - t0) / 1000), ops = ops, rate = math.floor((ops - lastOps) / (SAMPLE_EVERY / 1000)),
                    rssKB = harness.rssKB(), threads = harness.threadCount(), fds = harness.fdCount(),
                    mainLuaKB = math.floor(collectgarbage("count")), mainRefs = harness.registryCount(),
                }
                lastOps = ops
                for i = 1, W do
                    local ok, rep = harness.call("s" .. i, "report")
                    if ok and rep then s["w" .. i .. "LuaKB"] = math.floor(rep.luaKB); s["w" .. i .. "Refs"] = rep.refs; s["w" .. i .. "Inflight"] = rep.inflight end
                end
                samples[#samples + 1] = s
                T.log(("soak t=%3ds ops=%7d (%5d/s) rss=%7d KB threads=%2d fds=%3d mainLua=%5d KB refs=%d w1Lua=%s KB w1refs=%s"):format(
                    s.t, s.ops, s.rate, s.rssKB, s.threads, s.fds, s.mainLuaKB, s.mainRefs, tostring(s.w1LuaKB), tostring(s.w1Refs)))
            end
        end
    end, timeout = 3600000 },

    { "verify flat resource usage", function()
        for i = 1, W do harness.stop("s" .. i) end
        waitFrames(2)
        T.waitBackends("stress-soak%", 0, 15000 * SLOW, "soak connections closed")
        T.sleep(300 * SLOW)
        local threads, fds = harness.threadCount(), harness.fdCount()
        T.log(("threads %d -> %d, fds %d -> %d"):format(base.threads, threads, base.fds, fds))
        T.ok(threads <= base.threads + 1, "no thread leak")
        T.ok(fds <= base.fds + 3, "no fd leak")
        local n = #samples
        T.ok(n >= 4, "enough samples (" .. n .. ")")
        if n >= 4 then
            local function avg(a, b, key)
                local sum, cnt = 0, 0
                for k = a, b do if samples[k] and samples[k][key] then sum = sum + samples[k][key]; cnt = cnt + 1 end end
                return cnt > 0 and sum / cnt or 0
            end
            local warm = math.max(2, math.floor(n * 0.3))
            local early = avg(warm, warm + 1, "rssKB")
            local late = avg(n - 1, n, "rssKB")
            local growth = late - early
            T.log(("RSS after warm-up %.0f KB, at the end %.0f KB, growth %.0f KB (%.1f%%)"):format(early, late, growth, 100 * growth / early))
            T.log("RSS series (KB): " .. table.concat((function() local t = {} for k = 1, n do t[k] = samples[k].rssKB end return t end)(), " "))
            local mainLuaEarly, mainLuaLate = avg(warm, warm + 1, "mainLuaKB"), avg(n - 1, n, "mainLuaKB")
            T.ok(mainLuaLate < mainLuaEarly * 2 + 512, ("controller Lua heap flat (%.0f -> %.0f KB)"):format(mainLuaEarly, mainLuaLate))
            if harness.variant == "plain" then
                T.ok(growth < math.max(8192, early * 0.10), "RSS flat after warm-up")
            else
                T.log("RSS growth not asserted under " .. harness.variant .. " (allocator quarantine / shadow memory)")
            end
        end
        local consumed = 0
        for _, st in ipairs({ "08006", "08001", "57014", "57P01" }) do consumed = consumed + T.takeDebug("pgExec failed: .*%[" .. st .. "%]", 2) end
        T.log("expected pgExec warnings from network cuts: " .. consumed)
        pgQuerySync(T.admin(), "DROP TABLE " .. tbl)
    end },
})
