use crate::{CoreError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Disconnected,
    Handshaking,
    Pairing,
    Connected,
    ClockSyncing,
}

pub struct SessionMachine {
    pub state: SessionState,
    pub remote_clock_offset: i64,
}

impl SessionMachine {
    pub fn new() -> Self {
        Self {
            state: SessionState::Disconnected,
            remote_clock_offset: 0,
        }
    }

    /// Advance the state machine based on protocol events
    pub fn transition(&mut self, next_state: SessionState) -> Result<()> {
        match (self.state, next_state) {
            (SessionState::Disconnected, SessionState::Handshaking) => {
                self.state = next_state;
                Ok(())
            }
            (SessionState::Handshaking, SessionState::Pairing) 
            | (SessionState::Handshaking, SessionState::Connected) => {
                self.state = next_state;
                Ok(())
            }
            (SessionState::Pairing, SessionState::Connected) => {
                self.state = next_state;
                Ok(())
            }
            (SessionState::Connected, SessionState::ClockSyncing) => {
                self.state = next_state;
                Ok(())
            }
            (SessionState::ClockSyncing, SessionState::Connected) => {
                self.state = next_state;
                Ok(())
            }
            _ => Err(CoreError::InvalidStateTransition),
        }
    }

    /// Update clock synchronization offset calculation
    pub fn update_clock_sync(&mut self, local_time_ms: i64, remote_time_ms: i64) {
        self.remote_clock_offset = remote_time_ms - local_time_ms;
    }
}