#include "pool.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>

#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>

namespace mlpg
{
    namespace
    {
        constexpr int kTickMs = 50;  // max time blocked in poll() before re-checking for abort
        constexpr int kAbortGraceMs = 1000;  // on abort: cancel, then keep reading results this long
        constexpr int kMinBackoffMs = 250;
        constexpr int kMaxBackoffMs = 5000;
        constexpr int kMaxSendAttempts = 3;

        // SQLSTATEs for errors raised by the module itself
        constexpr const char* kStateCannotConnect = "08001";
        constexpr const char* kStateConnectionLost = "08006";
        constexpr const char* kStateProtocol = "08P01";
        constexpr const char* kStateTxState = "25000";
        constexpr const char* kStateCanceled = "57014";

        std::string Trimmed(const char* message)
        {
            std::string s = message ? message : "";
            while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' '))
                s.pop_back();
            return s.empty() ? std::string("unknown error") : s;
        }

        int MillisUntil(Clock::time_point deadline)
        {
            auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
            return left < 0 ? 0 : static_cast<int>(std::min<long long>(left, 1 << 30));
        }

        // Host names libpq will look up with a blocking getaddrinfo (see Worker::ResolveHosts).
        // Not included: Unix socket paths, numeric addresses, and anything when hostaddr is set.
        std::vector<std::string> HostNamesToResolve(const std::string& conninfo)
        {
            std::string hosts, hostaddr;
            char*       parseError = nullptr;
            if (PQconninfoOption* options = PQconninfoParse(conninfo.c_str(), &parseError))
            {
                for (PQconninfoOption* o = options; o->keyword; ++o)
                {
                    if (o->val && !strcmp(o->keyword, "host"))
                        hosts = o->val;
                    else if (o->val && !strcmp(o->keyword, "hostaddr"))
                        hostaddr = o->val;
                }
                PQconninfoFree(options);
            }
            if (parseError)
                PQfreemem(parseError);

            std::vector<std::string> names;
            if (!hostaddr.empty())
                return names;
            if (hosts.empty())
                if (const char* env = getenv("PGHOST"))
                    hosts = env;
            size_t start = 0;
            while (start <= hosts.size())
            {
                size_t end = hosts.find(',', start);
                if (end == std::string::npos)
                    end = hosts.size();
                std::string host = hosts.substr(start, end - start);
                start = end + 1;
                while (!host.empty() && isspace(static_cast<unsigned char>(host.back())))
                    host.pop_back();
                while (!host.empty() && isspace(static_cast<unsigned char>(host.front())))
                    host.erase(0, 1);
                unsigned char addr[sizeof(in6_addr)];
                if (host.empty() || host[0] == '/' || host[0] == '@' || inet_pton(AF_INET, host.c_str(), addr) == 1 ||
                    inet_pton(AF_INET6, host.c_str(), addr) == 1)
                    continue;
                names.push_back(host);
            }
            return names;
        }

        struct Lookup
        {
            std::mutex              mutex;
            std::condition_variable cond;
            bool                    done = false;
        };
    }

    // ---------------------------------------------------------------------------------
    // CompletionQueue
    // ---------------------------------------------------------------------------------

    void CompletionQueue::Push(std::vector<JobPtr>& jobs)
    {
        if (jobs.empty())
            return;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            for (auto& job : jobs)
                m_items.push_back(std::move(job));
            m_size.store(m_items.size(), std::memory_order_release);
        }
        jobs.clear();
        m_cond.notify_all();
    }

    void CompletionQueue::Push(JobPtr job)
    {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_items.push_back(std::move(job));
            m_size.store(m_items.size(), std::memory_order_release);
        }
        m_cond.notify_all();
    }

    void CompletionQueue::TakeAll(std::vector<JobPtr>& out)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (out.empty())
            out.swap(m_items);
        else
        {
            for (auto& job : m_items)
                out.push_back(std::move(job));
            m_items.clear();
        }
        m_size.store(0, std::memory_order_release);
    }

    JobPtr CompletionQueue::WaitFor(uint64_t id, std::chrono::milliseconds timeout, std::vector<JobPtr>& stash)
    {
        const auto                   deadline = Clock::now() + timeout;
        std::unique_lock<std::mutex> lock(m_mutex);
        for (;;)
        {
            JobPtr found;
            for (auto& job : m_items)
            {
                if (!found && job->id == id)
                    found = std::move(job);
                else
                    stash.push_back(std::move(job));
            }
            m_items.clear();
            m_size.store(0, std::memory_order_release);
            if (found)
                return found;
            if (Clock::now() >= deadline)
                return nullptr;
            m_cond.wait_until(lock, deadline);
        }
    }

    // ---------------------------------------------------------------------------------
    // Worker: owns one PGconn and one thread
    // ---------------------------------------------------------------------------------

    class Worker
    {
    public:
        Worker(Pool& pool, int index) : m_pool(pool), m_index(index) {}
        ~Worker() { Join(); }

        void Start() { m_thread = std::thread(&Worker::Run, this); }
        void Join()
        {
            if (m_thread.joinable())
                m_thread.join();
        }

    private:
        void Run();
        void Loop();
        bool Connect();
        bool ResolveHosts(Clock::time_point deadline);
        void Disconnect();
        bool EnsureConnected();
        void ConnectFailed(std::string error, bool backoff);

        void   ProcessBatch(std::vector<JobPtr>& batch, std::vector<JobPtr>& done, std::vector<JobPtr>& requeue);
        bool   RunSimple(Job& job);
        size_t RunPipeline(std::vector<JobPtr>& batch, size_t begin, size_t end);
        bool   SendJob(Job& job);
        bool   HandleResult(Job& job, Statement& st, int stmtNumber, PGresult* res, bool pipeline);
        void   HandleInternalResult(Job& job, PGresult* res);
        bool   SendStatement(Statement& st);
        bool   SendInternal(const char* sql);
        void   EndTransactionBlock(Job* job);
        bool   ExecInternal(const char* sql, std::string& error, int timeoutMs);

        bool Pump();
        int  WaitSocket(int fd, short events, int timeoutMs, short* revents);
        void CancelRunningQuery(Clock::time_point deadline);
        void DrainNotifications();
        void FailInFlight(Job& job);

        // Notices, warnings, and errors that arrive while no query is running (such as the
        // FATAL sent by pg_terminate_backend or a server shutdown).
        static void OnNotice(void* arg, const PGresult* res)
        {
            const char* severity = PQresultErrorField(res, PG_DIAG_SEVERITY_NONLOCALIZED);
            if (severity && (!strcmp(severity, "FATAL") || !strcmp(severity, "PANIC")))
                static_cast<Worker*>(arg)->m_serverClosing = true;
        }

        static bool IsSimple(const Job& job) { return !job.transaction && job.stmts.size() == 1 && job.stmts[0].simpleProtocol; }
        static bool RunsAlone(const Job& job) { return job.transaction || IsSimple(job); }

        Pool&       m_pool;
        const int   m_index;
        std::thread m_thread;

        PGconn*           m_conn = nullptr;
        bool              m_broken = false;         // drop and reconnect before the next batch
        bool              m_serverClosing = false;  // server sent FATAL/PANIC: session is ending
        bool              m_canceled = false;       // the pool is aborting and we sent a cancel
        Clock::time_point m_abortDeadline{};
        bool              m_counted = false;        // included in Pool::m_connected
        bool              m_everConnected = false;
        std::string       m_lastError;
        Clock::time_point m_retryAt{};
        int               m_backoffMs = 0;

        std::vector<const char*> m_values;  // scratch for PQsendQueryParams
    };

    void Worker::Run()
    {
        char name[16];
        snprintf(name, sizeof(name), "pgsql-%llu-%d", static_cast<unsigned long long>(m_pool.Id() % 1000), m_index);
        pthread_setname_np(pthread_self(), name);

        try
        {
            Loop();
        }
        catch (...)
        {
            // Only allocation failure can get here. The thread must still exit cleanly so
            // that shutdown can join it.
        }
        Disconnect();
        m_pool.WorkerExited();
    }

    void Worker::Loop()
    {
        const bool ok = Connect();
        m_pool.ReportConnectAttempt(ok, m_lastError);

        std::vector<JobPtr> batch, done, requeue;
        for (;;)
        {
            // Reconnect proactively so a connection is ready when work arrives.
            if (!m_conn && !m_pool.IsAborting() && Clock::now() >= m_retryAt)
                Connect();
            if (!m_pool.TakeBatch(batch, m_conn != nullptr, m_retryAt))
                break;
            if (batch.empty())
                continue;  // woke up to retry connecting
            try
            {
                ProcessBatch(batch, done, requeue);
            }
            catch (const std::exception& e)
            {
                for (auto& job : batch)
                {
                    if (!job)
                        continue;
                    job->Fail(kStateConnectionLost, std::string("internal error while running the query: ") + e.what());
                    done.push_back(std::move(job));
                }
                Disconnect();
            }
            batch.clear();
            m_pool.Requeue(requeue, m_lastError);
            m_pool.Finish(done);
        }
    }

    void Worker::ConnectFailed(std::string error, bool backoff)
    {
        m_lastError = std::move(error);
        if (backoff)
        {
            m_backoffMs = m_backoffMs ? std::min(m_backoffMs * 2, kMaxBackoffMs) : kMinBackoffMs;
            m_retryAt = Clock::now() + std::chrono::milliseconds(m_backoffMs);
        }
    }

    bool Worker::Connect()
    {
        Disconnect();
        const PoolConfig& cfg = m_pool.Config();

        // Defaults come before "dbname" so that anything in the user's connection string
        // (expanded from dbname) overrides them. tcp_user_timeout bounds how long sent data
        // may stay unacknowledged (a silently dropped connection), which keepalives don't cover.
        const char* keys[] = {"client_encoding",     "fallback_application_name", "keepalives", "keepalives_idle",
                              "keepalives_interval", "keepalives_count",          "tcp_user_timeout", "dbname", nullptr};
        const char* values[] = {"UTF8", cfg.appName.c_str(), "1", "30", "10", "3", "60000", cfg.conninfo.c_str(), nullptr};

        const auto deadline = Clock::now() + std::chrono::milliseconds(cfg.connectTimeoutMs);
        if (!ResolveHosts(deadline))
            return false;

        PGconn* conn = PQconnectStartParams(keys, values, 1);
        if (!conn)
        {
            ConnectFailed("out of memory", true);
            return false;
        }
        if (PQstatus(conn) == CONNECTION_BAD)
        {
            ConnectFailed(Trimmed(PQerrorMessage(conn)), true);
            PQfinish(conn);
            return false;
        }
        // Replaces libpq's default (printing to stderr, i.e. the server console).
        m_serverClosing = false;
        PQsetNoticeReceiver(conn, &Worker::OnNotice, this);

        // Non-blocking handshake so that a hung server or an abort never pins this thread
        // longer than one tick past the deadline.
        PostgresPollingStatusType status = PGRES_POLLING_WRITING;
        while (status != PGRES_POLLING_OK)
        {
            if (status == PGRES_POLLING_FAILED)
            {
                ConnectFailed(Trimmed(PQerrorMessage(conn)), true);
                PQfinish(conn);
                return false;
            }
            for (;;)
            {
                if (m_pool.IsAborting())
                {
                    ConnectFailed("connection attempt canceled", false);
                    PQfinish(conn);
                    return false;
                }
                const int left = MillisUntil(deadline);
                if (left == 0)
                {
                    ConnectFailed("timeout expired while connecting", true);
                    PQfinish(conn);
                    return false;
                }
                short     revents = 0;
                const int rc = WaitSocket(PQsocket(conn), status == PGRES_POLLING_READING ? POLLIN : POLLOUT, std::min(left, kTickMs), &revents);
                if (rc < 0)
                {
                    ConnectFailed("invalid socket while connecting", true);
                    PQfinish(conn);
                    return false;
                }
                if (rc > 0)
                    break;
            }
            status = PQconnectPoll(conn);
        }

        if (PQsetnonblocking(conn, 1) != 0)
        {
            ConnectFailed(Trimmed(PQerrorMessage(conn)), true);
            PQfinish(conn);
            return false;
        }
        m_conn = conn;
        m_broken = false;

        if (cfg.statementTimeoutMs > 0)
        {
            char        sql[64];
            std::string error;
            snprintf(sql, sizeof(sql), "SET statement_timeout = %d", cfg.statementTimeoutMs);
            if (!ExecInternal(sql, error, cfg.connectTimeoutMs))
            {
                Disconnect();
                ConnectFailed("session setup failed: " + error, true);
                return false;
            }
        }

        m_backoffMs = 0;
        m_retryAt = {};
        m_counted = true;
        m_pool.m_connected.fetch_add(1, std::memory_order_relaxed);
        if (m_everConnected)
            m_pool.m_reconnects.fetch_add(1, std::memory_order_relaxed);
        m_everConnected = true;
        return true;
    }

    // libpq resolves host names with a blocking getaddrinfo inside PQconnectPoll, which
    // neither connectTimeout nor an abort can interrupt: an unresponsive DNS server would pin
    // this thread (and with it server shutdown) for the resolver's full timeout. Look the
    // names up on a detached helper first and give up at the deadline; a late helper just
    // finishes on its own (the module is linked -z nodelete, so its code stays mapped).
    // Lookup failures are left to libpq, which may still fail over to another host.
    bool Worker::ResolveHosts(Clock::time_point deadline)
    {
        for (const std::string& host : m_pool.m_resolveHosts)
        {
            auto lookup = std::make_shared<Lookup>();
            try
            {
                std::thread([lookup, host] {
                    pthread_setname_np(pthread_self(), "mlpg-dns");  // not a worker: may outlive shutdown
                    addrinfo hints{};
                    hints.ai_family = AF_UNSPEC;
                    hints.ai_socktype = SOCK_STREAM;
                    addrinfo* result = nullptr;
                    if (getaddrinfo(host.c_str(), nullptr, &hints, &result) == 0 && result)
                        freeaddrinfo(result);
                    {
                        std::lock_guard<std::mutex> lock(lookup->mutex);
                        lookup->done = true;
                    }
                    lookup->cond.notify_all();
                }).detach();
            }
            catch (const std::system_error&)
            {
                continue;  // cannot spawn a thread: let libpq resolve it directly
            }
            std::unique_lock<std::mutex> lock(lookup->mutex);
            while (!lookup->done)
            {
                if (m_pool.IsAborting())
                {
                    ConnectFailed("connection attempt canceled", false);
                    return false;
                }
                if (Clock::now() >= deadline)
                {
                    ConnectFailed("timeout expired while resolving host name \"" + host + "\"", true);
                    return false;
                }
                lookup->cond.wait_for(lock, std::chrono::milliseconds(kTickMs));
            }
        }
        return true;
    }

    void Worker::Disconnect()
    {
        if (m_conn)
        {
            PQfinish(m_conn);
            m_conn = nullptr;
        }
        if (m_counted)
        {
            m_counted = false;
            m_pool.m_connected.fetch_sub(1, std::memory_order_relaxed);
            // Disconnected workers that were leaving jobs to us must re-evaluate.
            std::lock_guard<std::mutex> lock(m_pool.m_mutex);
            m_pool.m_cond.notify_all();
        }
        m_broken = false;
    }

    bool Worker::EnsureConnected()
    {
        if (m_conn && !m_broken && PQstatus(m_conn) == CONNECTION_OK)
        {
            // Anything readable on an idle connection is a notification, a parameter
            // status change, or the server terminating the session (restart, idle timeout,
            // pg_terminate_backend). A termination arrives as a FATAL message (which libpq
            // hands to the notice receiver while idle, see OnNotice) followed by EOF, so
            // keep reading while there is something to read.
            for (int i = 0; i < 4 && !m_broken; ++i)
            {
                short revents = 0;
                if (WaitSocket(PQsocket(m_conn), POLLIN, 0, &revents) == 0)
                    break;
                if (!PQconsumeInput(m_conn) || PQstatus(m_conn) != CONNECTION_OK)
                    m_broken = true;
            }
            if (m_serverClosing)
                m_broken = true;
            const PGTransactionStatusType tx = PQtransactionStatus(m_conn);
            if (tx == PQTRANS_ACTIVE || tx == PQTRANS_UNKNOWN)
                m_broken = true;
            if (!m_broken)
            {
                DrainNotifications();
                return true;
            }
            m_lastError = Trimmed(PQerrorMessage(m_conn));
        }
        Disconnect();
        if (Clock::now() < m_retryAt)
            return false;  // still backing off; m_lastError holds the previous failure
        return Connect();
    }

    int Worker::WaitSocket(int fd, short events, int timeoutMs, short* revents)
    {
        if (fd < 0)
            return -1;
        pollfd pfd{fd, events, 0};
        int    rc;
        do
            rc = poll(&pfd, 1, timeoutMs);
        while (rc < 0 && errno == EINTR);
        if (rc > 0)
            *revents = pfd.revents;
        return rc < 0 ? -1 : rc;
    }

    // Flush pending output and wait up to one tick for input. Returns false when the
    // connection failed. When the pool is aborting, the running query is cancelled and
    // results are still read for a short grace period, so a query that already committed is
    // not reported as cancelled.
    bool Worker::Pump()
    {
        if (m_pool.IsAborting())
        {
            if (!m_canceled)
            {
                // One budget for the cancel request and for reading late results, so a hung
                // server delays shutdown by at most kAbortGraceMs.
                m_canceled = true;
                m_abortDeadline = Clock::now() + std::chrono::milliseconds(kAbortGraceMs);
                CancelRunningQuery(m_abortDeadline);
            }
            else if (Clock::now() >= m_abortDeadline)
            {
                m_lastError = "the connection was closed while the query was running; its outcome is unknown";
                return false;
            }
        }

        const int flush = PQflush(m_conn);
        if (flush < 0)
        {
            m_lastError = Trimmed(PQerrorMessage(m_conn));
            return false;
        }
        short     revents = 0;
        const int rc = WaitSocket(PQsocket(m_conn), static_cast<short>(POLLIN | (flush == 1 ? POLLOUT : 0)), kTickMs, &revents);
        if (rc < 0)
        {
            m_lastError = "socket error";
            return false;
        }
        if (rc > 0 && (revents & (POLLIN | POLLERR | POLLHUP)) && !PQconsumeInput(m_conn))
        {
            m_lastError = Trimmed(PQerrorMessage(m_conn));
            return false;
        }
        return true;
    }

    void Worker::CancelRunningQuery(Clock::time_point deadline)
    {
        PGcancelConn* cancel = PQcancelCreate(m_conn);
        if (!cancel)
            return;
        if (PQcancelStart(cancel))
        {
            PostgresPollingStatusType status = PGRES_POLLING_WRITING;
            while (status != PGRES_POLLING_OK && status != PGRES_POLLING_FAILED)
            {
                const int left = MillisUntil(deadline);
                short     revents = 0;
                if (left == 0 || WaitSocket(PQcancelSocket(cancel), status == PGRES_POLLING_READING ? POLLIN : POLLOUT, left, &revents) <= 0)
                    break;
                status = PQcancelPoll(cancel);
            }
        }
        PQcancelFinish(cancel);
    }

    void Worker::DrainNotifications()
    {
        // LISTEN is not exposed; free anything a script's LISTEN produced so it cannot pile up.
        while (PGnotify* notify = PQnotifies(m_conn))
            PQfreemem(notify);
    }

    bool Worker::ExecInternal(const char* sql, std::string& error, int timeoutMs)
    {
        if (!PQsendQuery(m_conn, sql))
        {
            error = Trimmed(PQerrorMessage(m_conn));
            m_broken = true;
            return false;
        }
        const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
        bool       ok = true;
        for (;;)
        {
            while (PQisBusy(m_conn))
            {
                if (Clock::now() >= deadline)
                {
                    error = std::string("timeout running \"") + sql + "\"";
                    m_broken = true;
                    return false;
                }
                if (!Pump())
                {
                    error = m_lastError;
                    m_broken = true;
                    return false;
                }
            }
            PGresult* res = PQgetResult(m_conn);
            if (!res)
                break;
            const ExecStatusType status = PQresultStatus(res);
            if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK)
            {
                if (ok)
                    error = Trimmed(PQresultErrorMessage(res));
                ok = false;
            }
            PQclear(res);
        }
        return ok;
    }

    bool Worker::SendStatement(Statement& st)
    {
        const int count = static_cast<int>(st.paramOffsets.size());
        m_values.resize(st.paramOffsets.size());
        for (int i = 0; i < count; ++i)
        {
            const int32_t offset = st.paramOffsets[i];
            m_values[i] = offset < 0 ? nullptr : st.paramData.data() + offset;
        }
        return PQsendQueryParams(m_conn, st.sql.c_str(), count, nullptr, count ? m_values.data() : nullptr, nullptr, nullptr, 0) == 1;
    }

    bool Worker::SendInternal(const char* sql)
    {
        return PQsendQueryParams(m_conn, sql, 0, nullptr, nullptr, nullptr, nullptr, 0) == 1;
    }

    // A transaction is wrapped in an explicit BEGIN/COMMIT: an implicit block would only
    // start at the second statement, letting a first CALL/VACUUM/CREATE DATABASE run
    // outside it.
    bool Worker::SendJob(Job& job)
    {
        if (job.transaction && !SendInternal("BEGIN"))
            return false;
        for (Statement& st : job.stmts)
            if (!SendStatement(st))
                return false;
        return !job.transaction || SendInternal("COMMIT");
    }

    void Worker::FailInFlight(Job& job)
    {
        if (m_canceled)
            job.Fail(kStateConnectionLost, m_lastError);
        else
            job.Fail(kStateConnectionLost, "connection to PostgreSQL lost during query: " + m_lastError);
    }

    // Stores a result in its statement or records the error. Returns false when the
    // protocol state can no longer be trusted and the connection must be dropped.
    bool Worker::HandleResult(Job& job, Statement& st, int stmtNumber, PGresult* res, bool pipeline)
    {
        switch (PQresultStatus(res))
        {
            case PGRES_TUPLES_OK:
            case PGRES_COMMAND_OK:
            case PGRES_EMPTY_QUERY:
                st.result.reset(res);
                return true;

            case PGRES_PIPELINE_ABORTED:
                // Only follows an earlier error in the same transaction, which Fail() keeps.
                PQclear(res);
                job.Fail(kStateCanceled, "statement skipped because an earlier statement failed", stmtNumber);
                return true;

            case PGRES_COPY_IN:
                PQclear(res);
                if (pipeline)
                    break;
                for (;;)
                {
                    const int rc = PQputCopyEnd(m_conn, "COPY FROM STDIN is not supported by ml_pgsql");
                    if (rc == 1)
                        return true;  // the server answers with an error result for this statement
                    if (rc < 0 || !Pump())
                        return false;
                }

            case PGRES_COPY_OUT:
                PQclear(res);
                if (pipeline)
                    break;
                for (;;)
                {
                    char*     buffer = nullptr;
                    const int len = PQgetCopyData(m_conn, &buffer, 1);
                    if (len > 0)
                    {
                        PQfreemem(buffer);
                        continue;
                    }
                    if (len == 0)
                    {
                        if (!Pump())
                            return false;
                        continue;
                    }
                    return len == -1;  // -1: done, the COPY's command status follows
                }

            case PGRES_COPY_BOTH:
                PQclear(res);
                break;

            default:  // PGRES_FATAL_ERROR, PGRES_NONFATAL_ERROR, PGRES_BAD_RESPONSE
            {
                const char* state = PQresultErrorField(res, PG_DIAG_SQLSTATE);
                job.Fail(state ? state : kStateProtocol, Trimmed(PQresultErrorMessage(res)), stmtNumber);
                PQclear(res);
                return true;
            }
        }
        job.Fail(kStateProtocol, "COPY is not supported in this context", stmtNumber);
        m_lastError = "unsupported COPY";
        return false;
    }

    // Result of the BEGIN/COMMIT around a transaction. A failing COMMIT (e.g. a deferred
    // constraint or a serialization failure) fails the whole transaction.
    void Worker::HandleInternalResult(Job& job, PGresult* res)
    {
        const ExecStatusType status = PQresultStatus(res);
        if (status == PGRES_FATAL_ERROR || status == PGRES_NONFATAL_ERROR || status == PGRES_BAD_RESPONSE)
        {
            const char* state = PQresultErrorField(res, PG_DIAG_SQLSTATE);
            job.Fail(state ? state : kStateProtocol, Trimmed(PQresultErrorMessage(res)));
        }
        PQclear(res);
    }

    // A script or transaction must not leave the shared session inside a transaction
    // block: every later query on this connection would join (or, after an error, fail in)
    // it. Roll it back and tell the job that left it open.
    void Worker::EndTransactionBlock(Job* job)
    {
        if (m_broken || !m_conn)
            return;
        const PGTransactionStatusType tx = PQtransactionStatus(m_conn);
        if (tx != PQTRANS_INTRANS && tx != PQTRANS_INERROR)
            return;
        std::string error;
        if (!ExecInternal("ROLLBACK", error, m_pool.Config().connectTimeoutMs))
            m_broken = true;
        if (job && tx == PQTRANS_INTRANS)
            job->Fail(kStateTxState, "the query left a transaction block open, so it was rolled back "
                                     "(use pgTransaction, or end the script with COMMIT)");
    }

    // Simple query protocol: one job, possibly several ';'-separated commands.
    // Returns false if nothing was sent (the job can be retried on another connection).
    bool Worker::RunSimple(Job& job)
    {
        Statement& st = job.stmts[0];
        if (!PQsendQuery(m_conn, st.sql.c_str()))
        {
            m_lastError = Trimmed(PQerrorMessage(m_conn));
            m_broken = true;
            return false;
        }
        m_pool.m_roundTrips.fetch_add(1, std::memory_order_relaxed);

        bool healthy = true;
        while (healthy)
        {
            while (healthy && PQisBusy(m_conn))
                healthy = Pump();
            if (!healthy)
                break;
            PGresult* res = PQgetResult(m_conn);
            if (!res)
                break;
            healthy = HandleResult(job, st, 1, res, false);
        }

        if (!healthy || PQstatus(m_conn) != CONNECTION_OK)
        {
            m_broken = true;
            FailInFlight(job);
        }
        else if (job.error.empty())
            job.ok = true;
        return true;
    }

    // Extended protocol, pipelined: every job is its own sync segment (an implicit
    // transaction), so a failing job never affects its neighbours, while all of them share
    // one network round trip. A transaction job is several statements in one segment.
    // Returns how many jobs [begin, begin + n) have an outcome; the rest were not sent
    // (no Sync reached the server, so they cannot have committed) and may be retried.
    size_t Worker::RunPipeline(std::vector<JobPtr>& batch, size_t begin, size_t end)
    {
        if (!PQenterPipelineMode(m_conn))
        {
            m_lastError = Trimmed(PQerrorMessage(m_conn));
            m_broken = true;
            return 0;
        }

        size_t syncedEnd = begin;  // jobs whose Sync is queued: their results will arrive
        size_t sentEnd = begin;    // plus at most one job whose Sync may or may not have gone out
        for (size_t k = begin; k < end; ++k)
        {
            if (!SendJob(*batch[k]))
            {
                m_lastError = Trimmed(PQerrorMessage(m_conn));
                m_broken = true;
                break;
            }
            // Once the statements are buffered, a failing Sync may still have been queued
            // for sending: from here on the job counts as possibly executed.
            sentEnd = k + 1;
            if (PQsendPipelineSync(m_conn) != 1)
            {
                m_lastError = Trimmed(PQerrorMessage(m_conn));
                m_broken = true;
                break;
            }
            syncedEnd = k + 1;
        }
        if (sentEnd > begin)
            m_pool.m_roundTrips.fetch_add(1, std::memory_order_relaxed);

        // Result slots per job: its statements, plus the BEGIN/COMMIT around transactions.
        // libpq returns one or more results per slot followed by NULL, then the SYNC.
        size_t cur = begin;
        size_t slot = 0;
        bool   gotResult = false;  // current slot produced a result (its NULL terminator is next)
        int    idleNulls = 0;      // NULLs in a row without progress: libpq and we disagree
        bool   healthy = true;

        // Defense in depth for "BEGIN" slipping past the submit-time check: the jobs that ran
        // inside a block opened by a plain query must not be reported as committed unless a
        // later COMMIT in the same segment actually committed them.
        bool                blockOpen = false;
        std::vector<size_t> inBlock;
        auto failBlock = [&](const char* why) {
            for (size_t k : inBlock)
                batch[k]->Fail(kStateTxState, why);
            inBlock.clear();
            blockOpen = false;
        };

        while (healthy && cur < syncedEnd)
        {
            while (healthy && PQisBusy(m_conn))
                healthy = Pump();
            if (!healthy)
                break;

            Job&      job = *batch[cur];
            PGresult* res = PQgetResult(m_conn);
            if (!res)
            {
                if (gotResult)
                {
                    ++slot;
                    gotResult = false;
                    idleNulls = 0;
                }
                else if (++idleNulls > 2)
                {
                    m_lastError = "pipeline desynchronized";
                    healthy = false;
                }
                continue;
            }
            idleNulls = 0;
            if (PQresultStatus(res) == PGRES_PIPELINE_SYNC)
            {
                PQclear(res);
                if (job.error.empty())
                    job.ok = true;
                if (blockOpen)
                    inBlock.push_back(cur);
                ++cur;
                slot = 0;
                gotResult = false;
                continue;
            }
            gotResult = true;

            const size_t first = job.transaction ? 1 : 0;
            if (job.transaction && (slot == 0 || slot > job.stmts.size()))
            {
                if (PQresultStatus(res) == PGRES_PIPELINE_ABORTED)
                    PQclear(res);
                else
                    HandleInternalResult(job, res);
                continue;
            }
            const size_t index = std::min(slot - first, job.stmts.size() - 1);
            if (!HandleResult(job, job.stmts[index], static_cast<int>(index + 1), res, true))
                healthy = false;
            else if (!job.transaction && job.stmts[index].result)
            {
                const char* tag = PQcmdStatus(job.stmts[index].result.get());
                if (!strcmp(tag, "BEGIN") || !strcmp(tag, "START TRANSACTION"))
                {
                    blockOpen = true;
                    job.Fail(kStateTxState, "BEGIN cannot be sent on its own; use pgTransaction");
                }
                else if (blockOpen && !strcmp(tag, "COMMIT"))
                {
                    inBlock.clear();  // committed after all
                    blockOpen = false;
                }
                else if (blockOpen && !strcmp(tag, "ROLLBACK"))
                    failBlock("rolled back: an earlier query in the same batch opened a transaction block");
            }
        }
        if (blockOpen)
            failBlock("rolled back: an earlier query in the same batch opened a transaction block");

        if (!healthy || PQstatus(m_conn) != CONNECTION_OK)
            m_broken = true;
        for (size_t k = cur; k < sentEnd; ++k)  // unanswered, or Sync uncertain
            FailInFlight(*batch[k]);
        if (!m_broken && !PQexitPipelineMode(m_conn))
        {
            m_lastError = Trimmed(PQerrorMessage(m_conn));
            m_broken = true;
        }
        return sentEnd - begin;
    }

    void Worker::ProcessBatch(std::vector<JobPtr>& batch, std::vector<JobPtr>& done, std::vector<JobPtr>& requeue)
    {
        m_canceled = false;
        if (!EnsureConnected())
        {
            // Another connection may be fine: let it run these instead of failing them.
            if (m_pool.m_connected.load(std::memory_order_relaxed) > 0 && !m_pool.IsAborting())
            {
                for (auto& job : batch)
                    requeue.push_back(std::move(job));
                return;
            }
            for (auto& job : batch)
            {
                job->Fail(kStateCannotConnect, "could not connect to PostgreSQL: " + m_lastError);
                done.push_back(std::move(job));
            }
            return;
        }

        const size_t n = batch.size();
        size_t       i = 0;
        while (i < n && !m_broken)
        {
            Job& job = *batch[i];
            if (IsSimple(job))
            {
                if (!RunSimple(job))
                    break;
                EndTransactionBlock(&job);
                done.push_back(std::move(batch[i++]));
                continue;
            }
            // Transactions run as their own segment so a failure can be rolled back before
            // anything else uses the session.
            size_t segmentEnd = i + 1;
            if (!job.transaction)
                while (segmentEnd < n && !RunsAlone(*batch[segmentEnd]))
                    ++segmentEnd;
            const size_t finished = RunPipeline(batch, i, segmentEnd);
            EndTransactionBlock(job.transaction && finished == 1 ? &job : nullptr);
            for (size_t k = 0; k < finished; ++k)
                done.push_back(std::move(batch[i + k]));
            i += finished;
            if (finished == 0)
                break;
        }

        // Unsent jobs go back to the queue: another (or this, reconnected) connection runs them.
        for (; i < n; ++i)
            requeue.push_back(std::move(batch[i]));

        if (m_broken)
            Disconnect();
        else
            DrainNotifications();
    }

    // ---------------------------------------------------------------------------------
    // Pool
    // ---------------------------------------------------------------------------------

    Pool::Pool(uint64_t id, PoolConfig config, CompletionQueue& completions)
        : m_id(id),
          m_config(std::move(config)),
          m_completions(completions),
          m_resolveHosts(HostNamesToResolve(m_config.conninfo)),
          m_outstanding(std::make_shared<std::atomic<size_t>>(0))
    {
    }

    Pool::~Pool()
    {
        Abort();
        Join();
    }

    void Pool::Start()
    {
        // Workers must not receive process signals (SIGINT/SIGTERM/SIGPIPE...): those belong
        // to the server's main thread. Threads inherit the creator's mask.
        sigset_t all, previous;
        sigfillset(&all);
        pthread_sigmask(SIG_SETMASK, &all, &previous);
        try
        {
            m_workers.reserve(m_config.size);
            for (int i = 0; i < m_config.size; ++i)
            {
                m_workers.push_back(std::make_unique<Worker>(*this, i));
                m_liveWorkers.fetch_add(1, std::memory_order_acq_rel);
                try
                {
                    m_workers.back()->Start();
                }
                catch (...)
                {
                    m_liveWorkers.fetch_sub(1, std::memory_order_acq_rel);
                    m_workers.pop_back();
                    throw;
                }
            }
        }
        catch (...)
        {
            pthread_sigmask(SIG_SETMASK, &previous, nullptr);
            Abort();
            throw;
        }
        pthread_sigmask(SIG_SETMASK, &previous, nullptr);
    }

    Pool::SubmitResult Pool::Submit(JobPtr& job)
    {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            if (m_closing.load(std::memory_order_relaxed))
                return SubmitResult::Closed;
            if (m_outstanding->load(std::memory_order_acquire) >= m_config.maxQueue)
                return SubmitResult::QueueFull;
            m_outstanding->fetch_add(1, std::memory_order_acq_rel);
            job->outstanding = m_outstanding;
            job->queuedAt = Clock::now();
            m_queue.push_back(std::move(job));
        }
        m_submitted.fetch_add(1, std::memory_order_relaxed);
        m_cond.notify_all();  // see TakeBatch: disconnected workers may be waiting too
        return SubmitResult::Ok;
    }

    bool Pool::TakeBatch(std::vector<JobPtr>& batch, bool connected, Clock::time_point retryAt)
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        for (;;)
        {
            if (m_aborting.load(std::memory_order_relaxed))
                return false;
            // Without a connection, leave the work to a connected worker if there is one.
            // If none is connected, take it anyway so it fails fast instead of piling up.
            const bool deferToOthers = !connected && m_connected.load(std::memory_order_relaxed) > 0;
            if (!m_queue.empty() && !deferToOthers)
            {
                // Share a backlog between connections, but pipeline as much as possible.
                const size_t share = (m_queue.size() + m_config.size - 1) / m_config.size;
                const size_t count = std::min(std::max<size_t>(share, 1), static_cast<size_t>(m_config.maxBatch));
                for (size_t i = 0; i < count; ++i)
                {
                    batch.push_back(std::move(m_queue.front()));
                    m_queue.pop_front();
                }
                m_inFlight += count;
                return true;
            }
            if (m_queue.empty() && m_closing.load(std::memory_order_relaxed))
                return false;
            if (!connected)
            {
                if (Clock::now() >= retryAt)
                    return true;  // empty batch: time to retry connecting
                m_cond.wait_until(lock, retryAt);
            }
            else
                m_cond.wait(lock);
        }
    }

    void Pool::Requeue(std::vector<JobPtr>& jobs, const std::string& lastError)
    {
        if (jobs.empty())
            return;
        std::vector<JobPtr> failed;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_inFlight -= jobs.size();
            const bool aborting = m_aborting.load(std::memory_order_relaxed);
            for (auto it = jobs.rbegin(); it != jobs.rend(); ++it)
            {
                JobPtr& job = *it;
                if (aborting)
                    job->Fail(kStateCanceled, "canceling statement: connection was closed before it could run");
                else if (++job->sendAttempts > kMaxSendAttempts)
                    job->Fail(kStateConnectionLost, "could not send the query to PostgreSQL: " + lastError);
                else
                {
                    m_queue.push_front(std::move(job));
                    continue;
                }
                failed.push_back(std::move(job));
            }
        }
        jobs.clear();
        m_cond.notify_all();
        if (!failed.empty())
        {
            std::reverse(failed.begin(), failed.end());
            m_failed.fetch_add(failed.size(), std::memory_order_relaxed);
            m_completions.Push(failed);
        }
    }

    void Pool::Finish(std::vector<JobPtr>& jobs)
    {
        if (jobs.empty())
            return;
        const auto now = Clock::now();
        uint64_t   ok = 0, latencyUs = 0;
        for (const auto& job : jobs)
        {
            ok += job->ok ? 1 : 0;
            latencyUs += std::chrono::duration_cast<std::chrono::microseconds>(now - job->queuedAt).count();
        }
        m_succeeded.fetch_add(ok, std::memory_order_relaxed);
        m_failed.fetch_add(jobs.size() - ok, std::memory_order_relaxed);
        m_latencyUsTotal.fetch_add(latencyUs, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_inFlight -= jobs.size();
        }
        m_completions.Push(jobs);
    }

    void Pool::ReportConnectAttempt(bool ok, const std::string& error)
    {
        {
            std::lock_guard<std::mutex> lock(m_readyMutex);
            if (ok)
                ++m_readyOk;
            else
            {
                ++m_readyFailed;
                if (m_readyError.empty())
                    m_readyError = error;
            }
        }
        m_readyCond.notify_all();
    }

    bool Pool::WaitReady(int timeoutMs, std::string& error)
    {
        std::unique_lock<std::mutex> lock(m_readyMutex);
        m_readyCond.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                             [&] { return m_readyOk > 0 || m_readyFailed >= m_config.size || IsAborting(); });
        if (m_readyOk > 0)
            return true;
        error = !m_readyError.empty() ? m_readyError : std::string("timeout expired while connecting");
        return false;
    }

    void Pool::WorkerExited()
    {
        m_liveWorkers.fetch_sub(1, std::memory_order_acq_rel);
    }

    void Pool::Close()
    {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_closing.store(true, std::memory_order_release);
        }
        m_cond.notify_all();
    }

    void Pool::Abort()
    {
        std::vector<JobPtr> canceled;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_closing.store(true, std::memory_order_release);
            m_aborting.store(true, std::memory_order_release);
            while (!m_queue.empty())
            {
                canceled.push_back(std::move(m_queue.front()));
                m_queue.pop_front();
            }
        }
        m_cond.notify_all();
        {
            std::lock_guard<std::mutex> lock(m_readyMutex);  // pairs with WaitReady's predicate
        }
        m_readyCond.notify_all();
        if (!canceled.empty())
        {
            for (auto& job : canceled)
                job->Fail(kStateCanceled, "canceling statement: connection was closed before it could run");
            m_failed.fetch_add(canceled.size(), std::memory_order_relaxed);
            m_completions.Push(canceled);
        }
    }

    void Pool::Join()
    {
        for (auto& worker : m_workers)
            worker->Join();
    }

    PoolStats Pool::Stats()
    {
        PoolStats s;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            s.queued = m_queue.size();
            s.inFlight = m_inFlight;
        }
        s.outstanding = m_outstanding->load(std::memory_order_relaxed);
        s.connected = m_connected.load(std::memory_order_relaxed);
        s.submitted = m_submitted.load(std::memory_order_relaxed);
        s.succeeded = m_succeeded.load(std::memory_order_relaxed);
        s.failed = m_failed.load(std::memory_order_relaxed);
        s.reconnects = m_reconnects.load(std::memory_order_relaxed);
        s.roundTrips = m_roundTrips.load(std::memory_order_relaxed);
        const uint64_t completed = s.succeeded + s.failed;
        s.avgLatencyMs = completed ? m_latencyUsTotal.load(std::memory_order_relaxed) / 1000.0 / completed : 0.0;
        return s;
    }
}
