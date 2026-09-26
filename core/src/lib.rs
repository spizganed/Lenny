//! Lenny core: wire protocol, session state machine, TCP transport, pairing, clock sync.
//! Platform code talks to it through the stable C ABI (`c_api`, include/lenny/lenny.h); Rust apps can also use
//! `Session` directly.
//!
//! No OS-specific code lives here (architecture.md §4). Sockets stay behind `transport::Transport`.

pub mod abi;
pub mod c_api;
pub mod pairing;
pub mod session;
pub mod timing;
pub mod transport;
pub mod wire;

pub use abi::*;
pub use c_api::*;
