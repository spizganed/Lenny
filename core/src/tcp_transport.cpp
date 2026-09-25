// TCP over Winsock or BSD sockets. This file is the one allowed OS #if in the core (architecture.md §4):
// the sockets API is the same everywhere apart from init, close, error codes and non-blocking mode.
#include "transport.hpp"

#include <chrono>
#include <cstring>
#include <mutex>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  define NOMINMAX
#  include <winsock2.h>
#  include <ws2tcpip.h>
using socket_t = SOCKET;
constexpr socket_t kInvalid = INVALID_SOCKET;
#else
#  include <arpa/inet.h>
#  include <fcntl.h>
#  include <netdb.h>
#  include <netinet/in.h>
#  include <netinet/tcp.h>
#  include <poll.h>
#  include <sys/socket.h>
#  include <unistd.h>
#  include <cerrno>
using socket_t = int;
constexpr socket_t kInvalid = -1;
#endif

namespace lenny {
namespace {

#if defined(_WIN32)
void net_init() {
    static std::once_flag once;
    std::call_once(once, [] {
        WSADATA d;
        WSAStartup(MAKEWORD(2, 2), &d);  // never WSACleanup: sockets may outlive static destructors
    });
}
void close_socket(socket_t s) { closesocket(s); }
void set_nonblocking(socket_t s, bool on) {
    u_long v = on ? 1 : 0;
    ioctlsocket(s, FIONBIO, &v);
}
bool connect_in_progress() { return WSAGetLastError() == WSAEWOULDBLOCK; }
constexpr int kSendFlags = 0;
constexpr int kShutBoth = SD_BOTH;
#else
void net_init() {}
void close_socket(socket_t s) { ::close(s); }
void set_nonblocking(socket_t s, bool on) {
    int f = fcntl(s, F_GETFL, 0);
    fcntl(s, F_SETFL, on ? (f | O_NONBLOCK) : (f & ~O_NONBLOCK));
}
bool connect_in_progress() { return errno == EINPROGRESS; }
#  if defined(MSG_NOSIGNAL)
constexpr int kSendFlags = MSG_NOSIGNAL;  // a dead peer must not SIGPIPE-kill the app
#  else
constexpr int kSendFlags = 0;             // Apple: SO_NOSIGPIPE set per socket below
#  endif
constexpr int kShutBoth = SHUT_RDWR;
#endif

// 1 = ready, 0 = timeout, -1 = error.
int wait_socket(socket_t s, bool for_write, int timeout_ms) {
#if defined(_WIN32)
    // select() on Windows has no FD_SETSIZE limit on socket values, unlike POSIX.
    fd_set set;
    FD_ZERO(&set);
    FD_SET(s, &set);
    fd_set err;
    FD_ZERO(&err);
    FD_SET(s, &err);
    timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    int r = select(0, for_write ? nullptr : &set, for_write ? &set : nullptr, &err, &tv);
    if (r < 0) return -1;
    if (r == 0) return 0;
    // Windows reports a failed non-blocking connect via the except set, not writability.
    return FD_ISSET(s, &err) && !FD_ISSET(s, &set) ? -1 : 1;
#else
    pollfd p{s, static_cast<short>(for_write ? POLLOUT : POLLIN), 0};
    int r;
    do r = poll(&p, 1, timeout_ms); while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    return r == 0 ? 0 : 1;
#endif
}

void tune(socket_t s) {
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof one);
#if defined(SO_NOSIGPIPE)
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}

class TcpTransport final : public ITransport {
public:
    explicit TcpTransport(socket_t s) : s_(s) { tune(s_); }
    ~TcpTransport() override { close_socket(s_); }

    int recv(uint8_t* buf, size_t size, int timeout_ms) override {
        int w = wait_socket(s_, false, timeout_ms);
        if (w <= 0) return w;
        auto n = ::recv(s_, reinterpret_cast<char*>(buf), static_cast<int>(size), 0);
        return n > 0 ? static_cast<int>(n) : -1;  // 0 = orderly close
    }

    bool send_all(const uint8_t* data, size_t size) override {
        while (size > 0) {
            auto n = ::send(s_, reinterpret_cast<const char*>(data), static_cast<int>(size), kSendFlags);
            if (n <= 0) {
#if !defined(_WIN32)
                if (n < 0 && errno == EINTR) continue;
#endif
                return false;
            }
            data += n;
            size -= static_cast<size_t>(n);
        }
        return true;
    }

    void shutdown() override { ::shutdown(s_, kShutBoth); }

private:
    socket_t s_;
};

}  // namespace

std::unique_ptr<ITransport> tcp_connect(const std::string& host, uint16_t port, int timeout_ms,
                                        const std::atomic<bool>& cancel) {
    net_init();
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    addrinfo* res = nullptr;
    const std::string port_str = std::to_string(port);
    if (getaddrinfo(host.c_str(), port_str.c_str(), &hints, &res) != 0) return nullptr;

    std::unique_ptr<ITransport> out;
    for (addrinfo* ai = res; ai && !out && !cancel; ai = ai->ai_next) {
        socket_t s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == kInvalid) continue;
        // Non-blocking connect: a blocking one to an unreachable IP hangs ~21 s on Windows.
        set_nonblocking(s, true);
        bool ok = ::connect(s, ai->ai_addr, static_cast<int>(ai->ai_addrlen)) == 0;
        if (!ok && connect_in_progress()) {
            // Poll in slices so a disconnect() doesn't wait out the whole timeout.
            for (int waited = 0; waited < timeout_ms && !cancel; waited += 100) {
                int w = wait_socket(s, true, 100);
                if (w < 0) break;
                if (w == 0) continue;
                int err = 0;
                socklen_t len = sizeof err;
                getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
                ok = err == 0;
                break;
            }
        }
        if (ok) {
            set_nonblocking(s, false);
            out = std::make_unique<TcpTransport>(s);
        } else {
            close_socket(s);
        }
    }
    freeaddrinfo(res);
    return out;
}

TcpListener::TcpListener() : sock_(static_cast<intptr_t>(kInvalid)) {}
TcpListener::~TcpListener() { close(); }

bool TcpListener::listen(uint16_t port) {
    net_init();
    close();
    socket_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == kInvalid) return false;
#if !defined(_WIN32)
    // POSIX: allow rebinding while old connections sit in TIME_WAIT (fast app restart).
    // Not on Windows, where SO_REUSEADDR would let another process steal the port; Windows
    // already allows rebinding over TIME_WAIT by default.
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#endif
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(s, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0 || ::listen(s, 4) != 0) {
        close_socket(s);
        return false;
    }
    socklen_t len = sizeof addr;
    getsockname(s, reinterpret_cast<sockaddr*>(&addr), &len);
    port_ = ntohs(addr.sin_port);
    sock_ = static_cast<intptr_t>(s);
    return true;
}

std::unique_ptr<ITransport> TcpListener::accept(int timeout_ms) {
    auto s = static_cast<socket_t>(sock_);
    if (s == kInvalid || wait_socket(s, false, timeout_ms) <= 0) return nullptr;
    socket_t c = ::accept(s, nullptr, nullptr);
    if (c == kInvalid) return nullptr;
    set_nonblocking(c, false);  // Windows: accepted sockets inherit the listener's mode; be explicit
    return std::make_unique<TcpTransport>(c);
}

void TcpListener::close() {
    auto s = static_cast<socket_t>(sock_);
    if (s != kInvalid) close_socket(s);
    sock_ = static_cast<intptr_t>(kInvalid);
    port_ = 0;
}

}  // namespace lenny
