pub mod wire;
pub mod session;
pub mod c_api;

pub use wire::{TlvHeader, TlvPacket};
pub use session::{SessionState, SessionMachine};

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("Buffer too short or malformed wire data")]
    InvalidBuffer,
    #[error("Unknown or unsupported TLV type: {0}")]
    UnknownTlvType(u16),
    #[error("Invalid session state transition")]
    InvalidStateTransition,
    #[error("Pairing or crypto verification failed")]
    PairingFailed,
}

pub type Result<T> = std::result::Result<T, CoreError>;