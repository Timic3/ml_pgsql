// fakehost: a stand-in for MTA:SA's deathmatch.so, as far as Lua modules can tell.
//
// Mirrors the server code paths that matter to a module (mtasa-blue, Server/mods/deathmatch):
//   - Lua lives in this library (MTA's Lua 5.1, compiled as C: errors are _longjmp), which the
//     executable dlopen()s RTLD_LOCAL. Modules are dlopen()ed RTLD_NOW from here, so Lua
//     symbols are not in the global scope (CLuaModule::_LoadModule).
//   - One ILuaModuleManager10 instance per loaded module (CLuaModule); RegisterFunction is
//     lua_register; GetResourceName/GetResourceFromName resolve through the live VM map.
//   - Resource start (CResource::Start/CreateVM): new VM with mtasaowner, base libs, security
//     restrictions, host functions, embedded script (prelude), module RegisterFunctions, then
//     the resource's script files. A script that fails to *load* aborts the start and the VM is
//     destroyed WITHOUT ResourceStopping/ResourceStopped (CResource::Start abort path).
//   - Resource stop (CResource::Stop): ResourceStopping -> onStop() -> ResourceStopped (and
//     the module's globals are set to nil, CLuaModule::_ResourceStopped) -> timers removed ->
//     lua_close (__gc metamethods run while the resource still resolves).
//   - Frame: timers of every VM, then module DoPulse (CLuaManager::DoPulse), then queued
//     resource/console commands (stopResource is queued in MTA; startResource is immediate).
//   - unloadmodule/reloadmodule: ShutdownModule, globals set to nil in every VM, manager
//     deleted, dlclose; (re)load = dlopen + InitModule + RegisterFunctions for every live VM.
//   - Server shutdown: all resources stopped, then ShutdownModule + dlclose.
//   - lua_registerPreCallHook: C calls into a VM whose resource is not starting/running/
//     stopping are blocked (CLuaDefs::CanUseFunction).

extern "C"
{
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

#include "ILuaModuleManager.h"
#include "proxy.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <dirent.h>
#include <dlfcn.h>
#include <unistd.h>

extern "C" int __lsan_do_recoverable_leak_check() __attribute__((weak));

namespace host
{
    // ------------------------------------------------------------------------------------
    // basics
    // ------------------------------------------------------------------------------------

    using Clock = std::chrono::steady_clock;
    const Clock::time_point g_t0 = Clock::now();

    double NowMs() { return std::chrono::duration<double, std::milli>(Clock::now() - g_t0).count(); }

    std::mutex g_outMutex;

    void Out(FILE* f, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    void Out(FILE* f, const char* fmt, ...)
    {
        std::lock_guard<std::mutex> lock(g_outMutex);
        fprintf(f, "[%9.1f] ", NowMs());
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fflush(f);
    }

    struct Config
    {
        std::string modulePath;
        std::string scenarioPath;
        std::string scenarioDir;
        std::string preludePath;
        double      timeoutSec = 600;
        std::string variant = "plain";
        double      slowdown = 1;
        double      scale = 1;
    } g_cfg;

    int                      g_failures = 0;
    int                      g_hostErrors = 0;
    std::vector<std::string> g_failureLog;
    uint64_t                 g_frame = 0;
    std::atomic<int>         g_phase{0};  // for the watchdog: 0 run, 1 shutdown

    void Fail(const std::string& message)
    {
        ++g_failures;
        g_failureLog.push_back(message);
        Out(stderr, "HARNESS FAIL: %s\n", message.c_str());
    }

    void HostError(const std::string& where, const std::string& message)
    {
        ++g_hostErrors;
        g_failureLog.push_back(where + ": " + message);
        Out(stderr, "HOST ERROR (%s): %s\n", where.c_str(), message.c_str());
    }

    struct DebugMessage
    {
        int         id;
        std::string resource;
        int         level;
        std::string text;
        bool        consumed = false;
    };
    std::vector<DebugMessage> g_debug;
    int                       g_nextDebugId = 1;

    std::mutex               g_consoleMutex;
    std::vector<std::string> g_console;  // Printf/ErrorPrintf output of modules

    // ------------------------------------------------------------------------------------
    // resources and VMs
    // ------------------------------------------------------------------------------------

    enum class RState
    {
        Loaded,    // not running (never started / stopped / failed)
        Starting,
        Running,
        Stopping,
    };

    const char* StateName(RState s)
    {
        switch (s)
        {
            case RState::Loaded: return "loaded";
            case RState::Starting: return "starting";
            case RState::Running: return "running";
            case RState::Stopping: return "stopping";
        }
        return "?";
    }

    struct Timer
    {
        int              fnRef = LUA_NOREF;
        std::vector<int> argRefs;
        double           interval = 0;
        int              remaining = 1;  // 0 = infinite
        double           due = 0;
    };

    struct Resource
    {
        std::string              name;
        std::vector<std::string> files;
        lua_State*               L = nullptr;
        RState                   state = RState::Loaded;
        uint64_t                 startSeq = 0;
        std::map<int, Timer>     timers;
        int                      starts = 0;
    };

    std::map<std::string, std::unique_ptr<Resource>> g_resources;
    std::unordered_map<lua_State*, Resource*>        g_vms;  // main state -> resource while the VM exists
    uint64_t                                         g_startSeq = 0;
    int                                              g_nextTimerId = 1;
    std::atomic<int>                                 g_blockedCalls{0};

    Resource* ResourceOf(lua_State* L)
    {
        // Like CLuaManager::GetVirtualMachine: coroutine -> main state -> map.
        auto it = g_vms.find(lua_getmainstate(L));
        return it == g_vms.end() ? nullptr : it->second;
    }

    std::vector<Resource*> ResourcesByStart(bool reverse)
    {
        std::vector<Resource*> list;
        for (auto& [name, r] : g_resources)
            if (r->L)
                list.push_back(r.get());
        std::sort(list.begin(), list.end(), [&](Resource* a, Resource* b) { return reverse ? a->startSeq > b->startSeq : a->startSeq < b->startSeq; });
        return list;
    }

    // Allocator: plain realloc/free like luaL_newstate's l_alloc. For the "VM destroyed and a
    // new one allocated at the same address" scenario it can keep the main-state block of a
    // dying VM and hand it to the next VM instead of hoping malloc reuses it (ASan/valgrind
    // quarantine freed memory, so natural reuse never happens under them).
    lua_State* g_recycleState = nullptr;  // main state whose block should be kept on free
    void*      g_stashedBlock = nullptr;
    size_t     g_stashedSize = 0;
    bool       g_reuseNextState = false;

    void* HostAlloc(void*, void* ptr, size_t osize, size_t nsize)
    {
        if (nsize == 0)
        {
            if (ptr && ptr == static_cast<void*>(g_recycleState))
            {
                free(g_stashedBlock);
                g_stashedBlock = ptr;
                g_stashedSize = osize;
                g_recycleState = nullptr;
                return nullptr;
            }
            free(ptr);
            return nullptr;
        }
        if (!ptr && g_reuseNextState && g_stashedBlock && nsize == g_stashedSize)
        {
            void* p = g_stashedBlock;
            g_stashedBlock = nullptr;
            g_reuseNextState = false;
            return p;
        }
        return realloc(ptr, nsize);
    }

    int Panic(lua_State* L)
    {
        Out(stderr, "PANIC: unprotected error in call to Lua API (%s)\n", lua_tostring(L, -1));
        abort();
    }

    void CountHook(lua_State*, lua_Debug*) {}  // MTA's instruction-count hook (time check only)

    int PreCallHook(lua_CFunction, lua_State* L)
    {
        auto* r = static_cast<Resource*>(lua_getmtasaowner(L));
        if (!r)
            return 1;
        if (r->state == RState::Starting || r->state == RState::Running || r->state == RState::Stopping)
            return 1;
        g_blockedCalls.fetch_add(1);
        return 0;
    }

    // ------------------------------------------------------------------------------------
    // module manager (one instance per loaded module, like CLuaModule)
    // ------------------------------------------------------------------------------------

    struct LoadedModule;

    // Server shutdown: ~CGame deletes the resource manager before ~CLuaManager deletes the
    // module manager (which calls ShutdownModule). Resource lookups from ShutdownModule then
    // dereference destroyed objects in the real server.
    bool g_resourceManagerGone = false;

    void ResourceLookupAfterShutdown(const char* what)
    {
        Fail(std::string("module called ") + what + " during server shutdown (MTA's resource manager is already destroyed)");
    }

    class FakeManager final : public ILuaModuleManager10
    {
    public:
        explicit FakeManager(LoadedModule* module) : m_module(module) {}

        void ErrorPrintf(const char* fmt, ...) override
        {
            va_list ap;
            va_start(ap, fmt);
            Console(stderr, "ERROR: ", fmt, ap);
            va_end(ap);
        }
        void DebugPrintf(lua_State* L, const char* fmt, ...) override
        {
            char    buf[2048];
            va_list ap;
            va_start(ap, fmt);
            vsnprintf(buf, sizeof(buf), fmt, ap);
            va_end(ap);
            Resource* r = L ? ResourceOf(L) : nullptr;
            Out(stdout, "[%s] INFO: %s\n", r ? r->name.c_str() : "?", buf);
            g_debug.push_back({g_nextDebugId++, r ? r->name : "", 3, buf});
        }
        void Printf(const char* fmt, ...) override
        {
            va_list ap;
            va_start(ap, fmt);
            Console(stdout, "", fmt, ap);
            va_end(ap);
        }
        bool      RegisterFunction(lua_State* L, const char* name, lua_CFunction f) override;
        bool      GetResourceName(lua_State* L, std::string& name) override
        {
            if (!L)
                return false;
            if (g_resourceManagerGone)
            {
                ResourceLookupAfterShutdown("GetResourceName");
                return false;
            }
            Resource* r = ResourceOf(L);  // reads L like MTA does (lua_getmainstate)
            if (!r)
                return false;
            name = r->name;
            return true;
        }
        CChecksum GetResourceMetaChecksum(lua_State*) override { return CChecksum(); }
        CChecksum GetResourceFileChecksum(lua_State*, const char*) override { return CChecksum(); }

        unsigned long GetVersion() override { return 0x0106; }
        const char*   GetVersionString() override { return "1.6.0"; }
        const char*   GetVersionName() override { return "MTA:SA Server (fakehost)"; }
        unsigned long GetNetcodeVersion() override { return 0x01; }
        const char*   GetOperatingSystemName() override { return "GNU/Linux"; }

        lua_State* GetResourceFromName(const char* name) override
        {
            if (!name)
                return nullptr;
            if (g_resourceManagerGone)
            {
                ResourceLookupAfterShutdown("GetResourceFromName");
                return nullptr;
            }
            auto it = g_resources.find(name);
            return it == g_resources.end() ? nullptr : it->second->L;
        }
        bool GetResourceName(lua_State* L, char* buf, size_t length) override
        {
            std::string name;
            if (!GetResourceName(L, name))
                return false;
            std::strncpy(buf, name.c_str(), length);
            return true;
        }
        bool GetResourceFilePath(lua_State* L, const char* fileName, char* path, size_t length) override
        {
            if (!L || !fileName || !ResourceOf(L))
                return false;
            std::string p = g_cfg.scenarioDir + "/" + fileName;
            std::strncpy(path, p.c_str(), length);
            return true;
        }

    private:
        void Console(FILE* f, const char* prefix, const char* fmt, va_list ap)
        {
            char buf[4096];
            vsnprintf(buf, sizeof(buf), fmt, ap);
            {
                std::lock_guard<std::mutex> lock(g_consoleMutex);
                g_console.push_back(buf);
            }
            Out(f, "%s%s", prefix, buf);
            if (!*buf || buf[strlen(buf) - 1] != '\n')
                fputc('\n', f);
        }

        LoadedModule* m_module;
    };

    struct LoadedModule
    {
        std::string path;
        void*       handle = nullptr;
        bool (*InitModule)(ILuaModuleManager10*, char*, char*, float*) = nullptr;
        bool (*DoPulse)() = nullptr;
        bool (*ShutdownModule)() = nullptr;
        void (*RegisterFunctions)(lua_State*) = nullptr;
        void (*ResourceStopping)(lua_State*) = nullptr;
        void (*ResourceStopped)(lua_State*) = nullptr;
        char                         name[MAX_INFO_LENGTH] = {0};
        char                         author[MAX_INFO_LENGTH] = {0};
        float                        version = 0;
        std::vector<std::string>     functions;  // CLuaModule::m_Functions
        std::unique_ptr<FakeManager> manager;
    };

    std::unique_ptr<LoadedModule> g_module;
    double                        g_lastShutdownMs = -1;
    double                        g_expectShutdownWithinMs = -1;
    int                           g_moduleLoads = 0;

    bool FakeManager::RegisterFunction(lua_State* L, const char* name, lua_CFunction f)
    {
        if (L && name)
        {
            lua_register(L, name, f);
            auto& list = m_module->functions;
            if (std::find(list.begin(), list.end(), name) == list.end())
                list.push_back(name);
        }
        return true;
    }

    // ------------------------------------------------------------------------------------
    // protected calls
    // ------------------------------------------------------------------------------------

    int Traceback(lua_State* L)
    {
        if (!lua_isstring(L, 1))
            return 1;
        lua_getfield(L, LUA_GLOBALSINDEX, "debug");
        if (!lua_istable(L, -1))
        {
            lua_pop(L, 1);
            return 1;
        }
        lua_getfield(L, -1, "traceback");
        if (!lua_isfunction(L, -1))
        {
            lua_pop(L, 2);
            return 1;
        }
        lua_pushvalue(L, 1);
        lua_pushinteger(L, 2);
        lua_call(L, 2, 1);
        return 1;
    }

    // Calls the function below `nargs` arguments. Errors count as host errors.
    bool HostPCall(lua_State* L, int nargs, const std::string& what)
    {
        const int base = lua_gettop(L) - nargs;
        lua_pushcfunction(L, Traceback);
        lua_insert(L, base);
        const int rc = lua_pcall(L, nargs, 0, base);
        if (rc != 0)
        {
            const char* msg = lua_tostring(L, -1);
            HostError(what, msg ? msg : "(non-string error)");
            lua_pop(L, 1);
        }
        lua_remove(L, base);
        return rc == 0;
    }

    void CallGlobalIfPresent(Resource& r, const char* fn)
    {
        lua_State* L = r.L;
        lua_getfield(L, LUA_GLOBALSINDEX, fn);
        if (lua_isfunction(L, -1))
            HostPCall(L, 0, r.name + ":" + fn);
        else
            lua_pop(L, 1);
    }

    void GcAllVms(const char* why)
    {
        for (Resource* r : ResourcesByStart(false))
        {
            lua_gc(r->L, LUA_GCCOLLECT, 0);
            lua_gc(r->L, LUA_GCCOLLECT, 0);
        }
        Out(stdout, "host: full GC in every VM (%s)\n", why);
    }

    // ------------------------------------------------------------------------------------
    // module load/unload (CLuaModuleManager)
    // ------------------------------------------------------------------------------------

    bool LoadModule(bool lateLoad, std::string& error)
    {
        if (g_module)
        {
            error = "module already loaded";
            return false;
        }
        auto m = std::make_unique<LoadedModule>();
        m->path = g_cfg.modulePath;
        m->handle = dlopen(m->path.c_str(), RTLD_NOW);
        if (!m->handle)
        {
            error = std::string("dlopen failed: ") + dlerror();
            return false;
        }
        auto sym = [&](const char* name) { return dlsym(m->handle, name); };
        m->InitModule = reinterpret_cast<decltype(m->InitModule)>(sym("InitModule"));
        m->DoPulse = reinterpret_cast<decltype(m->DoPulse)>(sym("DoPulse"));
        m->ShutdownModule = reinterpret_cast<decltype(m->ShutdownModule)>(sym("ShutdownModule"));
        m->RegisterFunctions = reinterpret_cast<decltype(m->RegisterFunctions)>(sym("RegisterFunctions"));
        m->ResourceStopping = reinterpret_cast<decltype(m->ResourceStopping)>(sym("ResourceStopping"));
        m->ResourceStopped = reinterpret_cast<decltype(m->ResourceStopped)>(sym("ResourceStopped"));
        if (!m->InitModule || !m->DoPulse || !m->ShutdownModule || !m->RegisterFunctions)
        {
            error = "missing module entry point";
            dlclose(m->handle);
            return false;
        }
        m->manager = std::make_unique<FakeManager>(m.get());
        if (!m->InitModule(m->manager.get(), m->name, m->author, &m->version))
        {
            error = "InitModule returned false";
            m->manager.reset();
            dlclose(m->handle);
            return false;
        }
        ++g_moduleLoads;
        Out(stdout, "MODULE: Loaded \"%s\" (%.2f) by \"%s\"\n", m->name, m->version, m->author);
        g_module = std::move(m);
        if (lateLoad)
        {
            // CLuaModuleManager::LoadModule(bLateLoad): every VM in the manager's list.
            for (Resource* r : ResourcesByStart(false))
                g_module->RegisterFunctions(r->L);
        }
        return true;
    }

    // Threads named by the module that are still alive: workers are "pgsql-<pool>-<n>";
    // detached host-name resolver helpers are "mlpg-dns".
    int CountModuleThreads(const char* prefix = "pgsql-")
    {
        int  n = 0;
        DIR* d = opendir("/proc/self/task");
        if (!d)
            return -1;
        while (dirent* e = readdir(d))
        {
            if (e->d_name[0] == '.')
                continue;
            char path[128], comm[64] = {0};
            snprintf(path, sizeof(path), "/proc/self/task/%s/comm", e->d_name);
            if (FILE* f = fopen(path, "r"))
            {
                if (fgets(comm, sizeof(comm), f) && !strncmp(comm, prefix, strlen(prefix)))
                    ++n;
                fclose(f);
            }
        }
        closedir(d);
        return n;
    }

    void UnloadModule(const char* why)
    {
        if (!g_module)
            return;
        LoadedModule& m = *g_module;
        Out(stdout, "host: unloading module (%s)\n", why);
        const double t0 = NowMs();
        m.ShutdownModule();
        g_lastShutdownMs = NowMs() - t0;
        Out(stdout, "host: ShutdownModule took %.0f ms\n", g_lastShutdownMs);
        if (const int alive = CountModuleThreads(); alive > 0)
            Fail(std::to_string(alive) + " module worker thread(s) still alive after ShutdownModule (about to dlclose)");
        // Resolver helpers may still be inside getaddrinfo (a hanging DNS server). That is
        // only safe if the module stays mapped after dlclose (-z nodelete); checked below.
        const int resolvers = CountModuleThreads("mlpg-dns");
        if (resolvers > 0)
            Out(stdout, "host: %d detached resolver thread(s) still running after ShutdownModule\n", resolvers);
        if (g_expectShutdownWithinMs >= 0 && g_lastShutdownMs > g_expectShutdownWithinMs)
            Fail("ShutdownModule took " + std::to_string(static_cast<int>(g_lastShutdownMs)) + " ms, expected <= " +
                 std::to_string(static_cast<int>(g_expectShutdownWithinMs)) + " ms");

        // CLuaModule::_UnregisterFunctions: every VM, every function name
        for (Resource* r : ResourcesByStart(false))
            for (const std::string& f : m.functions)
            {
                lua_pushnil(r->L);
                lua_setglobal(r->L, f.c_str());
            }

        // Everything the module allocated must be gone now (its globals are still mapped, so
        // anything static stays reachable and is not reported).
        if (__lsan_do_recoverable_leak_check && getenv("MLPG_LEAK_CHECK_AT_UNLOAD"))
        {
            if (__lsan_do_recoverable_leak_check())
                Fail("LeakSanitizer found leaks right after ShutdownModule (before dlclose)");
        }

        void* handle = m.handle;
        const std::string path = m.path;
        g_module.reset();  // deletes the manager (CLuaModule destructor)
        if (!getenv("MLPG_KEEP_MODULE_MAPPED"))
            dlclose(handle);
        if (resolvers > 0)
        {
            if (void* still = dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD))
                dlclose(still);
            else
                Fail("module was unmapped while resolver threads were still running");
        }
        Out(stdout, "MODULE: Unloaded\n");
    }

    // ------------------------------------------------------------------------------------
    // resource lifecycle
    // ------------------------------------------------------------------------------------

    void RegisterHostApi(lua_State* L, Resource& r);

    bool ReadFile(const std::string& path, std::string& out)
    {
        std::ifstream f(path, std::ios::binary);
        if (!f)
            return false;
        std::ostringstream ss;
        ss << f.rdbuf();
        out = ss.str();
        return true;
    }

    std::string Basename(const std::string& p)
    {
        const size_t slash = p.find_last_of('/');
        return slash == std::string::npos ? p : p.substr(slash + 1);
    }

    void DestroyVm(Resource& r, const char* why)
    {
        lua_State* L = r.L;
        if (!L)
            return;
        // CLuaMain::~CLuaMain -> UnloadScript: timers removed, then lua_close (__gc runs now;
        // the resource still resolves for GetResourceName/GetResourceFromName meanwhile).
        r.timers.clear();
        lua_close(L);
        g_vms.erase(L);
        r.L = nullptr;
        r.state = RState::Loaded;
        Out(stdout, "host: VM of '%s' destroyed (%s)\n", r.name.c_str(), why);
    }

    // Copies a (tree of) plain values between VMs.
    void CopyValue(lua_State* from, int idx, lua_State* to, int depth)
    {
        if (idx < 0)
            idx = lua_gettop(from) + idx + 1;
        lua_checkstack(to, 4);
        switch (lua_type(from, idx))
        {
            case LUA_TBOOLEAN: lua_pushboolean(to, lua_toboolean(from, idx)); break;
            case LUA_TNUMBER: lua_pushnumber(to, lua_tonumber(from, idx)); break;
            case LUA_TSTRING:
            {
                size_t      len;
                const char* s = lua_tolstring(from, idx, &len);
                lua_pushlstring(to, s, len);
                break;
            }
            case LUA_TTABLE:
                if (depth > 8)
                {
                    lua_pushnil(to);
                    break;
                }
                lua_newtable(to);
                lua_pushnil(from);
                while (lua_next(from, idx))
                {
                    CopyValue(from, -2, to, depth + 1);
                    CopyValue(from, -1, to, depth + 1);
                    if (lua_isnil(to, -2))
                        lua_pop(to, 2);
                    else
                        lua_rawset(to, -3);
                    lua_pop(from, 1);
                }
                break;
            default: lua_pushnil(to); break;
        }
    }

    // CResource::Start. `argsVm/argsIdx` (optional) is copied into the new VM as global ARGS.
    bool StartResource(const std::string& name, const std::vector<std::string>& files, lua_State* argsVm, int argsIdx, bool reuseAddress,
                       std::string& error)
    {
        auto& slot = g_resources[name];
        if (!slot)
        {
            slot = std::make_unique<Resource>();
            slot->name = name;
        }
        Resource& r = *slot;
        if (r.L)
        {
            error = "resource '" + name + "' is already running";
            return false;
        }
        r.files = files;
        r.state = RState::Starting;
        r.startSeq = ++g_startSeq;
        ++r.starts;

        if (reuseAddress)
            g_reuseNextState = true;
        lua_State* L = lua_newstate(HostAlloc, nullptr, &r);  // lua_open(CLuaMain*)
        g_reuseNextState = false;
        if (!L)
        {
            error = "lua_newstate failed";
            r.state = RState::Loaded;
            return false;
        }
        lua_atpanic(L, Panic);
        r.L = L;
        g_vms[L] = &r;
        Out(stdout, "host: starting '%s' (VM %p)\n", name.c_str(), static_cast<void*>(L));

        // CLuaMain::Initialize
        lua_sethook(L, CountHook, LUA_MASKCOUNT, 1000000);
        luaopen_base(L);
        luaopen_math(L);
        luaopen_string(L);
        luaopen_table(L);
        luaopen_debug(L);
        luaopen_utf8(L);
        luaopen_os(L);
        lua_settop(L, 0);
        RegisterHostApi(L, r);
        lua_pushstring(L, name.c_str());
        lua_setglobal(L, "resourceName");
        if (argsVm)
        {
            CopyValue(argsVm, argsIdx, L, 0);
            lua_setglobal(L, "ARGS");
        }

        // LoadEmbeddedScripts
        std::string prelude;
        if (!ReadFile(g_cfg.preludePath, prelude) || luaL_loadbuffer(L, prelude.data(), prelude.size(), "@prelude.lua") != 0)
        {
            error = "cannot load prelude: " + std::string(lua_isstring(L, -1) ? lua_tostring(L, -1) : g_cfg.preludePath.c_str());
            lua_settop(L, 0);
            DestroyVm(r, "prelude failed");
            return false;
        }
        HostPCall(L, 0, name + ":prelude");

        // RegisterModuleFunctions
        if (g_module)
            g_module->RegisterFunctions(L);

        // Resource files. A script that does not compile aborts the start: the VM is destroyed
        // without ResourceStopping/ResourceStopped (CResource::Start, bAbortStart).
        for (const std::string& file : files)
        {
            const std::string path = file.size() && file[0] == '/' ? file : g_cfg.scenarioDir + "/" + file;
            std::string       code;
            if (!ReadFile(path, code))
            {
                error = "cannot read " + path;
                DestroyVm(r, "start aborted: missing file");
                return false;
            }
            const std::string chunk = "@" + name + "/" + Basename(file);
            if (luaL_loadbuffer(L, code.data(), code.size(), chunk.c_str()) != 0)
            {
                error = std::string("Loading script failed: ") + (lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
                Out(stdout, "host: %s -> aborting start of '%s'\n", error.c_str(), name.c_str());
                lua_settop(L, 0);
                DestroyVm(r, "start aborted: script failed to load (no module hooks)");
                return false;
            }
            HostPCall(L, 0, name + ":" + Basename(file));  // runtime errors are only logged
            if (!r.L)
            {
                error = "VM destroyed while loading";
                return false;
            }
        }

        r.state = RState::Running;
        CallGlobalIfPresent(r, "onStart");  // onResourceStart
        return true;
    }

    // CResource::Stop
    void StopResource(Resource& r)
    {
        if (!r.L || r.state != RState::Running)
            return;
        lua_State* L = r.L;
        Out(stdout, "host: stopping '%s'\n", r.name.c_str());
        r.state = RState::Stopping;
        if (g_module && g_module->ResourceStopping)
            g_module->ResourceStopping(L);
        CallGlobalIfPresent(r, "onStop");  // onResourceStop
        if (g_module)
        {
            if (g_module->ResourceStopped)
                g_module->ResourceStopped(L);
            for (const std::string& f : g_module->functions)  // CLuaModule::_ResourceStopped
            {
                lua_pushnil(L);
                lua_setglobal(L, f.c_str());
            }
        }
        DestroyVm(r, "stopped");
    }

    // ------------------------------------------------------------------------------------
    // queued commands (processed between frames, like CResourceManager::ProcessQueue and
    // console commands)
    // ------------------------------------------------------------------------------------

    struct Command
    {
        enum Kind
        {
            Stop,
            Destroy,  // destroy the VM without module hooks (failed-start path)
            Unload,
            Load,
            Reload,
            Done,
        } kind;
        std::string              name;
        bool                     ok = true;
        std::string              message;
        bool                     reuseAddress = false;
        std::string              thenStart;  // Destroy: start this resource right after (same frame)
        std::vector<std::string> thenFiles;
    };
    std::deque<Command> g_commands;
    bool                g_done = false;
    bool                g_doneOk = false;
    std::string         g_doneMessage;

    void ProcessCommands()
    {
        while (!g_commands.empty())
        {
            Command c = std::move(g_commands.front());
            g_commands.pop_front();
            switch (c.kind)
            {
                case Command::Stop:
                {
                    auto it = g_resources.find(c.name);
                    if (it != g_resources.end())
                        StopResource(*it->second);
                    break;
                }
                case Command::Destroy:
                {
                    auto it = g_resources.find(c.name);
                    if (it == g_resources.end() || !it->second->L)
                        break;
                    if (c.reuseAddress)
                        g_recycleState = it->second->L;
                    DestroyVm(*it->second, "destroyed without module hooks");
                    g_recycleState = nullptr;
                    if (c.reuseAddress)
                        g_reuseNextState = true;  // the next VM created (by anyone) gets the same address
                    if (!c.thenStart.empty())
                    {
                        std::string error;
                        if (!StartResource(c.thenStart, c.thenFiles, nullptr, 0, c.reuseAddress, error))
                            HostError("destroy+start", error);
                    }
                    break;
                }
                case Command::Unload:
                    UnloadModule("unloadmodule");
                    GcAllVms("after unload");
                    break;
                case Command::Load:
                {
                    GcAllVms("before load");
                    std::string error;
                    if (!LoadModule(true, error))
                        HostError("loadmodule", error);
                    break;
                }
                case Command::Reload:
                {
                    UnloadModule("reloadmodule");
                    GcAllVms("between unload and load");
                    std::string error;
                    if (!LoadModule(true, error))
                        HostError("reloadmodule", error);
                    break;
                }
                case Command::Done:
                    g_done = true;
                    g_doneOk = c.ok;
                    g_doneMessage = c.message;
                    return;
            }
        }
    }

    // ------------------------------------------------------------------------------------
    // timers (CLuaTimerManager)
    // ------------------------------------------------------------------------------------

    void RunTimers(Resource& r)
    {
        if (!r.L || r.timers.empty())
            return;
        const double     now = NowMs();
        std::vector<int> due;
        for (auto& [id, t] : r.timers)
            if (t.due <= now)
                due.push_back(id);
        for (int id : due)
        {
            if (!r.L)
                return;
            auto it = r.timers.find(id);
            if (it == r.timers.end())
                continue;
            lua_State*       L = r.L;
            Timer&           t = it->second;
            const bool       last = t.remaining == 1;
            const int        fnRef = t.fnRef;
            std::vector<int> argRefs = t.argRefs;
            if (t.remaining > 0)
                --t.remaining;
            t.due = now + t.interval;
            if (last)
                r.timers.erase(it);
            lua_rawgeti(L, LUA_REGISTRYINDEX, fnRef);
            for (int a : argRefs)
                lua_rawgeti(L, LUA_REGISTRYINDEX, a);
            HostPCall(L, static_cast<int>(argRefs.size()), r.name + ":timer");
            if (last && r.L == L)
            {
                luaL_unref(L, LUA_REGISTRYINDEX, fnRef);
                for (int a : argRefs)
                    luaL_unref(L, LUA_REGISTRYINDEX, a);
            }
        }
    }

    // ------------------------------------------------------------------------------------
    // Lua host functions
    // ------------------------------------------------------------------------------------

    Resource& Self(lua_State* L)
    {
        Resource* r = ResourceOf(L);
        if (!r)
        {
            Out(stderr, "host function called from an unknown VM\n");
            abort();
        }
        return *r;
    }

    int l_outputDebugString(lua_State* L)
    {
        const char* text = luaL_checkstring(L, 1);
        const int   level = static_cast<int>(luaL_optnumber(L, 2, 3));
        Resource&   r = Self(L);
        const char* tag = level == 1 ? "ERROR" : level == 2 ? "WARNING" : "INFO";
        Out(level <= 2 ? stderr : stdout, "[%s] %s: %s\n", r.name.c_str(), tag, text);
        g_debug.push_back({g_nextDebugId++, r.name, level, text});
        lua_pushboolean(L, 1);
        return 1;
    }

    int l_print(lua_State* L)
    {
        // No C++ objects here: tostring() may raise (longjmp).
        const int n = lua_gettop(L);
        for (int i = 1; i <= n; ++i)
        {
            lua_getglobal(L, "tostring");
            lua_pushvalue(L, i);
            lua_call(L, 1, 1);
            if (i < n)
                lua_pushliteral(L, "    ");
        }
        lua_concat(L, n > 0 ? 2 * n - 1 : 0);
        const char* s = lua_tostring(L, -1);
        Out(stdout, "[%s] %s\n", Self(L).name.c_str(), s ? s : "");
        return 0;
    }

    int l_setTimer(lua_State* L)
    {
        luaL_checktype(L, 1, LUA_TFUNCTION);
        const double interval = luaL_checknumber(L, 2);
        const int    times = static_cast<int>(luaL_optnumber(L, 3, 1));
        if (interval < 0)
            return luaL_argerror(L, 2, "interval must be >= 0");
        Resource& r = Self(L);
        const int n = lua_gettop(L);
        Timer     t;
        t.interval = interval;
        t.remaining = times < 0 ? 0 : times;
        t.due = NowMs() + interval;
        lua_pushvalue(L, 1);
        t.fnRef = luaL_ref(L, LUA_REGISTRYINDEX);
        for (int i = 4; i <= n; ++i)
        {
            lua_pushvalue(L, i);
            t.argRefs.push_back(luaL_ref(L, LUA_REGISTRYINDEX));
        }
        const int id = g_nextTimerId++;
        r.timers.emplace(id, std::move(t));
        lua_pushnumber(L, id);
        return 1;
    }

    int l_killTimer(lua_State* L)
    {
        const int id = static_cast<int>(luaL_checknumber(L, 1));
        Resource& r = Self(L);
        auto      it = r.timers.find(id);
        if (it == r.timers.end())
        {
            lua_pushboolean(L, 0);
            return 1;
        }
        // refs are left in place on purpose if the timer is currently running; they are
        // tiny and die with the VM (MTA defers timer deletion similarly)
        luaL_unref(L, LUA_REGISTRYINDEX, it->second.fnRef);
        for (int a : it->second.argRefs)
            luaL_unref(L, LUA_REGISTRYINDEX, a);
        r.timers.erase(it);
        lua_pushboolean(L, 1);
        return 1;
    }

    int l_isTimer(lua_State* L)
    {
        const int id = static_cast<int>(luaL_checknumber(L, 1));
        Resource& r = Self(L);
        lua_pushboolean(L, r.timers.count(id) != 0);
        return 1;
    }

    int l_getTickCount(lua_State* L)
    {
        lua_pushnumber(L, std::floor(NowMs()));
        return 1;
    }

    int l_disabled(lua_State* L) { return luaL_error(L, "this function is disabled by the server"); }

    // ---- harness.* ----------------------------------------------------------------------

    void CheckFiles(lua_State* L, int idx)
    {
        if (lua_type(L, idx) == LUA_TSTRING)
            return;
        luaL_checktype(L, idx, LUA_TTABLE);
        const int n = static_cast<int>(lua_objlen(L, idx));
        for (int i = 1; i <= n; ++i)
        {
            lua_rawgeti(L, idx, i);
            if (lua_type(L, -1) != LUA_TSTRING)
                luaL_argerror(L, idx, "files must be strings");
            lua_pop(L, 1);
        }
    }

    std::vector<std::string> ReadFiles(lua_State* L, int idx)
    {
        std::vector<std::string> files;
        if (lua_type(L, idx) == LUA_TSTRING)
            files.push_back(lua_tostring(L, idx));
        else
        {
            const int n = static_cast<int>(lua_objlen(L, idx));
            for (int i = 1; i <= n; ++i)
            {
                lua_rawgeti(L, idx, i);
                files.push_back(lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        }
        return files;
    }

    bool OptBoolField(lua_State* L, int idx, const char* name)
    {
        if (!lua_istable(L, idx))
            return false;
        lua_getfield(L, idx, name);
        const bool v = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
        return v;
    }

    // harness.start(name, files, [args]) -> true | false, err   (synchronous, like startResource)
    int h_start(lua_State* L)
    {
        luaL_checkstring(L, 1);
        CheckFiles(L, 2);
        int       ok = 0;
        char      errbuf[1024] = {0};
        {
            const std::string              name = lua_tostring(L, 1);
            const std::vector<std::string> files = ReadFiles(L, 2);
            std::string                    error;
            ok = StartResource(name, files, lua_isnoneornil(L, 3) ? nullptr : L, 3, false, error);
            snprintf(errbuf, sizeof(errbuf), "%s", error.c_str());
        }
        lua_pushboolean(L, ok);
        if (ok)
            return 1;
        lua_pushstring(L, errbuf);
        return 2;
    }

    int h_stop(lua_State* L)
    {
        const char* name = luaL_checkstring(L, 1);
        Command     c{Command::Stop};
        c.name = name;
        g_commands.push_back(std::move(c));
        return 0;
    }

    // harness.destroyNoHooks(name, {reuseAddress=bool, thenStart=name, thenFiles=files})
    int h_destroyNoHooks(lua_State* L)
    {
        luaL_checkstring(L, 1);
        if (!lua_isnoneornil(L, 2))
        {
            luaL_checktype(L, 2, LUA_TTABLE);
            lua_getfield(L, 2, "thenFiles");
            if (!lua_isnil(L, -1))
                CheckFiles(L, lua_gettop(L));
            lua_pop(L, 1);
        }
        Command c{Command::Destroy};
        c.name = lua_tostring(L, 1);
        c.reuseAddress = OptBoolField(L, 2, "reuseAddress");
        if (lua_istable(L, 2))
        {
            lua_getfield(L, 2, "thenStart");
            if (lua_isstring(L, -1))
                c.thenStart = lua_tostring(L, -1);
            lua_pop(L, 1);
            lua_getfield(L, 2, "thenFiles");
            if (!lua_isnil(L, -1))
                c.thenFiles = ReadFiles(L, lua_gettop(L));
            lua_pop(L, 1);
        }
        g_commands.push_back(std::move(c));
        return 0;
    }

    int h_state(lua_State* L)
    {
        const char* name = luaL_checkstring(L, 1);
        auto        it = g_resources.find(name);
        lua_pushstring(L, it == g_resources.end() ? "unknown" : StateName(it->second->state));
        return 1;
    }

    int h_vmAddress(lua_State* L)
    {
        const char* name = luaL_checkstring(L, 1);
        auto        it = g_resources.find(name);
        char        buf[32] = "nil";
        if (it != g_resources.end() && it->second->L)
            snprintf(buf, sizeof(buf), "%p", static_cast<void*>(it->second->L));
        lua_pushstring(L, buf);
        return 1;
    }

    int h_queue(lua_State*, Command::Kind kind)
    {
        g_commands.push_back(Command{kind});
        return 0;
    }
    int h_unloadModule(lua_State* L) { return h_queue(L, Command::Unload); }
    int h_loadModule(lua_State* L) { return h_queue(L, Command::Load); }
    int h_reloadModule(lua_State* L) { return h_queue(L, Command::Reload); }

    int h_moduleLoaded(lua_State* L)
    {
        lua_pushboolean(L, g_module != nullptr);
        lua_pushnumber(L, g_moduleLoads);
        return 2;
    }

    int h_lastShutdownMs(lua_State* L)
    {
        lua_pushnumber(L, g_lastShutdownMs);
        return 1;
    }

    int h_expectShutdownWithinMs(lua_State* L)
    {
        g_expectShutdownWithinMs = luaL_checknumber(L, 1);
        return 0;
    }

    int h_done(lua_State* L)
    {
        const bool  ok = lua_toboolean(L, 1) != 0;
        const char* msg = luaL_optstring(L, 2, "");
        Command     c{Command::Done};
        c.ok = ok;
        c.message = msg;
        g_commands.push_back(std::move(c));
        return 0;
    }

    int h_fail(lua_State* L)
    {
        const char* msg = luaL_checkstring(L, 1);
        Fail(msg);
        return 0;
    }

    int h_log(lua_State* L)
    {
        const char* msg = luaL_checkstring(L, 1);
        Out(stdout, "[%s] %s\n", Self(L).name.c_str(), msg);
        return 0;
    }

    // harness.debugMessages() -> { {id=, resource=, level=, text=}, ... } (unconsumed only)
    int h_debugMessages(lua_State* L)
    {
        lua_newtable(L);
        int i = 0;
        for (const DebugMessage& m : g_debug)
        {
            if (m.consumed)
                continue;
            lua_createtable(L, 0, 4);
            lua_pushnumber(L, m.id);
            lua_setfield(L, -2, "id");
            lua_pushstring(L, m.resource.c_str());
            lua_setfield(L, -2, "resource");
            lua_pushnumber(L, m.level);
            lua_setfield(L, -2, "level");
            lua_pushlstring(L, m.text.data(), m.text.size());
            lua_setfield(L, -2, "text");
            lua_rawseti(L, -2, ++i);
        }
        return 1;
    }

    int h_consumeDebug(lua_State* L)
    {
        const int id = static_cast<int>(luaL_checknumber(L, 1));
        for (DebugMessage& m : g_debug)
            if (m.id == id)
                m.consumed = true;
        return 0;
    }

    int h_consoleMessages(lua_State* L)
    {
        std::vector<std::string> copy;
        {
            std::lock_guard<std::mutex> lock(g_consoleMutex);
            copy = g_console;
        }
        lua_createtable(L, static_cast<int>(copy.size()), 0);
        for (size_t i = 0; i < copy.size(); ++i)
        {
            lua_pushlstring(L, copy[i].data(), copy[i].size());
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        return 1;
    }

    long ReadProcStatus(const char* key)
    {
        FILE* f = fopen("/proc/self/status", "r");
        if (!f)
            return -1;
        char       line[256];
        long       value = -1;
        const auto keyLen = strlen(key);
        while (fgets(line, sizeof(line), f))
            if (!strncmp(line, key, keyLen) && line[keyLen] == ':')
            {
                value = strtol(line + keyLen + 1, nullptr, 10);
                break;
            }
        fclose(f);
        return value;
    }

    int h_rssKB(lua_State* L)
    {
        lua_pushnumber(L, static_cast<double>(ReadProcStatus("VmRSS")));
        return 1;
    }

    int h_threadCount(lua_State* L)
    {
        lua_pushnumber(L, static_cast<double>(ReadProcStatus("Threads")));
        return 1;
    }

    int h_fdCount(lua_State* L)
    {
        int  n = 0;
        DIR* d = opendir("/proc/self/fd");
        if (d)
        {
            while (readdir(d))
                ++n;
            closedir(d);
        }
        lua_pushnumber(L, n - 2);
        return 1;
    }

    int h_now(lua_State* L)
    {
        lua_pushnumber(L, NowMs());
        return 1;
    }

    int h_sleep(lua_State* L)
    {
        const double ms = luaL_checknumber(L, 1);
        std::this_thread::sleep_for(std::chrono::microseconds(static_cast<long long>(ms * 1000)));
        return 0;
    }

    int h_getenv(lua_State* L)
    {
        const char* v = getenv(luaL_checkstring(L, 1));
        if (v)
            lua_pushstring(L, v);
        else
            lua_pushnil(L);
        return 1;
    }

    // live registry refs (non-number values in the array part) and the array size
    int h_registryCount(lua_State* L)
    {
        int live = 0, total = 0;
        lua_pushnil(L);
        while (lua_next(L, LUA_REGISTRYINDEX))
        {
            ++total;
            if (lua_type(L, -2) == LUA_TNUMBER && lua_type(L, -1) != LUA_TNUMBER)
                ++live;
            lua_pop(L, 1);
        }
        lua_pushnumber(L, live);
        lua_pushnumber(L, total);
        lua_pushnumber(L, static_cast<double>(lua_objlen(L, LUA_REGISTRYINDEX)));
        return 3;
    }

    int h_gcAll(lua_State*)
    {
        GcAllVms("harness.gcAll");
        return 0;
    }

    // harness.call(resourceName, globalFunctionName, ...) -> ok, results...  (like MTA's call()
    // for exported functions: plain values are copied between VMs)
    int h_call(lua_State* L)
    {
        const char* name = luaL_checkstring(L, 1);
        const char* fn = luaL_checkstring(L, 2);
        const int   nargs = lua_gettop(L) - 2;
        auto        it = g_resources.find(name);
        if (it == g_resources.end() || !it->second->L || it->second->L == lua_getmainstate(L))
        {
            lua_pushboolean(L, 0);
            lua_pushstring(L, "resource not running (or calling itself)");
            return 2;
        }
        lua_State* T = it->second->L;
        const int  base = lua_gettop(T);
        lua_pushcfunction(T, Traceback);
        lua_getfield(T, LUA_GLOBALSINDEX, fn);
        for (int i = 3; i < 3 + nargs; ++i)
            CopyValue(L, i, T, 0);
        if (lua_pcall(T, nargs, LUA_MULTRET, base + 1) != 0)
        {
            lua_pushboolean(L, 0);
            CopyValue(T, -1, L, 0);
            lua_settop(T, base);
            return 2;
        }
        const int nres = lua_gettop(T) - base - 1;
        lua_checkstack(L, nres + 2);
        lua_pushboolean(L, 1);
        for (int i = 0; i < nres; ++i)
            CopyValue(T, base + 2 + i, L, 0);
        lua_settop(T, base);
        return nres + 1;
    }

    std::map<std::string, double> g_counters;

    // harness.counter(name [, delta]) -> value   (shared by all VMs)
    int h_counter(lua_State* L)
    {
        const char*  name = luaL_checkstring(L, 1);
        const double delta = luaL_optnumber(L, 2, 0);
        double&      v = g_counters[name];
        v += delta;
        lua_pushnumber(L, v);
        return 1;
    }

    int h_frame(lua_State* L)
    {
        lua_pushnumber(L, static_cast<double>(g_frame));
        return 1;
    }

    int h_blockedCalls(lua_State* L)
    {
        lua_pushnumber(L, g_blockedCalls.load());
        return 1;
    }

    Proxy g_proxy;

    int h_proxyStart(lua_State* L)
    {
        const int   listenPort = static_cast<int>(luaL_checknumber(L, 1));
        const char* host = luaL_checkstring(L, 2);
        const int   port = static_cast<int>(luaL_checknumber(L, 3));
        char        errbuf[256] = {0};
        bool        ok;
        {
            std::string error;
            ok = g_proxy.Start(listenPort, host, port, error);
            snprintf(errbuf, sizeof(errbuf), "%s", error.c_str());
        }
        lua_pushboolean(L, ok);
        lua_pushstring(L, errbuf);
        return 2;
    }

    int h_proxyMode(lua_State* L)
    {
        const char* mode = luaL_checkstring(L, 1);
        if (!strcmp(mode, "up"))
            g_proxy.SetMode(Proxy::Mode::Up);
        else if (!strcmp(mode, "refuse"))
            g_proxy.SetMode(Proxy::Mode::Refuse);
        else if (!strcmp(mode, "blackhole"))
            g_proxy.SetMode(Proxy::Mode::Blackhole);
        else
            return luaL_argerror(L, 1, "up|refuse|blackhole");
        std::this_thread::sleep_for(std::chrono::milliseconds(60));  // let the proxy thread apply it
        return 0;
    }

    int h_proxyKill(lua_State* L)
    {
        lua_pushnumber(L, g_proxy.KillAll());
        return 1;
    }

    int h_proxyStats(lua_State* L)
    {
        lua_pushnumber(L, g_proxy.Accepted());
        lua_pushnumber(L, g_proxy.Active());
        return 2;
    }

    void RegisterHostApi(lua_State* L, Resource&)
    {
        // CLuaMain::InitSecurity
        static const luaL_Reg osDisabled[] = {{"execute", l_disabled}, {"rename", l_disabled}, {"remove", l_disabled}, {"exit", l_disabled},
                                              {"getenv", l_disabled},  {"tmpname", l_disabled}, {"setlocale", l_disabled}, {nullptr, nullptr}};
        luaL_register(L, "os", osDisabled);
        lua_pop(L, 1);
        for (const char* f : {"dofile", "loadfile", "require", "loadlib", "getfenv", "newproxy"})
            lua_register(L, f, l_disabled);

        lua_register(L, "outputDebugString", l_outputDebugString);
        lua_register(L, "print", l_print);
        lua_register(L, "setTimer", l_setTimer);
        lua_register(L, "killTimer", l_killTimer);
        lua_register(L, "isTimer", l_isTimer);
        lua_register(L, "getTickCount", l_getTickCount);

        static const luaL_Reg api[] = {
            {"start", h_start},
            {"stop", h_stop},
            {"destroyNoHooks", h_destroyNoHooks},
            {"state", h_state},
            {"vmAddress", h_vmAddress},
            {"unloadModule", h_unloadModule},
            {"loadModule", h_loadModule},
            {"reloadModule", h_reloadModule},
            {"moduleLoaded", h_moduleLoaded},
            {"lastShutdownMs", h_lastShutdownMs},
            {"expectShutdownWithinMs", h_expectShutdownWithinMs},
            {"done", h_done},
            {"fail", h_fail},
            {"log", h_log},
            {"debugMessages", h_debugMessages},
            {"consumeDebug", h_consumeDebug},
            {"consoleMessages", h_consoleMessages},
            {"rssKB", h_rssKB},
            {"threadCount", h_threadCount},
            {"fdCount", h_fdCount},
            {"now", h_now},
            {"sleep", h_sleep},
            {"getenv", h_getenv},
            {"registryCount", h_registryCount},
            {"gcAll", h_gcAll},
            {"frame", h_frame},
            {"counter", h_counter},
            {"call", h_call},
            {"blockedCalls", h_blockedCalls},
            {"proxyStart", h_proxyStart},
            {"proxyMode", h_proxyMode},
            {"proxyKill", h_proxyKill},
            {"proxyStats", h_proxyStats},
            {nullptr, nullptr},
        };
        luaL_register(L, "harness", api);
        lua_pushstring(L, g_cfg.variant.c_str());
        lua_setfield(L, -2, "variant");
        lua_pushnumber(L, g_cfg.slowdown);
        lua_setfield(L, -2, "slowdown");
        lua_pushnumber(L, g_cfg.scale);
        lua_setfield(L, -2, "scale");
        lua_pushstring(L, g_cfg.scenarioDir.c_str());
        lua_setfield(L, -2, "scenarioDir");
        lua_pop(L, 1);
    }

    // ------------------------------------------------------------------------------------
    // main
    // ------------------------------------------------------------------------------------

    void Watchdog()
    {
        // Backstop for hangs that the frame loop cannot notice (e.g. inside ShutdownModule).
        const double limit = g_cfg.timeoutSec * 1000 + 120000 * g_cfg.slowdown;
        while (NowMs() < limit)
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        Out(stderr, "WATCHDOG: process hung (phase %d) - aborting\n", g_phase.load());
        abort();
    }

    void PrintSummary(int exitCode)
    {
        int unconsumed1 = 0, unconsumed2 = 0;
        for (const DebugMessage& m : g_debug)
            if (!m.consumed)
            {
                if (m.level == 1)
                    ++unconsumed1;
                else if (m.level == 2)
                    ++unconsumed2;
            }
        Out(stdout, "==== SUMMARY: done=%s ok=%s failures=%d hostErrors=%d unconsumedDebug(errors=%d warnings=%d) blockedCalls=%d frames=%llu -> exit %d\n",
            g_done ? "yes" : "no", g_doneOk ? "yes" : "no", g_failures, g_hostErrors, unconsumed1, unconsumed2, g_blockedCalls.load(),
            static_cast<unsigned long long>(g_frame), exitCode);
        if (!g_doneMessage.empty())
            Out(stdout, "==== scenario says: %s\n", g_doneMessage.c_str());
        for (const std::string& f : g_failureLog)
            Out(stdout, "==== failure: %s\n", f.c_str());
    }

    int Main(int argc, char** argv)
    {
        for (int i = 1; i < argc; ++i)
        {
            const std::string a = argv[i];
            auto              next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
            if (a == "--module")
                g_cfg.modulePath = next();
            else if (a == "--scenario")
                g_cfg.scenarioPath = next();
            else if (a == "--prelude")
                g_cfg.preludePath = next();
            else if (a == "--timeout")
                g_cfg.timeoutSec = atof(next().c_str());
        }
        if (const char* v = getenv("MLPG_VARIANT"))
            g_cfg.variant = v;
        if (const char* v = getenv("MLPG_SLOWDOWN"))
            g_cfg.slowdown = atof(v);
        if (const char* v = getenv("MLPG_SCALE"))
            g_cfg.scale = atof(v);
        if (g_cfg.modulePath.empty() || g_cfg.scenarioPath.empty() || g_cfg.preludePath.empty())
        {
            fprintf(stderr, "usage: mtaserver_fake --module ml_pgsql.so --scenario dir/main.lua --prelude prelude.lua [--timeout sec]\n");
            return 2;
        }
        const size_t slash = g_cfg.scenarioPath.find_last_of('/');
        g_cfg.scenarioDir = slash == std::string::npos ? "." : g_cfg.scenarioPath.substr(0, slash);
        setvbuf(stdout, nullptr, _IOLBF, 0);

        Out(stdout, "fakehost: variant=%s slowdown=%g scale=%g module=%s scenario=%s\n", g_cfg.variant.c_str(), g_cfg.slowdown, g_cfg.scale,
            g_cfg.modulePath.c_str(), g_cfg.scenarioPath.c_str());

        lua_registerPreCallHook(PreCallHook);
        std::thread(Watchdog).detach();

        std::string error;
        if (!LoadModule(false, error))  // mtaserver.conf <module>: loaded before any resource
        {
            Out(stderr, "cannot load module: %s\n", error.c_str());
            return 3;
        }

        if (!StartResource("main", {Basename(g_cfg.scenarioPath)}, nullptr, 0, false, error))
        {
            HostError("start main", error);
            g_done = true;
        }

        const double deadline = g_cfg.timeoutSec * 1000;
        while (!g_done)
        {
            ++g_frame;
            for (Resource* r : ResourcesByStart(false))
                RunTimers(*r);
            if (g_module)
                g_module->DoPulse();
            ProcessCommands();
            if (!g_done && NowMs() > deadline)
            {
                Fail("global timeout: scenario did not finish within " + std::to_string(static_cast<int>(g_cfg.timeoutSec)) + " s");
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }

        // Server shutdown: ~CResourceManager stops every resource, then ~CLuaManager deletes the
        // module manager (ShutdownModule + dlclose).
        g_phase = 1;
        Out(stdout, "host: server shutdown\n");
        for (Resource* r : ResourcesByStart(true))
        {
            if (r->state == RState::Running)
                StopResource(*r);
            else
                DestroyVm(*r, "shutdown");
        }
        g_resourceManagerGone = true;
        UnloadModule("server shutdown");
        g_proxy.Stop();
        if (g_stashedBlock)
        {
            free(g_stashedBlock);
            g_stashedBlock = nullptr;
        }

        int unconsumedErrors = 0;
        for (const DebugMessage& m : g_debug)
            if (!m.consumed && m.level == 1)
                ++unconsumedErrors;
        if (unconsumedErrors)
            Fail(std::to_string(unconsumedErrors) + " unexpected error message(s) in debug output (see ERROR lines)");
        if (g_blockedCalls.load())
            Fail(std::to_string(g_blockedCalls.load()) + " C call(s) into inactive resources were blocked by the pre-call hook");
        const int exitCode = (g_done && g_doneOk && g_failures == 0 && g_hostErrors == 0) ? 0 : 1;
        PrintSummary(exitCode);
        return exitCode;
    }
}

extern "C" __attribute__((visibility("default"))) int fakehost_main(int argc, char** argv)
{
    return host::Main(argc, argv);
}
