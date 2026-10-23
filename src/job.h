#pragma once

#include <libpq-fe.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mlpg
{
    struct VmState;

    using Clock = std::chrono::steady_clock;

    struct ResultDeleter
    {
        void operator()(PGresult* r) const noexcept { PQclear(r); }
    };
    using ResultPtr = std::unique_ptr<PGresult, ResultDeleter>;

    enum class Int64Mode : uint8_t
    {
        Auto,    // number when exactly representable as a double (|v| <= 2^53), else string
        Number,  // always number (may lose precision)
        String,  // always string
    };

    enum class NumericMode : uint8_t
    {
        Number,
        String,
    };

    struct ConvOptions
    {
        Int64Mode   int64 = Int64Mode::Auto;
        NumericMode numeric = NumericMode::Number;
    };

    // One SQL statement with text-format parameters.
    struct Statement
    {
        std::string sql;
        // Parameter values, each NUL-terminated, stored back to back; paramOffsets[i] is the
        // start of parameter i or -1 for SQL NULL. Keeps a statement at three allocations
        // no matter how many parameters it has.
        std::string          paramData;
        std::vector<int32_t> paramOffsets;
        // Simple query protocol: allows several ';'-separated commands and COPY, but cannot
        // be pipelined. Only used for parameterless SQL that needs it.
        bool simpleProtocol = false;

        ResultPtr result;  // last result produced (worker-written)
    };

    enum class Delivery : uint8_t
    {
        Callback,  // call a Lua function with the outcome
        Exec,      // fire and forget; failures are logged to the debug console
        Await,     // resume the coroutine that issued the query
        Sync,      // a blocked main-thread caller picks the job up itself
    };

    // A unit of work: one query, or a list of statements executed atomically.
    // Created on the main thread, executed by exactly one worker, then handed back to the
    // main thread through the completion queue. Never shared between threads.
    struct Job
    {
        uint64_t               id = 0;
        Delivery               delivery = Delivery::Exec;
        bool                   transaction = false;
        std::vector<Statement> stmts;

        // Main-thread data. Workers only move the pointer around and never touch the VM.
        std::shared_ptr<VmState> vm;
        int                      ref = -2;  // LUA_NOREF; callback function or coroutine
        ConvOptions              conv;
        char                     where[96] = {0};  // call site ("file.lua:12"), for Exec errors

        // Outcome, written by the worker.
        bool        ok = false;
        std::string error;
        char        sqlstate[6] = {0};
        int         failedStatement = 0;  // 1-based, transactions only
        Clock::time_point queuedAt{};
        int         sendAttempts = 0;     // requeues after a send failure (bounded)

        std::shared_ptr<std::atomic<size_t>> outstanding;  // see OutstandingCounter

        Job() = default;
        Job(const Job&) = delete;
        Job& operator=(const Job&) = delete;
        ~Job()
        {
            if (outstanding)
                outstanding->fetch_sub(1, std::memory_order_acq_rel);
        }

        void Fail(const char* state, std::string message, int stmtIndex = 0)
        {
            if (!ok && !error.empty())
                return;  // keep the first error
            ok = false;
            error = std::move(message);
            snprintf(sqlstate, sizeof(sqlstate), "%s", state ? state : "");
            failedStatement = stmtIndex;
        }
    };

    using JobPtr = std::unique_ptr<Job>;

    // Counts a pool's jobs from submission until their result has been delivered (or
    // dropped) on the main thread, so `maxQueue` also bounds finished-but-undelivered
    // results. Released by the job's destructor, wherever that happens.
    using OutstandingCounter = std::shared_ptr<std::atomic<size_t>>;
}
