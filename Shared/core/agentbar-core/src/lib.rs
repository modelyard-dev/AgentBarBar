//! Versioned metadata semantics; no OS discovery, watcher, Tauri, or network dependency.
pub mod adapter;
pub mod aggregation;
pub mod domain;
pub mod ffi;
pub mod parser;
pub mod storage;
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[cfg(feature = "profiling")]
pub mod profiling;

mod additional;
pub mod release_106;
