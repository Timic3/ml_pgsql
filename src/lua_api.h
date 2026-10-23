#pragma once

// Lua 5.1 API as built into the MTA server (headers copied from mtasa-blue/vendor/lua).
//
// The MTA server dlopen()s deathmatch.so (which contains Lua) without RTLD_GLOBAL, so a
// module cannot link against the Lua symbols directly. Bundling a private Lua copy is not
// an option either: Lua 5.1 compares table nodes against a static `dummynode`, so two
// copies operating on the same lua_State corrupt each other. lua_api.cpp defines every
// Lua function this module uses as a thin forwarder to the server's implementation,
// resolved once in InitModule.

extern "C"
{
#include "lua/lua.h"
#include "lua/lauxlib.h"
}

#include <string>

namespace mlpg
{
    // `anchor` is any code or data address inside the library that hosts Lua (the
    // module manager's vtable). Falls back to the global symbol scope.
    bool ResolveLuaApi(const void* anchor, std::string& error);
}
