-- Scenario 6: stress. ~100k mixed operations (x SCALE) across several VMs while resources are
-- stopped/started at random, VMs are destroyed without hooks, connections are closed or
-- dropped, the network is cut and the module is reloaded.
local W = 4
local TARGET = math.floor(100000 * SCALE)
local PROXY_PORT = 15434
local PROXY = ("host=127.0.0.1 port=%d user=mta password=mta dbname=mta sslmode=disable"):format(PROXY_PORT)
local tbl = T.uniq("stress")
math.randomseed(12345)

local gen = {}
local function startWorker(i)
    gen[i] = (gen[i] or 0) + 1
    local ok, err = harness.start("w" .. i, "worker.lua", {
        id = i .. "g" .. gen[i], seed = i * 1000 + gen[i], inflight = 150, table = tbl, proxy = PROXY,
    })
    if not ok then T.fail("cannot start worker " .. i .. ": " .. tostring(err)) end
end

local function waitFrames(n)
    local f = harness.frame()
    T.waitFor(function() return harness.frame() >= f + n end, 5000 * SLOW, "frames")
end

local chaos = { stops = 0, destroys = 0, reloads = 0, kills = 0 }
local threads0

T.run({
    { "setup", function()
        local ok, err = pgQuerySync(T.admin(), "CREATE TABLE " .. tbl .. " (id bigserial, w text, v int)")
        T.ok(ok, "create table: " .. tostring(err))
        T.ok(harness.proxyStart(PROXY_PORT, PGHOST, PGPORT), "proxy")
        threads0 = harness.threadCount()
        for i = 1, W do startWorker(i) end
    end },

    { "run with chaos until the target is reached", function()
        local t0 = harness.now()
        local lastReport = t0
        local maxReloads = SCALE >= 0.25 and 2 or 1
        local reloadAt = { [math.floor(TARGET * 0.35)] = true, [math.floor(TARGET * 0.7)] = maxReloads > 1 }
        local reloadsDone = {}
        while harness.counter("stress:ops") < TARGET do
            T.sleep(math.random(150, 600) * SLOW)
            local ops = harness.counter("stress:ops")
            local r = math.random(1, 10)
            local w = math.random(1, W)
            for mark, on in pairs(reloadAt) do
                if on and ops >= mark and not reloadsDone[mark] then
                    reloadsDone[mark] = true
                    harness.reloadModule()
                    waitFrames(2)
                    T._admin = nil
                    chaos.reloads = chaos.reloads + 1
                    T.log(("reloadmodule at %d ops: ShutdownModule %.0f ms"):format(ops, harness.lastShutdownMs()))
                end
            end
            if r <= 4 then
                harness.stop("w" .. w)
                waitFrames(2)
                startWorker(w)
                chaos.stops = chaos.stops + 1
            elseif r == 5 then
                harness.destroyNoHooks("w" .. w, { reuseAddress = math.random() < 0.5 })
                waitFrames(2)
                startWorker(w)
                chaos.destroys = chaos.destroys + 1
            elseif r <= 7 then
                harness.proxyKill()
                chaos.kills = chaos.kills + 1
            end
            if harness.now() - lastReport > 5000 then
                lastReport = harness.now()
                T.log(("ops %d / %d, threads %d, rss %d KB, chaos %s"):format(harness.counter("stress:ops"), TARGET, harness.threadCount(), harness.rssKB(), inspect(chaos)))
            end
            if harness.now() - t0 > 1200000 * SLOW then
                T.fail("stress did not reach the target in time")
                break
            end
        end
        local secs = (harness.now() - t0) / 1000
        T.log(("reached %d ops in %.1f s (%.0f ops/s), chaos %s"):format(harness.counter("stress:ops"), secs, harness.counter("stress:ops") / secs, inspect(chaos)))
        for i = 1, W do
            local ok, rep = harness.call("w" .. i, "report")
            if ok then T.log("worker " .. i .. ": " .. inspect(rep)) end
        end
    end, timeout = 1500000 },

    { "stop everything and verify nothing is left", function()
        for i = 1, W do harness.stop("w" .. i) end
        waitFrames(2)
        T.waitBackends("stress-%", 0, 15000 * SLOW, "all stress connections closed")
        T.sleep(300 * SLOW)
        local threads = harness.threadCount()
        T.log(("threads: %d at start, %d now"):format(threads0, threads))
        T.ok(threads <= threads0 + 1, "worker threads all exited")
        -- pgExec failures caused by the chaos (network cut, closing pools) are expected
        local consumed = 0
        for _, st in ipairs({ "08006", "08001", "57014", "57P01" }) do consumed = consumed + T.takeDebug("pgExec failed: .*%[" .. st .. "%]", 2) end
        T.log("expected pgExec warnings from chaos: " .. consumed)
        local onStopRows = pgQuerySync(T.admin(), "SELECT count(*)::int AS n FROM " .. tbl .. " WHERE v = -1")
        T.log("onStop rows written: " .. inspect(onStopRows))
        pgQuerySync(T.admin(), "DROP TABLE " .. tbl)
    end },
})
