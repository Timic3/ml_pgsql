#include "proxy.h"

#include <algorithm>

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace host
{
    bool Proxy::Start(int listenPort, const std::string& targetHost, int targetPort, std::string& error)
    {
        if (Running())
        {
            error = "proxy already running";
            return false;
        }
        addrinfo hints{};
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        addrinfo* res = nullptr;
        const std::string port = std::to_string(targetPort);
        if (getaddrinfo(targetHost.c_str(), port.c_str(), &hints, &res) != 0 || !res)
        {
            error = "cannot resolve " + targetHost;
            return false;
        }
        memcpy(&m_target, res->ai_addr, sizeof(m_target));
        freeaddrinfo(res);

        m_listenPort = listenPort;
        if (!OpenListener())
        {
            error = std::string("cannot listen: ") + strerror(errno);
            return false;
        }
        m_stop = false;
        m_thread = std::thread(&Proxy::Run, this);
        return true;
    }

    void Proxy::Stop()
    {
        if (!m_thread.joinable())
            return;
        m_stop = true;
        m_thread.join();
        for (Conn& c : m_conns)
            CloseConn(c);
        m_conns.clear();
        CloseListener();
    }

    void Proxy::SetMode(Mode mode)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_mode = mode;
    }

    int Proxy::KillAll()
    {
        if (!Running())
            return 0;
        std::unique_lock<std::mutex> lock(m_mutex);
        const int ticket = ++m_killRequests;
        m_cond.wait_for(lock, std::chrono::seconds(5), [&] { return m_killServed >= ticket; });
        return m_lastKilled;
    }

    bool Proxy::OpenListener()
    {
        if (m_listenFd >= 0)
            return true;
        const int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0)
            return false;
        const int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(m_listenPort));
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || listen(fd, 128) != 0)
        {
            const int saved = errno;
            close(fd);
            errno = saved;
            return false;
        }
        m_listenFd = fd;
        return true;
    }

    void Proxy::CloseListener()
    {
        if (m_listenFd >= 0)
        {
            close(m_listenFd);
            m_listenFd = -1;
        }
    }

    void Proxy::CloseConn(Conn& c)
    {
        if (c.client >= 0)
        {
            close(c.client);
            c.client = -1;
            m_active.fetch_sub(1);
        }
        if (c.upstream >= 0)
        {
            close(c.upstream);
            c.upstream = -1;
        }
    }

    // Non-blocking I/O with per-direction buffers: the proxy must never block, or it could
    // deadlock with a server that is busy writing results nobody reads.
    bool Proxy::ReadInto(int from, std::string& buffer)
    {
        char          buf[65536];
        const ssize_t n = recv(from, buf, sizeof(buf), 0);
        if (n < 0)
            return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
        if (n == 0)
            return false;
        buffer.append(buf, static_cast<size_t>(n));
        return true;
    }

    bool Proxy::Flush(int to, std::string& buffer)
    {
        while (!buffer.empty())
        {
            const ssize_t w = send(to, buffer.data(), buffer.size(), MSG_NOSIGNAL);
            if (w < 0)
                return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
            buffer.erase(0, static_cast<size_t>(w));
        }
        return true;
    }

    void Proxy::Run()
    {
        Mode mode = Mode::Up;
        while (!m_stop.load())
        {
            int killTicket = 0;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                mode = m_mode;
                if (m_killRequests > m_killServed)
                    killTicket = m_killRequests;
            }
            if (killTicket)
            {
                int killed = 0;
                for (Conn& c : m_conns)
                {
                    if (c.client >= 0)
                    {
                        // RST instead of FIN: the client sees the session die abruptly.
                        linger lg{1, 0};
                        setsockopt(c.client, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
                        ++killed;
                    }
                    CloseConn(c);
                }
                m_conns.clear();
                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    m_killServed = killTicket;
                    m_lastKilled = killed;
                }
                m_cond.notify_all();
            }

            if (mode == Mode::Refuse)
                CloseListener();
            else
                OpenListener();

            std::vector<pollfd> fds;
            if (m_listenFd >= 0)
                fds.push_back({m_listenFd, POLLIN, 0});
            const size_t base = fds.size();
            for (const Conn& c : m_conns)
            {
                // Frozen while blackholed: nothing moves either way. Otherwise read a side
                // only while the other direction has room (backpressure), write when pending.
                short evClient = 0, evUp = 0;
                if (mode != Mode::Blackhole)
                {
                    if (c.toUpstream.size() < (1u << 20))
                        evClient |= POLLIN;
                    if (!c.toClient.empty())
                        evClient |= POLLOUT;
                    if (c.toClient.size() < (1u << 20))
                        evUp |= POLLIN;
                    if (!c.toUpstream.empty())
                        evUp |= POLLOUT;
                }
                fds.push_back({c.client, evClient, 0});
                fds.push_back({c.upstream, evUp, 0});
            }
            const int rc = poll(fds.data(), fds.size(), 20);
            if (rc <= 0)
                continue;

            if (m_listenFd >= 0 && (fds[0].revents & POLLIN))
            {
                for (;;)
                {
                    const int client = accept4(m_listenFd, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
                    if (client < 0)
                        break;
                    m_accepted.fetch_add(1);
                    m_active.fetch_add(1);
                    Conn c;
                    c.client = client;
                    if (mode == Mode::Up)
                    {
                        const int up = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
                        if (up < 0 || connect(up, reinterpret_cast<const sockaddr*>(&m_target), sizeof(m_target)) != 0)
                        {
                            if (up >= 0)
                                close(up);
                            CloseConn(c);
                            continue;
                        }
                        fcntl(up, F_SETFL, fcntl(up, F_GETFL) | O_NONBLOCK);
                        const int one = 1;
                        setsockopt(up, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                        c.upstream = up;
                    }
                    m_conns.push_back(std::move(c));
                }
            }

            const size_t n = std::min(m_conns.size(), (fds.size() - base) / 2);
            for (size_t i = 0; i < n; ++i)
            {
                Conn&       c = m_conns[i];
                const short rcClient = fds[base + i * 2].revents;
                const short rcUp = fds[base + i * 2 + 1].revents;
                bool        ok = true;
                if (rcClient & (POLLIN | POLLHUP | POLLERR))
                {
                    ok = ReadInto(c.client, c.toUpstream);
                    if (c.upstream < 0)
                        c.toUpstream.clear();  // blackholed: swallow
                }
                if (ok && c.upstream >= 0 && (rcUp & (POLLIN | POLLHUP | POLLERR)))
                    ok = ReadInto(c.upstream, c.toClient);
                if (ok && c.upstream >= 0 && !c.toUpstream.empty())
                    ok = Flush(c.upstream, c.toUpstream);
                if (ok && !c.toClient.empty())
                    ok = Flush(c.client, c.toClient);
                if (!ok)
                {
                    // deliver what the server already sent before closing the client side
                    if (c.client >= 0 && !c.toClient.empty())
                        send(c.client, c.toClient.data(), c.toClient.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
                    CloseConn(c);
                }
            }
            for (size_t i = 0; i < m_conns.size();)
            {
                if (m_conns[i].client < 0)
                {
                    CloseConn(m_conns[i]);
                    m_conns.erase(m_conns.begin() + static_cast<std::ptrdiff_t>(i));
                }
                else
                    ++i;
            }
        }
    }
}
