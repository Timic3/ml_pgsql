-- A VM created right after another one was destroyed without hooks (possibly at the same
-- address). Its registry is filled with trap functions: if the module delivered an old VM's
-- callback here, lua_rawgeti(registry, oldRef) would find one of these and call it.
local function trap(...)
    if select("#", ...) > 0 then
        harness.counter("trap", 1)
        outputDebugString("TRAP: a callback of a destroyed VM ran in " .. resourceName, 1)
    end
end
for i = 1, 300 do setTimer(trap, 1000000, 1) end
harness.counter(resourceName .. ":fresh", 1)
