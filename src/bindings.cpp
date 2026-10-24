// Lua functions exported to resources.
//
// MTA's Lua raises errors with longjmp, which skips C++ destructors. Every binding is
// therefore split into three phases:
//   1. argument checks  - may raise; no C++ objects with destructors are alive yet
//   2. work             - C++ objects allowed; only Lua calls that cannot raise
//                         (lua_type, lua_rawgeti, lua_tolstring on strings, ...)
//   3. push results     - may raise only on out-of-memory, like MTA's own bindings
// Errors found in phase 2 are copied to a stack buffer and raised after the objects are gone.

#include "convert.h"
#include "module.h"

#include <cstdio>
#include <cstring>
#include <exception>
#include <string>

namespace mlpg
{
    namespace
    {
        constexpr const char* kConnMeta = "ml_pgsql.connection";
        constexpr int         kMaxParams = 65535;
        constexpr int         kMaxStatements = 100000;

        constexpr uint64_t kConnMagic = 0x6d6c5f7067736c31ull;  // "ml_pgsl1"

        struct ConnHandle
        {
            uint64_t magic;
            uint64_t poolId;
        };

        // Registry key of the per-VM sentinel whose finalizer tells us lua_close ran.
        char g_vmSentinelKey;

        struct Error
        {
            char text[384] = {0};
            void Set(const char* fmt, const char* a = "", const char* b = "") { snprintf(text, sizeof(text), fmt, a, b); }
        };

        enum Status : int
        {
            kRaise = -1,  // programming error: raise a Lua error
            kFail = 0,    // runtime failure: return false, message
            kOk = 1,
        };

        // ---- phase 1 helpers (may raise) ----------------------------------------------

        // Validates more than the metatable: MTA exposes debug.setmetatable, so a script
        // could attach ours to an unrelated userdata.
        const ConnHandle* ToConn(lua_State* L, int idx)
        {
            if (lua_type(L, idx) != LUA_TUSERDATA || lua_objlen(L, idx) != sizeof(ConnHandle))
                return nullptr;
            const auto* handle = static_cast<const ConnHandle*>(lua_touserdata(L, idx));
            return handle && handle->magic == kConnMagic ? handle : nullptr;
        }

        uint64_t CheckConn(lua_State* L, int idx)
        {
            luaL_checkudata(L, idx, kConnMeta);
            const ConnHandle* handle = ToConn(L, idx);
            if (!handle)
                luaL_argerror(L, idx, "invalid ml_pgsql.connection");
            return handle->poolId;
        }

        const char* CheckSql(lua_State* L, int idx, size_t* len)
        {
            const char* sql = luaL_checklstring(L, idx, len);
            if (strlen(sql) != *len)
                luaL_argerror(L, idx, "SQL contains a NUL byte");
            return sql;
        }

        void CheckParamCount(lua_State* L, int count)
        {
            if (count > kMaxParams)
                luaL_error(L, "too many query parameters (%d, max %d)", count, kMaxParams);
        }

        int PushFailure(lua_State* L, const char* message)
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, message);
            return 2;
        }

        // ---- phase 2 helpers (never raise) ----------------------------------------------

        void CaptureWhere(lua_State* L, char* out, size_t size)
        {
            lua_Debug ar;
            out[0] = '\0';
            if (lua_getstack(L, 1, &ar) && lua_getinfo(L, "Sl", &ar) && ar.currentline > 0)
                snprintf(out, size, "%s:%d", ar.short_src, ar.currentline);
        }

        bool BuildStatement(lua_State* L, Statement& st, const char* sql, size_t len, int first, int last, bool allowSimple, Error& err)
        {
            st.sql.assign(sql, len);
            const int count = last >= first ? last - first + 1 : 0;
            st.paramOffsets.reserve(static_cast<size_t>(count));
            for (int i = first; i <= last; ++i)
            {
                char detail[256];
                if (!AppendParam(L, i, st, detail, sizeof(detail)))
                {
                    char index[16];
                    snprintf(index, sizeof(index), "%d", i - first + 1);
                    err.Set("bad query parameter $%s: %s", index, detail);
                    return false;
                }
            }
            st.simpleProtocol = allowSimple && count == 0 && NeedsSimpleProtocol(sql, len);
            if (!st.simpleProtocol && IsTransactionStart(sql, len))
            {
                // Each call is independent and the session is shared with every other
                // query of the resource, so a transaction must not span calls.
                err.Set("BEGIN/START TRANSACTION cannot be sent on its own; use pgTransaction, or run the "
                        "whole BEGIN ... COMMIT block as one multi-statement string");
                return false;
            }
            return true;
        }

        // statements = { "SQL", {"SQL $1", p1, ...}, ... }
        bool BuildTransaction(lua_State* L, int tableIdx, Job& job, Error& err)
        {
            const size_t count = lua_objlen(L, tableIdx);
            if (count == 0)
            {
                err.Set("statements table is empty");
                return false;
            }
            if (count > static_cast<size_t>(kMaxStatements) || !lua_checkstack(L, 8))
            {
                err.Set("too many statements in one transaction");
                return false;
            }
            job.transaction = true;
            job.stmts.resize(count);
            const int base = lua_gettop(L);
            for (size_t i = 1; i <= count; ++i)
            {
                char number[16];
                snprintf(number, sizeof(number), "%zu", i);
                lua_settop(L, base);
                lua_rawgeti(L, tableIdx, static_cast<int>(i));
                const int entry = lua_gettop(L);

                const char* sql = nullptr;
                size_t      len = 0;
                size_t      maxKey = 0;
                if (lua_type(L, entry) == LUA_TSTRING)
                    sql = lua_tolstring(L, entry, &len);
                else if (lua_type(L, entry) == LUA_TTABLE)
                {
                    lua_rawgeti(L, entry, 1);
                    if (lua_type(L, -1) == LUA_TSTRING)
                        sql = lua_tolstring(L, -1, &len);
                    // Parameters are entry[2..n]; n is the largest integer key so nil holes work.
                    lua_pushnil(L);
                    while (lua_next(L, entry))
                    {
                        const bool   isNumber = lua_type(L, -2) == LUA_TNUMBER;
                        const double k = isNumber ? lua_tonumber(L, -2) : 0;
                        lua_settop(L, -2);
                        if (!isNumber || k < 1 || k > kMaxParams + 1 || k != static_cast<double>(static_cast<size_t>(k)))
                        {
                            lua_settop(L, base);
                            err.Set("statement #%s: expected {sql, param1, param2, ...}", number);
                            return false;
                        }
                        if (static_cast<size_t>(k) > maxKey)
                            maxKey = static_cast<size_t>(k);
                    }
                }
                if (!sql)
                {
                    lua_settop(L, base);
                    err.Set("statement #%s must be a string or {sql, params...}", number);
                    return false;
                }
                if (strlen(sql) != len)
                {
                    lua_settop(L, base);
                    err.Set("statement #%s: SQL contains a NUL byte", number);
                    return false;
                }
                if (IsTransactionControl(sql, len) || IsCopy(sql, len))
                {
                    lua_settop(L, base);
                    err.Set("statement #%s: %s", number, "transaction control and COPY are not allowed (pgTransaction already runs atomically)");
                    return false;
                }
                Statement& st = job.stmts[i - 1];
                st.sql.assign(sql, len);
                st.paramOffsets.reserve(maxKey > 1 ? maxKey - 1 : 0);
                for (size_t p = 2; p <= maxKey; ++p)
                {
                    lua_rawgeti(L, entry, static_cast<int>(p));
                    char detail[256];
                    const bool ok = AppendParam(L, -1, st, detail, sizeof(detail));
                    lua_settop(L, -2);
                    if (!ok)
                    {
                        lua_settop(L, base);
                        char index[16];
                        snprintf(index, sizeof(index), "%zu", p - 1);
                        err.Set("statement #%s: bad parameter $%s: ", number, index);
                        strncat(err.text, detail, sizeof(err.text) - strlen(err.text) - 1);
                        return false;
                    }
                }
                lua_settop(L, base);
            }
            return true;
        }

        enum class Kind
        {
            Query,
            Transaction,
        };

        // Builds a job for the arguments of a query/transaction call.
        // Query:       args [first..last] are params of `sql`
        // Transaction: `first` is the stack index of the statements table
        int BuildJob(lua_State* L, Kind kind, uint64_t poolId, Delivery delivery, const char* sql, size_t len, int first, int last, JobPtr& out,
                     PoolEntry*& entryOut, Error& err)
        {
            PoolEntry* entry = g_module->FindPoolFor(L, poolId);
            if (!entry)
            {
                err.Set("connection is closed");
                return kFail;
            }
            auto job = std::make_unique<Job>();
            job->delivery = delivery;
            job->conv = entry->pool->Config().conv;
            job->vm = g_module->FindVmShared(L);
            if (kind == Kind::Query)
            {
                job->stmts.resize(1);
                if (!BuildStatement(L, job->stmts[0], sql, len, first, last, true, err))
                    return kRaise;
            }
            else if (!BuildTransaction(L, first, *job, err))
                return kRaise;
            if (delivery == Delivery::Exec)
                CaptureWhere(L, job->where, sizeof(job->where));
            job->id = g_module->NextJobId();
            out = std::move(job);
            entryOut = entry;
            return kOk;
        }

        int Submit(PoolEntry& entry, JobPtr& job, Error& err)
        {
            switch (entry.pool->Submit(job))
            {
                case Pool::SubmitResult::Ok:
                    return kOk;
                case Pool::SubmitResult::Closed:
                    err.Set("connection is closed");
                    return kFail;
                case Pool::SubmitResult::QueueFull:
                default:
                    err.Set("query queue is full (maxQueue reached); the database cannot keep up");
                    return kFail;
            }
        }

        // Callback / Exec delivery. `ref` is owned by the job only if this returns kOk.
        int SubmitAsync(lua_State* L, Kind kind, uint64_t poolId, Delivery delivery, int ref, const char* sql, size_t len, int first, int last,
                        Error& err)
        {
            try
            {
                JobPtr     job;
                PoolEntry* entry = nullptr;
                const int  rc = BuildJob(L, kind, poolId, delivery, sql, len, first, last, job, entry, err);
                if (rc != kOk)
                    return rc;
                job->ref = ref;
                const int submitted = Submit(*entry, job, err);
                if (submitted != kOk)
                    job->ref = LUA_NOREF;  // the caller still owns it
                return submitted;
            }
            catch (const std::exception& e)
            {
                err.Set("%s", e.what());
                return kFail;
            }
        }

        // Sync delivery: submit, then block until the job is back or the timeout passes.
        int RunSync(lua_State* L, Kind kind, uint64_t poolId, const char* sql, size_t len, int first, int last, JobPtr& done, Error& err)
        {
            try
            {
                JobPtr     job;
                PoolEntry* entry = nullptr;
                const int  rc = BuildJob(L, kind, poolId, Delivery::Sync, sql, len, first, last, job, entry, err);
                if (rc != kOk)
                    return rc;
                const uint64_t id = job->id;
                const int      timeoutMs = entry->syncTimeoutMs;
                if (Submit(*entry, job, err) != kOk)
                    return kFail;
                done = g_module->WaitForJob(id, timeoutMs);
                if (!done)
                {
                    char ms[16];
                    snprintf(ms, sizeof(ms), "%d", timeoutMs);
                    err.Set("timed out after %s ms waiting for the database (the query may still complete)", ms);
                    return kFail;
                }
                return kOk;
            }
            catch (const std::exception& e)
            {
                done.reset();
                err.Set("%s", e.what());
                return kFail;
            }
        }

        // Await delivery, part 1: build the job and park it in the VM (not submitted yet).
        int StageAwait(lua_State* L, VmState& vm, Kind kind, uint64_t poolId, const char* sql, size_t len, int first, int last, Error& err,
                       uint64_t& poolOut)
        {
            try
            {
                JobPtr     job;
                PoolEntry* entry = nullptr;
                const int  rc = BuildJob(L, kind, poolId, Delivery::Await, sql, len, first, last, job, entry, err);
                if (rc != kOk)
                    return rc;
                if (entry->pool->IsClosed())
                {
                    err.Set("connection is closed");
                    return kFail;
                }
                vm.staged = std::move(job);
                poolOut = poolId;
                return kOk;
            }
            catch (const std::exception& e)
            {
                err.Set("%s", e.what());
                return kFail;
            }
        }

        // Await delivery, part 2 (after lua_yield succeeded): submit, or complete with an
        // error so the coroutine is resumed with (false, message) on the next pulse.
        void SubmitStaged(VmState& vm, uint64_t poolId)
        {
            JobPtr job = std::move(vm.staged);
            if (!job)
                return;
            try
            {
                Error      err;
                PoolEntry* entry = g_module->FindPool(poolId);
                if (!entry)
                    err.Set("connection is closed");
                else if (Submit(*entry, job, err) == kOk)
                    return;
                job->Fail("55000", err.text);
                g_module->CompleteNow(std::move(job));
            }
            catch (const std::exception&)
            {
                // Out of memory: the coroutine stays suspended; its ref dies with the VM.
            }
        }

        // A previous await whose lua_yield raised (yield across a C boundary) left its job
        // and coroutine ref parked here.
        void ReclaimStaged(VmState& vm)
        {
            if (!vm.staged)
                return;
            if (vm.staged->ref != LUA_NOREF)
                luaL_unref(vm.L, LUA_REGISTRYINDEX, vm.staged->ref);
            vm.staged.reset();
        }

        // ---- shared bodies ------------------------------------------------------------------

        int DoAwait(lua_State* L, Kind kind, uint64_t poolId, const char* sql, size_t len, int first, int last)
        {
            VmState* vm = g_module->FindVm(L);
            ReclaimStaged(*vm);
            Error    err;
            uint64_t stagedPool = 0;
            const int rc = StageAwait(L, *vm, kind, poolId, sql, len, first, last, err, stagedPool);
            if (rc == kRaise)
                return luaL_error(L, "%s", err.text);
            if (rc == kFail)
                return PushFailure(L, err.text);

            lua_pushthread(L);
            vm->staged->ref = luaL_ref(L, LUA_REGISTRYINDEX);  // anchors the coroutine
            const int yielded = lua_yield(L, 0);               // raises if not yieldable here
            SubmitStaged(*vm, stagedPool);  // no Lua calls past the yield
            return yielded;
        }

        int DoSync(lua_State* L, Kind kind, uint64_t poolId, const char* sql, size_t len, int first, int last)
        {
            Error     err;
            JobPtr    done;
            const int rc = RunSync(L, kind, poolId, sql, len, first, last, done, err);
            if (rc == kOk)
                return PushOutcome(L, *done);
            done.reset();
            if (rc == kRaise)
                return luaL_error(L, "%s", err.text);
            return PushFailure(L, err.text);
        }

        int DoAsync(lua_State* L, Kind kind, uint64_t poolId, Delivery delivery, int ref, const char* sql, size_t len, int first, int last)
        {
            Error     err;
            const int rc = SubmitAsync(L, kind, poolId, delivery, ref, sql, len, first, last, err);
            if (rc == kOk)
            {
                lua_pushboolean(L, 1);
                return 1;
            }
            if (ref != LUA_NOREF)
                luaL_unref(L, LUA_REGISTRYINDEX, ref);
            if (rc == kRaise)
                return luaL_error(L, "%s", err.text);
            return PushFailure(L, err.text);
        }

        int RefFunction(lua_State* L, int idx)
        {
            lua_pushvalue(L, idx);
            return luaL_ref(L, LUA_REGISTRYINDEX);
        }

        // ---- Lua functions ----------------------------------------------------------------------

        // pgQuery(conn, callback, sql, ...) -> true | false, err
        int l_pgQuery(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            luaL_checktype(L, 2, LUA_TFUNCTION);
            size_t      len;
            const char* sql = CheckSql(L, 3, &len);
            const int   last = lua_gettop(L);
            CheckParamCount(L, last - 3);
            const int ref = RefFunction(L, 2);
            return DoAsync(L, Kind::Query, poolId, Delivery::Callback, ref, sql, len, 4, last);
        }

        // pgExec(conn, sql, ...) -> true | false, err
        int l_pgExec(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            size_t         len;
            const char*    sql = CheckSql(L, 2, &len);
            const int      last = lua_gettop(L);
            CheckParamCount(L, last - 2);
            return DoAsync(L, Kind::Query, poolId, Delivery::Exec, LUA_NOREF, sql, len, 3, last);
        }

        // pgQuerySync(conn, sql, ...) -> rows, nil, affected | false, err, sqlstate
        int l_pgQuerySync(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            size_t         len;
            const char*    sql = CheckSql(L, 2, &len);
            const int      last = lua_gettop(L);
            CheckParamCount(L, last - 2);
            return DoSync(L, Kind::Query, poolId, sql, len, 3, last);
        }

        // pgQueryAwait(conn, sql, ...) -> rows, nil, affected | false, err, sqlstate  (yields)
        int l_pgQueryAwait(lua_State* L)
        {
            if (lua_getmainstate(L) == L)
                return luaL_error(L, "pgQueryAwait must be called from inside a coroutine");
            const uint64_t poolId = CheckConn(L, 1);
            size_t         len;
            const char*    sql = CheckSql(L, 2, &len);
            const int      last = lua_gettop(L);
            CheckParamCount(L, last - 2);
            return DoAwait(L, Kind::Query, poolId, sql, len, 3, last);
        }

        // pgTransaction(conn, statements, callback) -> true | false, err
        int l_pgTransaction(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            luaL_checktype(L, 2, LUA_TTABLE);
            luaL_checktype(L, 3, LUA_TFUNCTION);
            lua_settop(L, 3);
            const int ref = RefFunction(L, 3);
            return DoAsync(L, Kind::Transaction, poolId, Delivery::Callback, ref, nullptr, 0, 2, 2);
        }

        // pgTransactionSync(conn, statements) -> results, nil, affected | false, err, sqlstate, index
        int l_pgTransactionSync(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            luaL_checktype(L, 2, LUA_TTABLE);
            lua_settop(L, 2);
            return DoSync(L, Kind::Transaction, poolId, nullptr, 0, 2, 2);
        }

        // pgTransactionAwait(conn, statements) -> same as pgTransactionSync (yields)
        int l_pgTransactionAwait(lua_State* L)
        {
            if (lua_getmainstate(L) == L)
                return luaL_error(L, "pgTransactionAwait must be called from inside a coroutine");
            const uint64_t poolId = CheckConn(L, 1);
            luaL_checktype(L, 2, LUA_TTABLE);
            lua_settop(L, 2);
            return DoAwait(L, Kind::Transaction, poolId, nullptr, 0, 2, 2);
        }

        struct ConnectOptions
        {
            int         poolSize = 1;
            int         batchSize = 64;
            double      maxQueue = 100000;
            int         connectTimeoutMs = 10000;
            int         queryTimeoutMs = 0;
            int         drainTimeoutMs = 10000;
            int         syncTimeoutMs = 30000;
            bool        lazy = false;
            bool        pipeline = true;
            Int64Mode   int64 = Int64Mode::Auto;
            NumericMode numeric = NumericMode::Number;
            const char* appName = nullptr;  // kept alive on the Lua stack
        };

        double OptNumber(lua_State* L, int t, const char* name, double def, double min, double max)
        {
            lua_getfield(L, t, name);
            if (lua_isnil(L, -1))
            {
                lua_pop(L, 1);
                return def;
            }
            if (lua_type(L, -1) != LUA_TNUMBER)
                luaL_error(L, "pgConnect option '%s' must be a number", name);
            const double v = lua_tonumber(L, -1);
            lua_pop(L, 1);
            if (!(v >= min && v <= max))
                luaL_error(L, "pgConnect option '%s' must be between %f and %f", name, min, max);
            return v;
        }

        bool OptBool(lua_State* L, int t, const char* name, bool def)
        {
            lua_getfield(L, t, name);
            bool v = def;
            if (!lua_isnil(L, -1))
            {
                if (lua_type(L, -1) != LUA_TBOOLEAN)
                    luaL_error(L, "pgConnect option '%s' must be a boolean", name);
                v = lua_toboolean(L, -1) != 0;
            }
            lua_pop(L, 1);
            return v;
        }

        // Leaves the string (if any) on the stack so the pointer stays valid.
        const char* OptString(lua_State* L, int t, const char* name)
        {
            lua_getfield(L, t, name);
            if (lua_isnil(L, -1))
            {
                lua_pop(L, 1);
                return nullptr;
            }
            if (lua_type(L, -1) != LUA_TSTRING)
                luaL_error(L, "pgConnect option '%s' must be a string", name);
            return lua_tostring(L, -1);
        }

        void ReadOptions(lua_State* L, int t, ConnectOptions& o)
        {
            o.poolSize = static_cast<int>(OptNumber(L, t, "poolSize", o.poolSize, 1, 64));
            o.batchSize = static_cast<int>(OptNumber(L, t, "batchSize", o.batchSize, 1, 1000));
            o.maxQueue = OptNumber(L, t, "maxQueue", o.maxQueue, 1, 1e8);
            o.connectTimeoutMs = static_cast<int>(OptNumber(L, t, "connectTimeout", o.connectTimeoutMs, 100, 600000));
            o.queryTimeoutMs = static_cast<int>(OptNumber(L, t, "queryTimeout", o.queryTimeoutMs, 0, 86400000));
            o.drainTimeoutMs = static_cast<int>(OptNumber(L, t, "drainTimeout", o.drainTimeoutMs, 0, 600000));
            o.syncTimeoutMs = static_cast<int>(OptNumber(L, t, "syncTimeout", o.syncTimeoutMs, 1, 600000));
            o.lazy = OptBool(L, t, "lazy", o.lazy);
            o.pipeline = OptBool(L, t, "pipeline", o.pipeline);

            if (const char* s = OptString(L, t, "int64"))
            {
                if (!strcmp(s, "auto"))
                    o.int64 = Int64Mode::Auto;
                else if (!strcmp(s, "number"))
                    o.int64 = Int64Mode::Number;
                else if (!strcmp(s, "string"))
                    o.int64 = Int64Mode::String;
                else
                    luaL_error(L, "pgConnect option 'int64' must be \"auto\", \"number\" or \"string\"");
                lua_pop(L, 1);
            }
            if (const char* s = OptString(L, t, "numeric"))
            {
                if (!strcmp(s, "number"))
                    o.numeric = NumericMode::Number;
                else if (!strcmp(s, "string"))
                    o.numeric = NumericMode::String;
                else
                    luaL_error(L, "pgConnect option 'numeric' must be \"number\" or \"string\"");
                lua_pop(L, 1);
            }
            o.appName = OptString(L, t, "applicationName");  // stays on the stack
        }

        int OpenPool(lua_State* L, const char* conninfo, const ConnectOptions& o, const char* resourceName, uint64_t& idOut, Error& err)
        {
            try
            {
                // Catch syntax errors without touching the network.
                if (strchr(conninfo, '=') || !strncmp(conninfo, "postgres://", 11) || !strncmp(conninfo, "postgresql://", 13))
                {
                    char*             parseError = nullptr;
                    PQconninfoOption* parsed = PQconninfoParse(conninfo, &parseError);
                    if (!parsed)
                    {
                        std::string message = parseError ? parseError : "out of memory";
                        if (parseError)
                            PQfreemem(parseError);
                        while (!message.empty() && message.back() == '\n')
                            message.pop_back();
                        err.Set("invalid connection string: %s", message.c_str());
                        return kFail;
                    }
                    PQconninfoFree(parsed);
                }

                PoolConfig cfg;
                cfg.conninfo = conninfo;
                cfg.appName = o.appName ? o.appName : (std::string("mta:") + resourceName);
                cfg.size = o.poolSize;
                cfg.maxBatch = o.pipeline ? o.batchSize : 1;
                cfg.maxQueue = static_cast<size_t>(o.maxQueue);
                cfg.connectTimeoutMs = o.connectTimeoutMs;
                cfg.statementTimeoutMs = o.queryTimeoutMs;
                cfg.conv.int64 = o.int64;
                cfg.conv.numeric = o.numeric;

                const uint64_t id = g_module->NextPoolId();
                auto           pool = std::make_shared<Pool>(id, std::move(cfg), g_module->Completions());
                pool->Start();
                if (!o.lazy)
                {
                    std::string error;
                    if (!pool->WaitReady(o.connectTimeoutMs + 1000, error))
                    {
                        g_module->DiscardPool(std::move(pool));
                        err.Set("could not connect to PostgreSQL: %s", error.c_str());
                        return kFail;
                    }
                }
                PoolEntry entry;
                entry.pool = std::move(pool);
                entry.drainTimeoutMs = o.drainTimeoutMs;
                entry.syncTimeoutMs = o.syncTimeoutMs;
                g_module->AddPool(id, std::move(entry), g_module->FindVm(L));
                idOut = id;
                return kOk;
            }
            catch (const std::exception& e)
            {
                err.Set("could not create connection pool: %s", e.what());
                return kFail;
            }
        }

        // pgConnect(conninfo [, options]) -> connection | false, err
        int l_pgConnect(lua_State* L)
        {
            size_t      len;
            const char* conninfo = luaL_checklstring(L, 1, &len);
            if (strlen(conninfo) != len)
                luaL_argerror(L, 1, "connection string contains a NUL byte");
            ConnectOptions options;
            if (!lua_isnoneornil(L, 2))
            {
                luaL_checktype(L, 2, LUA_TTABLE);
                ReadOptions(L, 2, options);
            }
            char resourceName[64] = "unknown";
            g_module->Manager()->GetResourceName(L, resourceName, sizeof(resourceName));
            resourceName[sizeof(resourceName) - 1] = '\0';

            Error     err;
            uint64_t  id = 0;
            const int rc = OpenPool(L, conninfo, options, resourceName, id, err);
            if (rc == kRaise)
                return luaL_error(L, "%s", err.text);
            if (rc == kFail)
                return PushFailure(L, err.text);

            auto* handle = static_cast<ConnHandle*>(lua_newuserdata(L, sizeof(ConnHandle)));
            handle->magic = kConnMagic;
            handle->poolId = id;
            lua_getfield(L, LUA_REGISTRYINDEX, kConnMeta);
            lua_setmetatable(L, -2);
            return 1;
        }

        // pgClose(conn) -> true if it was open
        int l_pgClose(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            bool           closed = false;
            try
            {
                closed = g_module->FindPoolFor(L, poolId) && g_module->ClosePool(poolId);
            }
            catch (const std::exception&)
            {
            }
            lua_pushboolean(L, closed);
            return 1;
        }

        // pgStats(conn) -> table | false, err
        int l_pgStats(lua_State* L)
        {
            const uint64_t poolId = CheckConn(L, 1);
            PoolEntry*     entry = g_module->FindPoolFor(L, poolId);
            if (!entry)
                return PushFailure(L, "connection is closed");
            const PoolStats s = entry->pool->Stats();
            const int       size = entry->pool->Config().size;
            lua_createtable(L, 0, 12);
            auto field = [L](const char* name, double v) {
                lua_pushnumber(L, v);
                lua_setfield(L, -2, name);
            };
            field("poolSize", size);
            field("connected", s.connected);
            field("queued", static_cast<double>(s.queued));
            field("inFlight", static_cast<double>(s.inFlight));
            field("outstanding", static_cast<double>(s.outstanding));
            field("submitted", static_cast<double>(s.submitted));
            field("succeeded", static_cast<double>(s.succeeded));
            field("failed", static_cast<double>(s.failed));
            field("reconnects", static_cast<double>(s.reconnects));
            field("roundTrips", static_cast<double>(s.roundTrips));
            field("avgLatencyMs", s.avgLatencyMs);
            return 1;
        }

        // pgQuoteIdent(name) -> "\"name\"" (for dynamic table/column names)
        int l_pgQuoteIdent(lua_State* L)
        {
            size_t      len;
            const char* s = luaL_checklstring(L, 1, &len);
            if (strlen(s) != len)
                luaL_argerror(L, 1, "identifier contains a NUL byte");
            std::string quoted;
            bool        oom = false;
            try
            {
                quoted.reserve(len + 2);
                quoted.push_back('"');
                for (size_t i = 0; i < len; ++i)
                {
                    if (s[i] == '"')
                        quoted.push_back('"');
                    quoted.push_back(s[i]);
                }
                quoted.push_back('"');
            }
            catch (const std::exception&)
            {
                oom = true;
            }
            if (oom)
            {
                std::string().swap(quoted);
                return luaL_error(L, "pgQuoteIdent: out of memory");
            }
            lua_pushlstring(L, quoted.data(), quoted.size());
            return 1;
        }

        // pgBytea(binary) -> "\x..." text that a bytea parameter accepts
        int l_pgBytea(lua_State* L)
        {
            size_t      len;
            const char* s = luaL_checklstring(L, 1, &len);
            static const char kHex[] = "0123456789abcdef";
            std::string       out;
            bool              oom = false;
            try
            {
                out.resize(2 + len * 2);
                out[0] = '\\';
                out[1] = 'x';
                for (size_t i = 0; i < len; ++i)
                {
                    const auto c = static_cast<unsigned char>(s[i]);
                    out[2 + i * 2] = kHex[c >> 4];
                    out[3 + i * 2] = kHex[c & 15];
                }
            }
            catch (const std::exception&)
            {
                oom = true;
            }
            if (oom)
            {
                std::string().swap(out);
                return luaL_error(L, "pgBytea: out of memory");
            }
            lua_pushlstring(L, out.data(), out.size());
            return 1;
        }

        // pgVersion() -> moduleVersion, libpqVersion, tlsLibrary ("OpenSSL", or nil when built
        // without TLS support)
        int l_pgVersion(lua_State* L)
        {
            lua_pushstring(L, MLPG_VERSION_STRING);
            lua_pushnumber(L, PQlibVersion());
            const char* tls = PQsslAttribute(nullptr, "library");
            if (tls)
                lua_pushstring(L, tls);
            else
                lua_pushnil(L);
            return 3;
        }

        int l_connGc(lua_State* L)
        {
            const ConnHandle* handle = ToConn(L, 1);
            if (handle && g_module && g_module->FindPoolFor(L, handle->poolId))
            {
                try
                {
                    g_module->ClosePool(handle->poolId);
                }
                catch (const std::exception&)
                {
                }
            }
            return 0;
        }

        int l_connToString(lua_State* L)
        {
            const ConnHandle* handle = ToConn(L, 1);
            char              text[64];
            if (handle)
                snprintf(text, sizeof(text), "pgsql-connection #%llu%s", static_cast<unsigned long long>(handle->poolId),
                         g_module && g_module->FindPoolFor(L, handle->poolId) ? "" : " (closed)");
            else
                snprintf(text, sizeof(text), "pgsql-connection");
            lua_pushstring(L, text);
            return 1;
        }

        // Finalizer of the per-VM sentinel: runs inside lua_close, including when MTA destroys
        // a VM without calling ResourceStopped.
        int l_vmSentinelGc(lua_State* L)
        {
            if (g_module)
                g_module->VmClosing(L);
            return 0;
        }

        // Scripts may keep references to module functions (`local q = pgQuery`). The module
        // is linked with -z nodelete, so after unloadmodule the code stays mapped and such
        // a call ends here with an error instead of jumping into unmapped memory.
        template <lua_CFunction F>
        int Guarded(lua_State* L)
        {
            if (!g_module)
                return luaL_error(L, "the ml_pgsql module is not loaded");
            return F(L);
        }

        // Globals and methods share the same function pointers, so MTA's ACL names
        // (function.pgQuery, ...) apply to both.
        const luaL_Reg kFunctions[] = {
            {"pgConnect", Guarded<l_pgConnect>},
            {"pgClose", Guarded<l_pgClose>},
            {"pgQuery", Guarded<l_pgQuery>},
            {"pgQueryAwait", Guarded<l_pgQueryAwait>},
            {"pgQuerySync", Guarded<l_pgQuerySync>},
            {"pgExec", Guarded<l_pgExec>},
            {"pgTransaction", Guarded<l_pgTransaction>},
            {"pgTransactionAwait", Guarded<l_pgTransactionAwait>},
            {"pgTransactionSync", Guarded<l_pgTransactionSync>},
            {"pgStats", Guarded<l_pgStats>},
            {"pgQuoteIdent", Guarded<l_pgQuoteIdent>},
            {"pgBytea", Guarded<l_pgBytea>},
            {"pgVersion", Guarded<l_pgVersion>},
        };

        const luaL_Reg kMethods[] = {
            {"query", Guarded<l_pgQuery>},
            {"queryAwait", Guarded<l_pgQueryAwait>},
            {"querySync", Guarded<l_pgQuerySync>},
            {"exec", Guarded<l_pgExec>},
            {"transaction", Guarded<l_pgTransaction>},
            {"transactionAwait", Guarded<l_pgTransactionAwait>},
            {"transactionSync", Guarded<l_pgTransactionSync>},
            {"stats", Guarded<l_pgStats>},
            {"close", Guarded<l_pgClose>},
        };
    }

    void RegisterBindings(lua_State* L)
    {
        for (const luaL_Reg& f : kFunctions)
            g_module->Manager()->RegisterFunction(L, f.name, f.func);

        if (!lua_checkstack(L, 6))
            return;
        luaL_newmetatable(L, kConnMeta);  // reuses an existing one
        lua_createtable(L, 0, static_cast<int>(sizeof(kMethods) / sizeof(kMethods[0])));
        for (const luaL_Reg& m : kMethods)
        {
            lua_pushcclosure(L, m.func, 0);
            lua_setfield(L, -2, m.name);
        }
        lua_setfield(L, -2, "__index");
        lua_pushcclosure(L, l_connGc, 0);
        lua_setfield(L, -2, "__gc");
        lua_pushcclosure(L, l_connToString, 0);
        lua_setfield(L, -2, "__tostring");
        lua_pushstring(L, kConnMeta);
        lua_setfield(L, -2, "__metatable");  // getmetatable() returns this string; scripts cannot swap __gc
        lua_pop(L, 1);

        lua_pushlightuserdata(L, NullSentinel());
        lua_setfield(L, LUA_GLOBALSINDEX, "PG_NULL");

        // registry[&g_vmSentinelKey] = userdata whose __gc reports the VM's destruction
        lua_pushlightuserdata(L, &g_vmSentinelKey);
        lua_newuserdata(L, 1);
        lua_createtable(L, 0, 1);
        lua_pushcclosure(L, l_vmSentinelGc, 0);
        lua_setfield(L, -2, "__gc");
        lua_setmetatable(L, -2);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }

    void UnregisterBindings(lua_State* L)
    {
        if (!lua_checkstack(L, 4))
            return;
        lua_getfield(L, LUA_REGISTRYINDEX, kConnMeta);
        if (lua_type(L, -1) == LUA_TTABLE)
        {
            for (const char* key : {"__index", "__gc", "__tostring"})
            {
                lua_pushstring(L, key);
                lua_pushnil(L);
                lua_rawset(L, -3);
            }
        }
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_setfield(L, LUA_REGISTRYINDEX, kConnMeta);
        lua_pushnil(L);
        lua_setfield(L, LUA_GLOBALSINDEX, "PG_NULL");

        // Disarm and drop the VM sentinel; a reload installs a new one.
        lua_pushlightuserdata(L, &g_vmSentinelKey);
        lua_rawget(L, LUA_REGISTRYINDEX);
        if (lua_getmetatable(L, -1))
        {
            lua_pushstring(L, "__gc");
            lua_pushnil(L);
            lua_rawset(L, -3);
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
        lua_pushlightuserdata(L, &g_vmSentinelKey);
        lua_pushnil(L);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }
}
