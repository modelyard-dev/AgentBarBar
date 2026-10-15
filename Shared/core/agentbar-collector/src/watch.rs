//! Bounded hints. Windows notify uses ReadDirectoryChangesW; reconciliation remains authoritative.
use agentbar_core::Result;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{sync_channel, Receiver},
        Arc,
    },
    time::{Duration, Instant},
};
pub struct WatchHints {
    watcher: RecommendedWatcher,
    receiver: Receiver<std::result::Result<Event, notify::Error>>,
    overflow: Arc<AtomicBool>,
    last_reconcile: Instant,
    reconcile_every: Duration,
}
#[derive(Default)]
pub struct Hints {
    pub changed: Vec<PathBuf>,
    pub full_reconcile: bool,
}
impl WatchHints {
    pub fn new(roots: &[PathBuf], interval: Duration) -> Result<Self> {
        let (sender, receiver) = sync_channel(256);
        let overflow = Arc::new(AtomicBool::new(false));
        let flag = overflow.clone();
        let mut watcher = notify::recommended_watcher(move |event| {
            if sender.try_send(event).is_err() {
                flag.store(true, Ordering::Relaxed);
            }
        })?;
        for root in roots {
            crate::io::safe_path(root)?;
            if root.is_dir() {
                watcher.watch(root, RecursiveMode::Recursive)?;
            }
        }
        Ok(Self {
            watcher,
            receiver,
            overflow,
            last_reconcile: Instant::now(),
            reconcile_every: interval,
        })
    }
    pub fn drain(&mut self) -> Hints {
        let mut hints = Hints {
            full_reconcile: self.overflow.swap(false, Ordering::Relaxed)
                || self.last_reconcile.elapsed() >= self.reconcile_every,
            ..Default::default()
        };
        for event in self.receiver.try_iter() {
            match event {
                Ok(e) => hints.changed.extend(e.paths),
                Err(_) => hints.full_reconcile = true,
            }
        }
        if hints.changed.len() > 1024 {
            hints.changed.clear();
            hints.full_reconcile = true;
        }
        hints.changed.sort();
        hints.changed.dedup();
        if hints.full_reconcile {
            self.last_reconcile = Instant::now();
        }
        hints
    }
    pub fn watched(&self) -> bool {
        let _ = &self.watcher;
        true
    }
}
pub fn affected(path: &Path, changes: &[PathBuf]) -> bool {
    changes.iter().any(|p| {
        path == p
            || path.starts_with(p)
            || p.starts_with(path)
            || p.as_os_str() == std::ffi::OsString::from(format!("{}-wal", path.display()))
            || p.as_os_str() == std::ffi::OsString::from(format!("{}-shm", path.display()))
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn sqlite_wal_changes_affect_the_database_source() {
        let path = std::path::Path::new("anonymous/usage.sqlite");
        assert!(super::affected(
            path,
            &["anonymous/usage.sqlite-wal".into()]
        ));
        assert!(!super::affected(
            path,
            &["anonymous/other.sqlite-wal".into()]
        ));
    }
}
