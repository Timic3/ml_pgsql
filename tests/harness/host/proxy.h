#pragma once

// Tiny TCP forwarder used to simulate PostgreSQL outages from inside a scenario:
//   up        - accept and forward
//   refuse    - no listener: new connections get ECONNREFUSED (existing ones keep working)
//   blackhole - accept but never forward; existing connections are frozen too (a hung server)
// killAll() closes every proxied connection (the client sees the server vanish).

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <netinet/in.h>

namespace host
{
    class Proxy
    {
    public:
        enum class Mode
        {
            Up,
            Refuse,
            Blackhole,
        };

        ~Proxy() { Stop(); }

        bool Start(int listenPort, const std::string& targetHost, int targetPort, std::string& error);
        void Stop();
        bool Running() const { return m_thread.joinable(); }

        void SetMode(Mode mode);
        int  KillAll();  // returns the number of connections closed
        int  Accepted() const { return m_accepted.load(); }
        int  Active() const { return m_active.load(); }

    private:
        struct Conn
        {
            int         client = -1;
            int         upstream = -1;  // -1: blackholed
            std::string toUpstream;     // pending bytes client -> server
            std::string toClient;       // pending bytes server -> client
        };

        void Run();
        bool OpenListener();
        void CloseListener();
        void CloseConn(Conn& c);
        static bool ReadInto(int from, std::string& buffer);
        static bool Flush(int to, std::string& buffer);

        std::thread       m_thread;
        std::atomic<bool> m_stop{false};
        int               m_listenPort = 0;
        sockaddr_in       m_target{};
        int               m_listenFd = -1;
        std::vector<Conn> m_conns;  // proxy thread only

        std::mutex              m_mutex;
        std::condition_variable m_cond;
        Mode                    m_mode = Mode::Up;       // requested (guarded by m_mutex)
        int                     m_killRequests = 0;      // guarded by m_mutex
        int                     m_killServed = 0;        // guarded by m_mutex
        int                     m_lastKilled = 0;        // guarded by m_mutex
        std::atomic<int>        m_accepted{0};
        std::atomic<int>        m_active{0};
    };
}
