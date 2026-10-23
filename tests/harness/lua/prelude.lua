-- Loaded into every resource VM before its scripts (like MTA's embedded scripts).
-- Test helpers + small MTA-style utilities. Lua 5.1.

local harness = harness
local unpack, select, tostring, type, pairs, ipairs = unpack, select, tostring, type, pairs, ipairs

function pack(...) return { n = select("#", ...), ... } end

SLOW = harness.slowdown or 1          -- timing multiplier for slow variants (valgrind/tsan)
SCALE = harness.scale or 1            -- iteration multiplier for stress tests
CONNINFO = harness.getenv("MLPG_CONNINFO") or "host=127.0.0.1 user=mta password=mta dbname=mta sslmode=disable"
PGHOST = harness.getenv("MLPG_PGHOST") or "127.0.0.1"
PGPORT = tonumber(harness.getenv("MLPG_PGPORT") or "5432")

---------------------------------------------------------------------------------------------
-- inspect: compact, deterministic dump (sorted keys, binary-safe strings, cycle-safe)
---------------------------------------------------------------------------------------------
local function quote(s)
    return '"' .. s:gsub('[%c"\\\128-\255]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        local b = c:byte()
        if b >= 128 then return c end
        return string.format("\\%d", b)
    end) .. '"'
end

function inspect(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = type(v)
    if t == "string" then
        if #v > 200 then return quote(v:sub(1, 200)) .. "..(" .. #v .. " bytes)" end
        return quote(v)
    elseif t ~= "table" then
        return tostring(v)
    end
    if seen[v] then return "<cycle>" end
    if depth > 6 then return "{...}" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end)
    local parts, n = {}, #v
    for i = 1, n do parts[#parts + 1] = inspect(v[i], depth + 1, seen) end
    for _, k in ipairs(keys) do
        if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
            local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. inspect(k, depth + 1, seen) .. "]")
            parts[#parts + 1] = ks .. "=" .. inspect(v[k], depth + 1, seen)
        end
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

---------------------------------------------------------------------------------------------
-- assertions
---------------------------------------------------------------------------------------------
T = { checks = 0, failures = 0, timeout = 30000 * SLOW, stepTimeout = 120000 * SLOW }

function T.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    harness.log(table.concat(parts, " "))
end

function T.fail(msg, level)
    T.failures = T.failures + 1
    harness.fail(resourceName .. ": " .. tostring(msg) .. "\n" .. debug.traceback("", (level or 1) + 1))
end

function T.ok(cond, msg)
    T.checks = T.checks + 1
    if not cond then T.fail("check failed: " .. tostring(msg), 2) end
    return cond
end

local function deepEq(a, b, seen)
    if a == b then return true end
    if type(a) == "number" and type(b) == "number" then return a ~= a and b ~= b end -- NaN == NaN here
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for k, v in pairs(a) do if not deepEq(v, b[k], seen) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
T.deepEq = deepEq

function T.eq(actual, expected, msg)
    T.checks = T.checks + 1
    if not deepEq(actual, expected) then
        T.fail(("%s: expected %s, got %s"):format(tostring(msg), inspect(expected), inspect(actual)), 2)
        return false
    end
    return true
end

function T.near(actual, expected, eps, msg)
    T.checks = T.checks + 1
    if type(actual) ~= "number" or math.abs(actual - expected) > eps then
        T.fail(("%s: expected %s +- %s, got %s"):format(tostring(msg), tostring(expected), tostring(eps), inspect(actual)), 2)
        return false
    end
    return true
end

function T.match(s, pattern, msg)
    T.checks = T.checks + 1
    if type(s) ~= "string" or not s:find(pattern) then
        T.fail(("%s: %s does not match %q"):format(tostring(msg), inspect(s), pattern), 2)
        return false
    end
    return true
end

-- Expects fn(...) to raise an error matching `pattern`; returns the error.
function T.raises(pattern, fn, ...)
    T.checks = T.checks + 1
    local res = pack(pcall(fn, ...))
    if res[1] then
        T.fail(("expected an error matching %q, call returned %s"):format(pattern, inspect({ unpack(res, 2, res.n) })), 2)
        return nil
    end
    if not tostring(res[2]):find(pattern) then
        T.fail(("expected an error matching %q, got %q"):format(pattern, tostring(res[2])), 2)
    end
    return res[2]
end

---------------------------------------------------------------------------------------------
-- coroutine plumbing (Lua 5.1: no yield across pcall, so failures are tracked by the runner)
---------------------------------------------------------------------------------------------

-- Suspends the running coroutine until `wake(...)` is called (by a callback, timer, ...).
-- `setup(wake)` arms whatever will call wake. Returns wake's arguments.
function T.wait(setup, timeoutMs, what)
    local co = coroutine.running()
    assert(co, "T.wait needs a coroutine")
    local st = { done = false, waiting = false }
    local function wake(...)
        if st.done then return end
        st.done = true
        st.values = pack(...)
        if st.waiting then
            st.waiting = false
            local ok, err = coroutine.resume(co)
            if not ok then T.fail("test coroutine raised: " .. tostring(err)) end
        end
    end
    setup(wake)
    if not st.done then
        local timer = setTimer(function()
            if not st.done then st.timedOut = true; wake() end
        end, timeoutMs or T.timeout, 1)
        st.waiting = true
        coroutine.yield()
        if isTimer(timer) then killTimer(timer) end
    end
    if st.timedOut then
        T.fail("timed out waiting for " .. tostring(what), 2)
        return nil, "harness timeout"
    end
    return unpack(st.values, 1, st.values.n)
end

function T.sleep(ms)
    T.wait(function(wake) setTimer(wake, ms, 1) end, ms + T.timeout, "sleep")
end

function T.waitFor(pred, timeoutMs, what)
    local t0 = getTickCount()
    timeoutMs = timeoutMs or T.timeout
    while not pred() do
        if getTickCount() - t0 > timeoutMs then
            T.fail("timed out waiting for " .. tostring(what), 2)
            return false
        end
        T.sleep(5)
    end
    return true
end

-- Runs fn in a new coroutine right away.
function T.async(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    if not ok then T.fail("async body raised: " .. tostring(err)) end
    return co
end

-- Callback-style API calls turned into sequential code (inside a coroutine).
-- Returns the callback arguments; if submission failed returns false, err.
function T.query(db, sql, ...)
    local args = pack(...)
    return T.wait(function(wake)
        local ok, err = pgQuery(db, wake, sql, unpack(args, 1, args.n))
        if not ok then wake(false, "submit failed: " .. tostring(err), "submit") end
    end, nil, sql)
end

function T.tx(db, statements)
    return T.wait(function(wake)
        local ok, err = pgTransaction(db, statements, wake)
        if not ok then wake(false, "submit failed: " .. tostring(err), "submit") end
    end, nil, "transaction")
end

---------------------------------------------------------------------------------------------
-- debug output expectations (outputDebugString is recorded by the host)
---------------------------------------------------------------------------------------------

-- Consumes unconsumed debug messages matching `pattern` (and level, resource if given).
function T.takeDebug(pattern, level, resource)
    local n = 0
    for _, m in ipairs(harness.debugMessages()) do
        if (not level or m.level == level) and (not resource or m.resource == resource) and m.text:find(pattern) then
            harness.consumeDebug(m.id)
            n = n + 1
        end
    end
    return n
end

function T.expectDebug(pattern, expected, level, msg)
    local n = T.takeDebug(pattern, level)
    return T.eq(n, expected, msg or ("debug messages matching " .. pattern))
end

-- Level 1/2 messages nobody consumed so far.
function T.unexpectedDebug()
    local list = {}
    for _, m in ipairs(harness.debugMessages()) do
        if m.level <= 2 then list[#list + 1] = m end
    end
    return list
end

function T.checkNoUnexpectedDebug(msg)
    local list = T.unexpectedDebug()
    T.checks = T.checks + 1
    if #list > 0 then
        local lines = {}
        for i = 1, math.min(#list, 10) do lines[i] = ("[%s] L%d %s"):format(list[i].resource, list[i].level, list[i].text) end
        T.fail(("%s: %d unexpected debug message(s):\n  %s"):format(msg or "debug output", #list, table.concat(lines, "\n  ")), 2)
        for _, m in ipairs(list) do harness.consumeDebug(m.id) end
    end
end

---------------------------------------------------------------------------------------------
-- step runner: steps run one after another, each in its own coroutine, with a timeout.
-- A step that dies (error raised while resumed by the module) or hangs fails and the runner
-- moves on. When all steps are done T.done() is called.
---------------------------------------------------------------------------------------------
function T.run(steps)
    local i = 0
    local current
    local function startNext()
        i = i + 1
        local s = steps[i]
        if not s then return false end
        T.log(("---- step %d/%d: %s"):format(i, #steps, s[1]))
        local cur = { name = s[1], started = getTickCount(), timeout = (s.timeout or 120000) * SLOW }
        current = cur
        cur.co = coroutine.create(function()
            s[2]()
            cur.finished = true
        end)
        local ok, err = coroutine.resume(cur.co)
        if not ok then
            T.fail(("step '%s' raised: %s"):format(cur.name, tostring(err)))
            cur.failed = true
        end
        return true
    end
    local timer
    timer = setTimer(function()
        if not current or current.finished or current.failed then
            if not startNext() then
                killTimer(timer)
                T.done()
            end
            return
        end
        if coroutine.status(current.co) == "dead" then
            T.fail(("step '%s' died (see debug output for the error)"):format(current.name))
            current.failed = true
        elseif getTickCount() - current.started > current.timeout then
            T.fail(("step '%s' timed out after %d ms"):format(current.name, current.timeout))
            current.failed = true
        end
    end, 5, 0)
end

function T.done(extra)
    T.checkNoUnexpectedDebug("at end of scenario")
    local summary = ("%s: %d checks, %d failures%s"):format(resourceName, T.checks, T.failures, extra and (" - " .. extra) or "")
    T.log("==== " .. summary)
    harness.done(T.failures == 0, summary)
end

---------------------------------------------------------------------------------------------
-- misc
---------------------------------------------------------------------------------------------

-- A second, independent connection for verification queries (pg_stat_activity etc.).
function T.admin()
    if not T._admin then
        T._admin = assert(pgConnect(CONNINFO, { applicationName = "harness-admin:" .. resourceName }))
    end
    return T._admin
end

-- Number of backends whose application_name matches a LIKE pattern.
function T.backends(likePattern)
    local rows, err = pgQuerySync(T.admin(), "SELECT count(*)::int AS n FROM pg_stat_activity WHERE application_name LIKE $1", likePattern)
    if not rows then T.fail("backend count failed: " .. tostring(err)) return -1 end
    return rows[1].n
end

function T.waitBackends(likePattern, expected, timeoutMs, what)
    local t0 = getTickCount()
    local n
    repeat
        n = T.backends(likePattern)
        if n == expected then return true end
        T.sleep(25)
    until getTickCount() - t0 > (timeoutMs or 5000)
    T.fail(("%s: expected %d backends like %q, have %d"):format(what or "backends", expected, likePattern, n), 2)
    return false
end

-- Waits until a backend of `app` is running a query (state = 'active').
function T.waitActive(app, timeoutMs)
    local t0 = getTickCount()
    repeat
        local r = pgQuerySync(T.admin(), "SELECT count(*)::int AS n FROM pg_stat_activity WHERE application_name = $1 AND state = 'active'", app)
        if r and r[1].n > 0 then return true end
        T.sleep(20)
    until getTickCount() - t0 > (timeoutMs or 10000 * SLOW)
    T.fail("no active query for " .. app, 2)
    return false
end

-- Unique-ish token for table names / application names.
local uniq = 0
function T.uniq(prefix)
    uniq = uniq + 1
    return ("%s_%s_%d_%d_%d"):format(prefix or "t", (resourceName:gsub("%W", "_")), os.time(), math.random(1, 1e6), uniq)
end
