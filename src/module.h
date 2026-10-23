#pragma once

#include "lua_api.h"
#include "pool.h"
#include "sdk/ILuaModuleManager.h"

#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#define MLPG_MODULE_NAME    "PostgreSQL (ml_pgsql)"
#define MLPG_MODULE_AUTHOR  "ml_pgsql contributors"
#define MLPG_MODULE_VERSION 1.00f
#define MLPG_VERSION_STRING "1.0.0"

namespace mlpg
{
    // Per resource VM. Only ever touched on the main thread; jobs carry a shared_ptr so a
    // late completion can see that its VM is gone.
    struct VmState
    {
        lua_State*            L = nullptr;  // main state of the VM
        bool                  alive = true;
        std::string           resource;     // owning resource, for liveness checks
        uint64_t              verifiedPulse = 0;

        // pgExec failure reports are rate-limited per VM
        Clock::time_point reportWindow{};
        int               reportsInWindow = 0;
        int               suppressedReports = 0;
        std::vector<uint64_t> pools;        // pools opened by this VM, closed when it stops

        // An awaiting job lives here between lua_yield() and submission. If lua_yield()
        // raises (yield across a C boundary) the job and its coroutine ref are reclaimed on
        // the next call instead of leaking.
        JobPtr staged;
    };

    struct PoolEntry
    {
        std::shared_ptr<Pool> pool;
        const VmState*        owner = nullptr;  // identity only, never dereferenced
        int                   drainTimeoutMs = 10000;
        int                   syncTimeoutMs = 30000;
    };

    class Module
    {
    public:
        explicit Module(ILuaModuleManager10* manager);
        ~Module();

        ILuaModuleManager10* Manager() const { return m_manager; }

        // VM lifecycle
        void     RegisterVm(lua_State* L);
        void     VmStopped(lua_State* L);
        void     VmClosing(lua_State* L);  // a VM's sentinel was finalized (lua_close)
        VmState* FindVm(lua_State* L);  // accepts coroutines
        std::shared_ptr<VmState> FindVmShared(lua_State* L);

        // Pools
        uint64_t   NextPoolId() { return m_nextPoolId++; }
        uint64_t   NextJobId() { return m_nextJobId++; }
        void       AddPool(uint64_t id, PoolEntry entry, VmState* owner);
        PoolEntry* FindPool(uint64_t id);
        // The pool if it is open and belongs to the VM running `L` (handles are per VM; a
        // forged handle must not reach another resource's connection).
        PoolEntry* FindPoolFor(lua_State* L, uint64_t id);
        bool       ClosePool(uint64_t id);                       // graceful, never blocks
        void       DiscardPool(std::shared_ptr<Pool> pool);      // abort and reap in the background

        // Blocking wait used by the *Sync functions. Other completions are kept for DoPulse.
        JobPtr WaitForJob(uint64_t id, int timeoutMs);
        // Completes a job without running it (e.g. it could not be submitted).
        void CompleteNow(JobPtr job) { m_completions.Push(std::move(job)); }

        CompletionQueue& Completions() { return m_completions; }

        void Pulse();
        void Shutdown();

        // Reports to the resource's debug output (outputDebugString), falling back to the
        // server console. level: 1 error, 2 warning, 3 info.
        void Report(VmState& vm, int level, const std::string& message);

    private:
        void Dispatch(JobPtr job);
        void DeliverCallback(VmState& vm, Job& job);
        void DeliverAwait(VmState& vm, Job& job);
        void ReleaseRef(Job& job);
        bool CheckVm(VmState& vm);
        bool ResourceOwnsVm(const VmState& vm);
        void RetireVm(const std::shared_ptr<VmState>& vm);
        void SweepVms();
        void ReapClosingPools(bool shuttingDown);

        struct ClosingPool
        {
            std::shared_ptr<Pool> pool;
            Clock::time_point     deadline;
        };

        ILuaModuleManager10* m_manager;
        CompletionQueue      m_completions;
        std::deque<JobPtr>   m_pending;  // completed, not yet delivered (pulse budget / sync waits)

        std::unordered_map<lua_State*, std::shared_ptr<VmState>> m_vms;
        std::unordered_map<uint64_t, PoolEntry>                  m_pools;
        std::vector<ClosingPool>                                 m_closing;

        uint64_t          m_nextPoolId = 1;
        uint64_t          m_nextJobId = 1;
        uint64_t          m_pulse = 1;
        Clock::time_point m_lastSweep{};
    };

    extern Module* g_module;

    // bindings.cpp
    void RegisterBindings(lua_State* L);
    void UnregisterBindings(lua_State* L);  // removes metatable hooks before the module unloads
}
