#include "module.h"

#include "convert.h"

#include <algorithm>
#include <cstring>
#include <exception>
#include <thread>

#define MTAEXPORT extern "C" __attribute__((visibility("default")))

static_assert(LUA_NOREF == -2, "Job::ref default assumes LUA_NOREF == -2");

namespace mlpg
{
    Module* g_module = nullptr;

    namespace
    {
        // Upper bound for delivering results in one server frame; the rest waits a frame.
        constexpr auto kPulseBudget = std::chrono::milliseconds(20);
        constexpr int  kMaxExecReportsPerSecond = 20;

        // MTA's "infinite running script" watchdog is an instruction-count hook that adds
        // up to 500 ms per firing to a timer which only MTA's own call dispatch resets.
        // Re-arming the countdown before running a callback means a light callback never
        // receives a firing that earlier code "paid for"; heavy loops are still caught.
        void RearmInstructionHook(lua_State* L)
        {
            if (lua_Hook hook = lua_gethook(L))
                lua_sethook(L, hook, lua_gethookmask(L), lua_gethookcount(L));
        }
    }

    Module::Module(ILuaModuleManager10* manager) : m_manager(manager) {}

    Module::~Module() = default;

    void Module::RegisterVm(lua_State* L)
    {
        lua_State* main = lua_getmainstate(L);

        // RegisterFunctions runs once per new VM. An existing entry for this address
        // belongs to a VM that MTA destroyed without ResourceStopped (failed resource
        // start) and whose memory was reused: retire it so its jobs are dropped.
        auto it = m_vms.find(main);
        if (it != m_vms.end())
            RetireVm(std::shared_ptr<VmState>(it->second));

        auto vm = std::make_shared<VmState>();
        vm->L = main;
        char name[256];
        if (m_manager->GetResourceName(main, name, sizeof(name)))
        {
            name[sizeof(name) - 1] = '\0';
            vm->resource = name;
        }
        m_vms[main] = vm;
        RegisterBindings(main);
    }

    void Module::VmStopped(lua_State* L)
    {
        auto it = m_vms.find(lua_getmainstate(L));
        if (it != m_vms.end())
            RetireVm(std::shared_ptr<VmState>(it->second));
    }

    void Module::VmClosing(lua_State* L)
    {
        // Called from inside lua_close, possibly without ResourceStopped ever running (MTA
        // destroys the VM of a resource whose start was aborted). Only our own state is
        // touched here.
        auto it = m_vms.find(lua_getmainstate(L));
        if (it != m_vms.end())
            RetireVm(std::shared_ptr<VmState>(it->second));
    }

    void Module::RetireVm(const std::shared_ptr<VmState>& vm)
    {
        auto it = m_vms.find(vm->L);
        if (it != m_vms.end() && it->second == vm)
            m_vms.erase(it);

        // The VM (and with it every registry ref we hold) is gone or about to be. Queries
        // it queued (e.g. saves in onResourceStop) still run: pools drain in the background.
        vm->alive = false;
        vm->staged.reset();
        const std::vector<uint64_t> pools = std::move(vm->pools);
        vm->pools.clear();
        for (uint64_t id : pools)
            ClosePool(id);
    }

    // True if the VM's resource still runs this exact VM. Never dereferences vm.L, which
    // may be dangling: MTA destroys the VM of a resource that fails to start without
    // calling ResourceStopped.
    bool Module::ResourceOwnsVm(const VmState& vm)
    {
        if (vm.resource.empty())
            return true;  // name unknown at registration; cannot verify
        return m_manager->GetResourceFromName(vm.resource.c_str()) == vm.L;
    }

    bool Module::CheckVm(VmState& vm)
    {
        if (!vm.alive)
            return false;
        if (vm.verifiedPulse == m_pulse)
            return true;
        if (!ResourceOwnsVm(vm))
        {
            auto it = m_vms.find(vm.L);
            std::shared_ptr<VmState> keep = (it != m_vms.end() && it->second.get() == &vm) ? it->second : nullptr;
            if (keep)
                RetireVm(keep);
            else
                vm.alive = false;
            return false;
        }
        vm.verifiedPulse = m_pulse;
        return true;
    }

    void Module::SweepVms()
    {
        std::vector<std::shared_ptr<VmState>> dead;
        for (auto& [L, vm] : m_vms)
            if (!ResourceOwnsVm(*vm))
                dead.push_back(vm);
        for (auto& vm : dead)
            RetireVm(vm);
    }

    VmState* Module::FindVm(lua_State* L)
    {
        return FindVmShared(L).get();
    }

    std::shared_ptr<VmState> Module::FindVmShared(lua_State* L)
    {
        lua_State* main = lua_getmainstate(L);
        auto&      vm = m_vms[main];
        if (!vm)
        {
            // Should not happen (RegisterFunctions runs first), but never hand out null.
            vm = std::make_shared<VmState>();
            vm->L = main;
        }
        return vm;
    }

    void Module::AddPool(uint64_t id, PoolEntry entry, VmState* owner)
    {
        entry.owner = owner;
        m_pools.emplace(id, std::move(entry));
        if (owner)
            owner->pools.push_back(id);
    }

    PoolEntry* Module::FindPool(uint64_t id)
    {
        auto it = m_pools.find(id);
        return it == m_pools.end() ? nullptr : &it->second;
    }

    PoolEntry* Module::FindPoolFor(lua_State* L, uint64_t id)
    {
        PoolEntry* entry = FindPool(id);
        if (!entry)
            return nullptr;
        auto it = m_vms.find(lua_getmainstate(L));
        if (it == m_vms.end() || it->second.get() != entry->owner)
            return nullptr;
        return entry;
    }

    bool Module::ClosePool(uint64_t id)
    {
        auto it = m_pools.find(id);
        if (it == m_pools.end())
            return false;
        PoolEntry entry = std::move(it->second);
        m_pools.erase(it);

        for (auto& [L, vm] : m_vms)
        {
            auto& owned = vm->pools;
            owned.erase(std::remove(owned.begin(), owned.end(), id), owned.end());
        }

        entry.pool->Close();
        m_closing.push_back({std::move(entry.pool), Clock::now() + std::chrono::milliseconds(entry.drainTimeoutMs)});
        return true;
    }

    void Module::DiscardPool(std::shared_ptr<Pool> pool)
    {
        pool->Abort();
        m_closing.push_back({std::move(pool), Clock::now()});
    }

    JobPtr Module::WaitForJob(uint64_t id, int timeoutMs)
    {
        std::vector<JobPtr> stash;
        JobPtr              job = m_completions.WaitFor(id, std::chrono::milliseconds(timeoutMs), stash);
        for (auto& other : stash)
            m_pending.push_back(std::move(other));
        return job;
    }

    void Module::Pulse()
    {
        ++m_pulse;
        const auto now = Clock::now();
        if (now - m_lastSweep > std::chrono::seconds(1))
        {
            m_lastSweep = now;
            SweepVms();
        }

        if (m_pending.empty() && !m_completions.HasItems() && m_closing.empty())
            return;

        if (m_completions.HasItems())
        {
            std::vector<JobPtr> fresh;
            m_completions.TakeAll(fresh);
            for (auto& job : fresh)
                m_pending.push_back(std::move(job));
        }

        // A single large result can take milliseconds to convert, so the budget is checked
        // after every delivery (a steady_clock read is a few nanoseconds).
        const auto start = Clock::now();
        while (!m_pending.empty())
        {
            // Pop before dispatching: callbacks may re-enter (pgQuerySync appends here).
            JobPtr job = std::move(m_pending.front());
            m_pending.pop_front();
            Dispatch(std::move(job));
            if (Clock::now() - start > kPulseBudget)
                break;
        }

        ReapClosingPools(false);
    }

    void Module::Dispatch(JobPtr job)
    {
        VmState* vm = job->vm.get();
        if (!vm || !CheckVm(*vm))
            return;  // the VM is gone and took its registry refs with it

        try
        {
            switch (job->delivery)
            {
                case Delivery::Callback:
                    DeliverCallback(*vm, *job);
                    break;
                case Delivery::Await:
                    DeliverAwait(*vm, *job);
                    break;
                case Delivery::Exec:
                    if (!job->ok)
                    {
                        // A flood of failing writes must not turn into a flood of console output.
                        const auto now = Clock::now();
                        if (now - vm->reportWindow >= std::chrono::seconds(1))
                        {
                            if (vm->suppressedReports > 0)
                                Report(*vm, 2, "pgExec: " + std::to_string(vm->suppressedReports) + " more failure(s) were not shown");
                            vm->reportWindow = now;
                            vm->reportsInWindow = 0;
                            vm->suppressedReports = 0;
                        }
                        if (++vm->reportsInWindow > kMaxExecReportsPerSecond)
                        {
                            ++vm->suppressedReports;
                            break;
                        }
                        std::string message = "pgExec failed: " + job->error;
                        if (job->sqlstate[0])
                            message += std::string(" [") + job->sqlstate + "]";
                        if (job->where[0])
                            message += std::string(" (called at ") + job->where + ")";
                        Report(*vm, 2, message);
                    }
                    break;
                case Delivery::Sync:
                    break;  // its caller timed out and returned already
            }
        }
        catch (const std::exception& e)
        {
            m_manager->ErrorPrintf("[ml_pgsql] failed to deliver a result: %s\n", e.what());
        }
    }

    void Module::DeliverCallback(VmState& vm, Job& job)
    {
        lua_State* L = vm.L;
        const int  top = lua_gettop(L);
        if (!lua_checkstack(L, 8))
            return;  // leaves the ref: harmless, dies with the VM

        lua_rawgeti(L, LUA_REGISTRYINDEX, job.ref);
        luaL_unref(L, LUA_REGISTRYINDEX, job.ref);
        job.ref = LUA_NOREF;
        if (lua_type(L, -1) != LUA_TFUNCTION)
        {
            lua_settop(L, top);
            return;
        }

        const int nargs = PushOutcome(L, job);
        job.stmts.clear();  // results are now Lua values; free the PGresults before running Lua
        RearmInstructionHook(L);
        if (lua_pcall(L, nargs, 0, 0) != 0)
        {
            const char* error = lua_tostring(L, -1);
            std::string message = std::string("error in pgsql callback: ") + (error ? error : "(error object is not a string)");
            lua_settop(L, top);
            Report(vm, 1, message);
        }
        lua_settop(L, top);
    }

    void Module::DeliverAwait(VmState& vm, Job& job)
    {
        lua_State* L = vm.L;
        const int  top = lua_gettop(L);
        if (!lua_checkstack(L, 4))
            return;

        lua_rawgeti(L, LUA_REGISTRYINDEX, job.ref);  // keeps the coroutine alive while we work
        luaL_unref(L, LUA_REGISTRYINDEX, job.ref);
        job.ref = LUA_NOREF;

        lua_State* co = lua_tothread(L, -1);
        // Only resume what is still suspended; a script may have resumed or killed it.
        if (co && lua_status(co) == LUA_YIELD && lua_checkstack(co, 8))
        {
            // Build the values on the main state and move them over (lua_xmove does not
            // allocate): allocating on the suspended coroutine can run __gc finalizers on it,
            // after which luaD_poscall resets its base to the yielded C frame.
            if (!lua_checkstack(L, 8))
            {
                lua_settop(L, top);
                return;
            }
            const int nargs = PushOutcome(L, job);
            if (!lua_checkstack(co, nargs))
            {
                lua_settop(L, top);
                return;
            }
            lua_xmove(L, co, nargs);
            job.stmts.clear();
            RearmInstructionHook(co);
            const int rc = lua_resume(co, nargs);
            if (rc == 0 || rc == LUA_YIELD)
                lua_settop(co, 0);  // drop returned / yielded values nobody will read
            else
            {
                const char* error = lua_tostring(co, -1);
                std::string message = std::string("error in coroutine resumed by pgsql: ") + (error ? error : "(error object is not a string)");
                lua_settop(co, 0);
                lua_settop(L, top);
                Report(vm, 1, message);
            }
        }
        lua_settop(L, top);
    }

    void Module::Report(VmState& vm, int level, const std::string& message)
    {
        lua_State* L = vm.L;
        const int  top = lua_gettop(L);
        if (lua_checkstack(L, 4))
        {
            lua_pushstring(L, "outputDebugString");
            lua_rawget(L, LUA_GLOBALSINDEX);
            if (lua_type(L, -1) == LUA_TFUNCTION)
            {
                lua_pushlstring(L, message.data(), message.size());
                lua_pushnumber(L, level);
                const int rc = lua_pcall(L, 2, 0, 0);
                lua_settop(L, top);
                if (rc == 0)
                    return;
            }
        }
        lua_settop(L, top);
        m_manager->ErrorPrintf("[ml_pgsql] %s\n", message.c_str());
    }

    void Module::ReleaseRef(Job& job)
    {
        if (job.ref != LUA_NOREF && job.vm && job.vm->alive)
            luaL_unref(job.vm->L, LUA_REGISTRYINDEX, job.ref);
        job.ref = LUA_NOREF;
    }

    void Module::ReapClosingPools(bool shuttingDown)
    {
        const auto now = Clock::now();
        for (size_t i = 0; i < m_closing.size();)
        {
            ClosingPool& closing = m_closing[i];
            if (closing.pool->AllWorkersExited())
            {
                closing.pool->Join();
                m_closing.erase(m_closing.begin() + static_cast<std::ptrdiff_t>(i));
                continue;
            }
            if (!closing.pool->IsAborting() && now >= closing.deadline)
            {
                if (shuttingDown)
                    m_manager->Printf("[ml_pgsql] drain timeout reached, canceling remaining queries\n");
                closing.pool->Abort();
            }
            ++i;
        }
    }

    void Module::Shutdown()
    {
        // Let queued work (e.g. saves issued in onResourceStop) finish, bounded by each
        // connection's drainTimeout, then cancel what is left. Worker threads must be gone
        // before the module is unmapped, so this blocks.
        std::vector<uint64_t> ids;
        for (const auto& [id, entry] : m_pools)
            ids.push_back(id);
        for (uint64_t id : ids)
            ClosePool(id);

        auto lastNotice = Clock::now();
        while (!m_closing.empty())
        {
            ReapClosingPools(true);
            if (m_closing.empty())
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            if (Clock::now() - lastNotice > std::chrono::seconds(5))
            {
                m_manager->Printf("[ml_pgsql] waiting for %zu connection pool(s) to finish...\n", m_closing.size());
                lastNotice = Clock::now();
            }
        }

        // Resources that keep running (unloadmodule/reloadmodule) must not keep refs or
        // metatables pointing at module code. Liveness comes from our own bookkeeping
        // (stop hooks and the per-VM sentinel): during server shutdown MTA has already
        // deleted its resource manager, so it cannot be asked.

        std::vector<JobPtr> leftovers;
        m_completions.TakeAll(leftovers);
        for (auto& job : m_pending)
            leftovers.push_back(std::move(job));
        m_pending.clear();
        for (auto& job : leftovers)
            ReleaseRef(*job);

        for (auto& [L, vm] : m_vms)
        {
            if (vm->staged)
                ReleaseRef(*vm->staged);
            vm->staged.reset();
            if (vm->alive)
                UnregisterBindings(L);
            vm->alive = false;
        }
        m_vms.clear();
    }
}

using mlpg::g_module;

MTAEXPORT bool InitModule(ILuaModuleManager10* pManager, char* szModuleName, char* szAuthor, float* fVersion)
{
    if (!pManager)
        return false;
    try
    {
        // The vtable lives in the library that implements the module manager (deathmatch.so),
        // which is also where the server's Lua is.
        const void* anchor = *reinterpret_cast<void* const*>(pManager);
        std::string error;
        if (!mlpg::ResolveLuaApi(anchor, error))
        {
            pManager->ErrorPrintf("[ml_pgsql] %s\n", error.c_str());
            return false;
        }
        if (!PQisthreadsafe())
        {
            pManager->ErrorPrintf("[ml_pgsql] libpq was built without thread safety\n");
            return false;
        }

        strncpy(szModuleName, MLPG_MODULE_NAME, MAX_INFO_LENGTH - 1);
        szModuleName[MAX_INFO_LENGTH - 1] = '\0';
        strncpy(szAuthor, MLPG_MODULE_AUTHOR, MAX_INFO_LENGTH - 1);
        szAuthor[MAX_INFO_LENGTH - 1] = '\0';
        *fVersion = MLPG_MODULE_VERSION;

        delete g_module;
        g_module = new mlpg::Module(pManager);
        return true;
    }
    catch (const std::exception& e)
    {
        pManager->ErrorPrintf("[ml_pgsql] initialization failed: %s\n", e.what());
        return false;
    }
}

MTAEXPORT void RegisterFunctions(lua_State* luaVM)
{
    if (!g_module || !luaVM)
        return;
    try
    {
        g_module->RegisterVm(luaVM);
    }
    catch (const std::exception& e)
    {
        g_module->Manager()->ErrorPrintf("[ml_pgsql] RegisterFunctions failed: %s\n", e.what());
    }
}

MTAEXPORT bool DoPulse()
{
    if (!g_module)
        return true;
    try
    {
        g_module->Pulse();
    }
    catch (const std::exception& e)
    {
        g_module->Manager()->ErrorPrintf("[ml_pgsql] DoPulse failed: %s\n", e.what());
    }
    return true;
}

MTAEXPORT bool ShutdownModule()
{
    if (!g_module)
        return true;
    try
    {
        g_module->Shutdown();
    }
    catch (const std::exception& e)
    {
        g_module->Manager()->ErrorPrintf("[ml_pgsql] shutdown failed: %s\n", e.what());
    }
    delete g_module;
    g_module = nullptr;
    mlpg::ShutdownConversion();
    return true;
}

MTAEXPORT void ResourceStopping(lua_State*)
{
    // Nothing to do: onResourceStop runs after this and may still queue queries.
}

MTAEXPORT void ResourceStopped(lua_State* luaVM)
{
    if (!g_module || !luaVM)
        return;
    try
    {
        g_module->VmStopped(luaVM);
    }
    catch (const std::exception& e)
    {
        g_module->Manager()->ErrorPrintf("[ml_pgsql] ResourceStopped failed: %s\n", e.what());
    }
}
