//! Host config. Thin for now, everything has a default so plain `ioscpy` needs
//! no setup.

#![allow(dead_code)]

use crate::protocol::DEFAULT_PORT;

#[derive(Debug, Clone)]
pub struct HostConfig {
    /// Device port we forward to.
    pub port: u16,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self { port: DEFAULT_PORT }
    }
}
