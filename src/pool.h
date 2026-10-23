#pragma once

#include "job.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace mlpg
{
    // Finished jobs travel back to the main thread through this queue. Workers push, the
    // main thread (DoPulse / sync waits) pops.
    class CompletionQueue
    {
    public:
        void Push(std::vector<JobPtr>& jobs);
        void Push(JobPtr job);

        // Cheap check for DoPulse; no locking.
        bool HasItems() const { return m_size.load(std::memory_order_acquire) != 0; }

        // Moves everything into `out` (appending).
        void TakeAll(std::vector<JobPtr>& out);

        // Blocks until the job with `id` has completed or the timeout expires. Every other
        // completion that arrives meanwhile is appended to `stash`, preserving order.
        JobPtr WaitFor(uint64_t id, std::chrono::milliseconds timeout, std::vector<JobPtr>& stash);

    private:
        std::mutex              m_mutex;
        std::condition_variable m_cond;
        std::vector<JobPtr>     m_items;
        std::atomic<size_t>     m_size{0};
    };

    struct PoolConfig
    {
        std::string conninfo;
        std::string appName;
        int         size = 1;
        int         maxBatch = 64;          // jobs pipelined per round trip (1 = no pipelining)
        size_t      maxQueue = 100000;      // backpressure: max outstanding (undelivered) jobs
        int         connectTimeoutMs = 10000;
        int         statementTimeoutMs = 0; // SET statement_timeout after connecting
        ConvOptions conv;
    };

    struct PoolStats
    {
        size_t   queued = 0;
        size_t   inFlight = 0;
        size_t   outstanding = 0;  // queued + running + finished but not yet delivered
        int      connected = 0;
        uint64_t submitted = 0;
        uint64_t succeeded = 0;
        uint64_t failed = 0;
        uint64_t reconnects = 0;
        uint64_t roundTrips = 0;
        double   avgLatencyMs = 0;  // queue + execution time of completed jobs
    };

    class Worker;

    // A set of connections to one database, each owned by a worker thread. Jobs are FIFO;
    // with size == 1 they also execute in submission order.
    class Pool
    {
    public:
        enum class SubmitResult
        {
            Ok,
            Closed,
            QueueFull,
        };

        Pool(uint64_t id, PoolConfig config, CompletionQueue& completions);
        ~Pool();

        Pool(const Pool&) = delete;
        Pool& operator=(const Pool&) = delete;

        uint64_t          Id() const { return m_id; }
        const PoolConfig& Config() const { return m_config; }

        void Start();

        // On success the job is consumed. On failure the job is left with the caller.
        SubmitResult Submit(JobPtr& job);

        // Blocks until one connection is up (true) or every worker failed its first
        // attempt / the timeout passed (false).
        bool WaitReady(int timeoutMs, std::string& error);

        // Graceful: no new jobs; workers finish the queue, disconnect and exit.
        void Close();
        // Hard: queued jobs fail immediately, in-flight queries are cancelled.
        void Abort();

        bool IsClosed() const { return m_closing.load(std::memory_order_acquire); }
        bool IsAborting() const { return m_aborting.load(std::memory_order_acquire); }
        bool AllWorkersExited() const { return m_liveWorkers.load(std::memory_order_acquire) == 0; }
        void Join();

        PoolStats Stats();

    private:
        friend class Worker;

        // Worker interface. A worker without a connection does not take jobs while another
        // worker is connected (it would only fail them); it wakes at `retryAt` to reconnect.
        // Returns false when the worker should exit; an empty batch means "retry connecting".
        bool TakeBatch(std::vector<JobPtr>& batch, bool connected, Clock::time_point retryAt);
        void Requeue(std::vector<JobPtr>& jobs, const std::string& lastError);  // unsent jobs go back to the front
        void Finish(std::vector<JobPtr>& jobs);
        void ReportConnectAttempt(bool ok, const std::string& error);
        void WorkerExited();

        const uint64_t                 m_id;
        const PoolConfig               m_config;
        CompletionQueue&               m_completions;
        const std::vector<std::string> m_resolveHosts;  // host names to pre-resolve per connect

        std::mutex              m_mutex;
        std::condition_variable m_cond;
        std::deque<JobPtr>      m_queue;
        size_t                  m_inFlight = 0;
        OutstandingCounter      m_outstanding;  // submitted and not yet delivered

        std::atomic<bool> m_closing{false};
        std::atomic<bool> m_aborting{false};
        std::atomic<int>  m_liveWorkers{0};

        // first-connection handshake for WaitReady
        std::mutex              m_readyMutex;
        std::condition_variable m_readyCond;
        int                     m_readyOk = 0;
        int                     m_readyFailed = 0;
        std::string             m_readyError;

        std::vector<std::unique_ptr<Worker>> m_workers;

        // statistics
        std::atomic<int>      m_connected{0};
        std::atomic<uint64_t> m_submitted{0};
        std::atomic<uint64_t> m_succeeded{0};
        std::atomic<uint64_t> m_failed{0};
        std::atomic<uint64_t> m_reconnects{0};
        std::atomic<uint64_t> m_roundTrips{0};
        std::atomic<uint64_t> m_latencyUsTotal{0};
    };
}
