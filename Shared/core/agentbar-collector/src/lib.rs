//! Read-only platform source adapters and bounded ingest. No Tauri or Windows Service.
pub mod ingest;
pub mod io;
pub mod locator;
pub mod watch;

pub mod cli;

#[cfg(feature = "profiling")]
pub mod profiling;

mod structured;
