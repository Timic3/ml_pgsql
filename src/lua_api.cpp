#include "lua_api.h"

#include <cstdarg>
#include <dlfcn.h>

// (return type, name, parameter list, argument list)
#define MLPG_LUA_FUNCTIONS(X)                                                                           \
    X(int, lua_gettop, (lua_State * L), (L))                                                            \
    X(void, lua_settop, (lua_State * L, int idx), (L, idx))                                             \
    X(void, lua_pushvalue, (lua_State * L, int idx), (L, idx))                                          \
    X(void, lua_remove, (lua_State * L, int idx), (L, idx))                                             \
    X(void, lua_insert, (lua_State * L, int idx), (L, idx))                                             \
    X(void, lua_replace, (lua_State * L, int idx), (L, idx))                                            \
    X(int, lua_checkstack, (lua_State * L, int sz), (L, sz))                                            \
    X(void, lua_xmove, (lua_State * from, lua_State * to, int n), (from, to, n))                        \
    X(int, lua_isnumber, (lua_State * L, int idx), (L, idx))                                            \
    X(int, lua_isstring, (lua_State * L, int idx), (L, idx))                                            \
    X(int, lua_type, (lua_State * L, int idx), (L, idx))                                                \
    X(const char*, lua_typename, (lua_State * L, int tp), (L, tp))                                      \
    X(int, lua_rawequal, (lua_State * L, int a, int b), (L, a, b))                                      \
    X(lua_Number, lua_tonumber, (lua_State * L, int idx), (L, idx))                                     \
    X(lua_Integer, lua_tointeger, (lua_State * L, int idx), (L, idx))                                   \
    X(int, lua_toboolean, (lua_State * L, int idx), (L, idx))                                           \
    X(const char*, lua_tolstring, (lua_State * L, int idx, size_t* len), (L, idx, len))                 \
    X(size_t, lua_objlen, (lua_State * L, int idx), (L, idx))                                           \
    X(void*, lua_touserdata, (lua_State * L, int idx), (L, idx))                                        \
    X(lua_State*, lua_tothread, (lua_State * L, int idx), (L, idx))                                     \
    X(const void*, lua_topointer, (lua_State * L, int idx), (L, idx))                                   \
    X(void, lua_pushnil, (lua_State * L), (L))                                                          \
    X(void, lua_pushnumber, (lua_State * L, lua_Number n), (L, n))                                      \
    X(void, lua_pushinteger, (lua_State * L, lua_Integer n), (L, n))                                    \
    X(void, lua_pushlstring, (lua_State * L, const char* s, size_t l), (L, s, l))                       \
    X(void, lua_pushstring, (lua_State * L, const char* s), (L, s))                                     \
    X(const char*, lua_pushvfstring, (lua_State * L, const char* fmt, va_list argp), (L, fmt, argp))    \
    X(void, lua_pushcclosure, (lua_State * L, lua_CFunction fn, int n), (L, fn, n))                     \
    X(void, lua_pushboolean, (lua_State * L, int b), (L, b))                                            \
    X(void, lua_pushlightuserdata, (lua_State * L, void* p), (L, p))                                    \
    X(int, lua_pushthread, (lua_State * L), (L))                                                        \
    X(void, lua_gettable, (lua_State * L, int idx), (L, idx))                                           \
    X(void, lua_getfield, (lua_State * L, int idx, const char* k), (L, idx, k))                         \
    X(void, lua_rawget, (lua_State * L, int idx), (L, idx))                                             \
    X(void, lua_rawgeti, (lua_State * L, int idx, int n), (L, idx, n))                                  \
    X(void, lua_createtable, (lua_State * L, int narr, int nrec), (L, narr, nrec))                      \
    X(void*, lua_newuserdata, (lua_State * L, size_t sz), (L, sz))                                      \
    X(int, lua_getmetatable, (lua_State * L, int objindex), (L, objindex))                              \
    X(void, lua_settable, (lua_State * L, int idx), (L, idx))                                           \
    X(void, lua_setfield, (lua_State * L, int idx, const char* k), (L, idx, k))                         \
    X(void, lua_rawset, (lua_State * L, int idx), (L, idx))                                             \
    X(void, lua_rawseti, (lua_State * L, int idx, int n), (L, idx, n))                                  \
    X(int, lua_setmetatable, (lua_State * L, int objindex), (L, objindex))                              \
    X(void, lua_call, (lua_State * L, int nargs, int nresults), (L, nargs, nresults))                   \
    X(int, lua_pcall, (lua_State * L, int nargs, int nresults, int errfunc), (L, nargs, nresults, errfunc)) \
    X(int, lua_yield, (lua_State * L, int nresults), (L, nresults))                                     \
    X(int, lua_resume, (lua_State * L, int narg), (L, narg))                                            \
    X(int, lua_status, (lua_State * L), (L))                                                            \
    X(int, lua_error, (lua_State * L), (L))                                                             \
    X(int, lua_next, (lua_State * L, int idx), (L, idx))                                                \
    X(void, lua_concat, (lua_State * L, int n), (L, n))                                                 \
    X(int, lua_getstack, (lua_State * L, int level, lua_Debug* ar), (L, level, ar))                     \
    X(int, lua_getinfo, (lua_State * L, const char* what, lua_Debug* ar), (L, what, ar))                \
    X(int, lua_sethook, (lua_State * L, lua_Hook func, int mask, int count), (L, func, mask, count))     \
    X(lua_Hook, lua_gethook, (lua_State * L), (L))                                                      \
    X(int, lua_gethookmask, (lua_State * L), (L))                                                       \
    X(int, lua_gethookcount, (lua_State * L), (L))                                                      \
    X(lua_State*, lua_getmainstate, (lua_State * L), (L))                                               \
    X(int, luaL_ref, (lua_State * L, int t), (L, t))                                                    \
    X(void, luaL_unref, (lua_State * L, int t, int ref), (L, t, ref))                                   \
    X(void, luaL_where, (lua_State * L, int lvl), (L, lvl))                                             \
    X(int, luaL_argerror, (lua_State * L, int numarg, const char* extramsg), (L, numarg, extramsg))     \
    X(int, luaL_typerror, (lua_State * L, int narg, const char* tname), (L, narg, tname))               \
    X(const char*, luaL_checklstring, (lua_State * L, int numArg, size_t* l), (L, numArg, l))           \
    X(lua_Number, luaL_checknumber, (lua_State * L, int numArg), (L, numArg))                           \
    X(void, luaL_checktype, (lua_State * L, int narg, int t), (L, narg, t))                             \
    X(void, luaL_checkany, (lua_State * L, int narg), (L, narg))                                        \
    X(void*, luaL_checkudata, (lua_State * L, int ud, const char* tname), (L, ud, tname))               \
    X(int, luaL_newmetatable, (lua_State * L, const char* tname), (L, tname))                           \
    X(void, luaL_checkstack, (lua_State * L, int sz, const char* msg), (L, sz, msg))

namespace
{
#define MLPG_DECLARE_PTR(ret, name, params, args) ret(*p_##name) params = nullptr;
    MLPG_LUA_FUNCTIONS(MLPG_DECLARE_PTR)
#undef MLPG_DECLARE_PTR
}

extern "C"
{
#define MLPG_DEFINE_FORWARDER(ret, name, params, args) \
    __attribute__((visibility("hidden"))) ret name params { return p_##name args; }
    MLPG_LUA_FUNCTIONS(MLPG_DEFINE_FORWARDER)
#undef MLPG_DEFINE_FORWARDER

    // Variadic API functions cannot be forwarded; rebuild them on top of lua_pushvfstring.
    __attribute__((visibility("hidden"))) const char* lua_pushfstring(lua_State* L, const char* fmt, ...)
    {
        va_list argp;
        va_start(argp, fmt);
        const char* s = lua_pushvfstring(L, fmt, argp);
        va_end(argp);
        return s;
    }

    __attribute__((visibility("hidden"))) int luaL_error(lua_State* L, const char* fmt, ...)
    {
        va_list argp;
        va_start(argp, fmt);
        luaL_where(L, 1);
        lua_pushvfstring(L, fmt, argp);
        va_end(argp);
        lua_concat(L, 2);
        return lua_error(L);
    }
}

namespace mlpg
{
    bool ResolveLuaApi(const void* anchor, std::string& error)
    {
        void* host = nullptr;
        Dl_info info{};
        if (anchor && dladdr(anchor, &info) && info.dli_fname)
            host = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);

        bool ok = true;
        auto lookup = [&](const char* name) -> void* {
            void* sym = host ? dlsym(host, name) : nullptr;
            if (!sym)
                sym = dlsym(RTLD_DEFAULT, name);
            if (!sym && ok)
            {
                ok = false;
                error = std::string("Lua API symbol not found in server: ") + name;
            }
            return sym;
        };

#define MLPG_RESOLVE(ret, name, params, args) p_##name = reinterpret_cast<decltype(p_##name)>(lookup(#name));
        MLPG_LUA_FUNCTIONS(MLPG_RESOLVE)
#undef MLPG_RESOLVE

        if (host)
            dlclose(host);  // drops the reference taken by RTLD_NOLOAD; the library stays loaded
        return ok;
    }
}
