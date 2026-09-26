// Transport interface. Every byte the core sends or receives goes through ITransport. Keep it that way:
// a future TLS layer (ADR-0005) is a wrapper around this interface, so no other code may touch sockets.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace lenny {

class ITransport {
public:
    virtual ~ITransport() = default;
    // > 0 bytes read, 0 = timeout, < 0 = closed or failed.
    virtual int recv(uint8_t* buf, size_t size, int timeout_ms) = 0;
    // Blocks until everything is sent. False = link is dead.
    virtual bool send_all(const uint8_t* data, size_t size) = 0;
    // Thread-safe: wakes a blocked recv/send on another thread, which then fails.
    virtual void shutdown() = 0;
};

// Connects with a timeout, trying every address `host` resolves to. `cancel` aborts early.
// send_buffer > 0 caps the kernel send buffer, so queued video stays visible to our own congestion control.
std::unique_ptr<ITransport> tcp_connect(const std::string& host, uint16_t port, int timeout_ms,
                                        const std::atomic<bool>& cancel, int send_buffer = 0);

class TcpListener {
public:
    TcpListener();
    ~TcpListener();
    TcpListener(const TcpListener&) = delete;
    TcpListener& operator=(const TcpListener&) = delete;

    // ponytail: IPv4 only (all interfaces); add a dual-stack socket if IPv6-only LANs show up.
    bool listen(uint16_t port);
    uint16_t port() const { return port_; }
    // nullptr on timeout or error.
    std::unique_ptr<ITransport> accept(int timeout_ms);
    void close();

private:
    intptr_t sock_;
    uint16_t port_ = 0;
};

}  // namespace lenny
