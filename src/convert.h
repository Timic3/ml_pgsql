#pragma once

#include "job.h"
#include "lua_api.h"

#include <cstddef>

namespace mlpg
{
    // Sentinel for SQL NULL inside table parameters (exposed to Lua as PG_NULL).
    void* NullSentinel();

    // Frees conversion state (C locale object, scratch buffers) at module shutdown.
    void ShutdownConversion();

    // --- Lua -> PostgreSQL --------------------------------------------------------------
    // These only use Lua API calls that cannot raise errors (except on out-of-memory), so
    // they may run while C++ objects are alive.

    // Appends the Lua value at `idx` as the next text-format parameter of `st`.
    bool AppendParam(lua_State* L, int idx, Statement& st, char* error, size_t errorSize);

    // Parameterless SQL that contains several commands or starts with COPY needs the
    // simple query protocol.
    bool NeedsSimpleProtocol(const char* sql, size_t len);
    // BEGIN/COMMIT/ROLLBACK/... (not allowed inside pgTransaction).
    bool IsTransactionControl(const char* sql, size_t len);
    // BEGIN / START TRANSACTION
    bool IsTransactionStart(const char* sql, size_t len);
    bool IsCopy(const char* sql, size_t len);

    // --- PostgreSQL -> Lua --------------------------------------------------------------

    // Pushes the job outcome; returns the number of values pushed.
    //   query ok:        rows, nil, affectedRows
    //   transaction ok:  {rows1, rows2, ...}, nil, {affected1, affected2, ...}
    //   failure:         false, message, sqlstate        (+ failedStatementIndex for transactions)
    int PushOutcome(lua_State* L, Job& job);
}
