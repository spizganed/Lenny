//! Transport. Every byte the core sends or receives goes through `Transport`. Keep it that way: a future TLS
//! layer (ADR-0005) is a wrapper around this trait, so no other code may touch sockets.
//!
//! TCP uses std + socket2, so the only per-OS line is the "connect in progress" errno check.

use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Duration;

use socket2::{Domain, Protocol, Socket, Type};

pub trait Transport: Send + Sync {
    /// > 0 bytes read, 0 = timeout, < 0 = closed or failed.
    fn recv(&self, buf: &mut [u8], timeout_ms: i32) -> i32;
    /// Blocks until everything is sent. False = link is dead.
    fn send_all(&self, data: &[u8]) -> bool;
    /// Thread-safe: wakes a blocked recv/send on another thread, which then fails.
    fn shutdown(&self);
}

struct TcpTransport {
    s: TcpStream,
    read_timeout_ms: AtomicI32, // last SO_RCVTIMEO set; recv is only called from one thread
}

impl TcpTransport {
    fn new(s: TcpStream) -> Self {
        let _ = s.set_nodelay(true);
        Self { s, read_timeout_ms: AtomicI32::new(-1) }
    }
}

impl Transport for TcpTransport {
    fn recv(&self, buf: &mut [u8], timeout_ms: i32) -> i32 {
        let t = timeout_ms.max(1); // SO_RCVTIMEO can't express "don't wait"; 1 ms is close enough
        if self.read_timeout_ms.swap(t, Ordering::Relaxed) != t
            && self.s.set_read_timeout(Some(Duration::from_millis(t as u64))).is_err()
        {
            return -1;
        }
        match (&self.s).read(buf) {
            Ok(0) => -1, // orderly close
            Ok(n) => n.min(i32::MAX as usize) as i32,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => 0,
            Err(_) => -1,
        }
    }

    fn send_all(&self, data: &[u8]) -> bool {
        // std sends with MSG_NOSIGNAL on Linux/Android: a dead peer can't SIGPIPE-kill the app.
        (&self.s).write_all(data).is_ok()
    }

    fn shutdown(&self) {
        let _ = self.s.shutdown(Shutdown::Both);
    }
}

fn stream_from(sock: Socket) -> Option<Box<dyn Transport>> {
    #[cfg(target_vendor = "apple")]
    let _ = sock.set_nosigpipe(true);
    sock.set_nonblocking(false).ok()?; // Windows: accepted sockets inherit the listener's mode; be explicit
    Some(Box::new(TcpTransport::new(sock.into())))
}

/// Connects with a timeout, trying every address `host` resolves to. `cancel` aborts early.
/// send_buffer > 0 caps the kernel send buffer, so queued video stays visible to our own congestion control.
pub fn tcp_connect(
    host: &str,
    port: u16,
    timeout_ms: i32,
    cancel: &AtomicBool,
    send_buffer: usize,
) -> Option<Box<dyn Transport>> {
    let addrs = (host, port).to_socket_addrs().ok()?;
    for addr in addrs {
        if cancel.load(Ordering::SeqCst) {
            break;
        }
        let Ok(s) = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP)) else { continue };
        if send_buffer > 0 {
            let _ = s.set_send_buffer_size(send_buffer);
        }
        if connect_cancellable(&s, addr, timeout_ms, cancel) {
            if let Some(t) = stream_from(s) {
                return Some(t);
            }
        }
    }
    None
}

fn in_progress(e: &std::io::Error) -> bool {
    #[cfg(unix)]
    if e.raw_os_error() == Some(libc::EINPROGRESS) {
        return true;
    }
    e.kind() == ErrorKind::WouldBlock // Windows: WSAEWOULDBLOCK
}

/// Non-blocking connect polled in short slices, so a disconnect() doesn't wait out the whole timeout
/// (and a blocking connect to an unreachable IP would hang ~21 s on Windows).
// ponytail: 10 ms sleep-polling instead of poll()/select(), which keeps this file free of OS code;
// costs at most 10 ms per connect.
fn connect_cancellable(s: &Socket, addr: SocketAddr, timeout_ms: i32, cancel: &AtomicBool) -> bool {
    if s.set_nonblocking(true).is_err() {
        return false;
    }
    match s.connect(&addr.into()) {
        Ok(()) => return true,
        Err(e) if in_progress(&e) => {}
        Err(_) => return false,
    }
    let mut waited = 0;
    while waited < timeout_ms && !cancel.load(Ordering::SeqCst) {
        match s.take_error() {
            Ok(None) => {}
            _ => return false,
        }
        if s.peer_addr().is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
        waited += 10;
    }
    false
}

/// IPv4, all interfaces.
// ponytail: IPv4 only; add a dual-stack socket if IPv6-only LANs show up.
pub struct TcpListener {
    sock: Socket,
    port: u16,
}

impl TcpListener {
    pub fn listen(port: u16) -> Option<Self> {
        let s = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).ok()?;
        // POSIX: allow rebinding while old connections sit in TIME_WAIT (fast app restart). Not on Windows, where
        // SO_REUSEADDR would let another process steal the port; Windows already allows rebinding over TIME_WAIT.
        #[cfg(not(windows))]
        s.set_reuse_address(true).ok()?;
        s.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)).into()).ok()?;
        s.listen(4).ok()?;
        s.set_nonblocking(true).ok()?;
        let port = s.local_addr().ok()?.as_socket()?.port();
        Some(Self { sock: s, port })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// None on timeout or error.
    // ponytail: 10 ms sleep-polling, see connect_cancellable.
    pub fn accept(&self, timeout_ms: i32) -> Option<Box<dyn Transport>> {
        let mut waited = 0;
        loop {
            match self.sock.accept() {
                Ok((c, _)) => return stream_from(c),
                Err(e) if e.kind() == ErrorKind::WouldBlock && waited < timeout_ms => {
                    std::thread::sleep(Duration::from_millis(10));
                    waited += 10;
                }
                Err(_) => return None,
            }
        }
    }
}
