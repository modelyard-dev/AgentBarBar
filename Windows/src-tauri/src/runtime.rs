//! One writer thread. UI reads separate WAL snapshots and never waits on import mutex.
use agentbar_collector::{
    ingest::{self, CollectorState, Options},
    locator::{kimi_directories, NativeLocator, Profile, SourceLocator},
    watch::WatchHints,
};
use agentbar_core::parser::UsageAdapter;
use agentbar_core::{storage::Store, Result};
use agentbar_windows_host::data;
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
        Arc, Mutex,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
use tauri::{AppHandle, Emitter};
pub enum Work {
    Sync,
    Survey(String, SyncSender<std::result::Result<Value, String>>),
    Settings(Value, SyncSender<std::result::Result<Value, String>>),
    Stop,
}
pub struct Runtime {
    _profile_lease: std::fs::File,
    pub db: PathBuf,
    pub health: Mutex<Value>,
    pub collectors: Mutex<Value>,
    pub cancel: Arc<AtomicBool>,
    pub sender: SyncSender<Work>,
    join: Mutex<Option<JoinHandle<()>>>,
    pub timezone: String,
}
impl Runtime {
    pub fn start(app: AppHandle) -> Result<Arc<Self>> {
        let db = agentbar_collector::cli::default_database()?;
        let lease_path = db
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("state/writer.lock");
        agentbar_collector::io::safe_path(&lease_path)?;
        std::fs::create_dir_all(lease_path.parent().unwrap())?;
        let mut lease_options = std::fs::OpenOptions::new();
        lease_options
            .read(true)
            .write(true)
            .create(true)
            .truncate(false);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            lease_options.share_mode(0);
        }
        let profile_lease = lease_options
            .open(&lease_path)
            .map_err(|_| "PROFILE_ALREADY_RUNNING_OR_UNAVAILABLE")?;
        let store = agentbar_collector::cli::open_owned(&db, &[])?;
        let timezone = system_timezone();
        let (sender, receiver) = mpsc::sync_channel(16);
        let r = Arc::new(Self {
            _profile_lease: profile_lease,
            db: db.clone(),
            health: Mutex::new(
                json!({"lifecycle":"initializing","database":"healthy","databasePath":db,"collector":"importing","timezoneSupported":agentbar_core::aggregation::zone(&timezone).is_ok(),"agents":{},"processed":0,"inserted":0}),
            ),
            collectors: Mutex::new(json!([])),
            cancel: Arc::new(AtomicBool::new(false)),
            sender,
            join: Mutex::new(None),
            timezone,
        });
        let worker = r.clone();
        let handle = std::thread::spawn(move || {
            let mut store = store;
            let profile = match Profile::current() {
                Ok(p) => p,
                Err(_) => {
                    worker.fail(&app);
                    return;
                }
            };
            let mut locator = NativeLocator::new(profile.clone());
            locator.probe = false;
            let dirs = kimi_directories(&profile);
            let mut hints = None;
            let mut pending = true;
            let mut last = Instant::now();
            let mut dirty = vec![];
            let mut initial_import = true;
            let mut manual_sync = false;
            let mut previous_day_start = None;
            loop {
                if worker.cancel.load(Ordering::Acquire) {
                    break;
                }
                if pending {
                    worker.health.lock().unwrap()["collector"] = json!("importing");
                    worker.emit(&app, "collector_status_changed");
                    let prefs = data::settings(&store).unwrap_or_else(|_| data::defaults());
                    let mut reports = vec![];
                    let mut roots = vec![];
                    let mut processed = 0u64;
                    let mut inserted = 0u64;
                    let mut updated = 0u64;
                    for (agent, name) in data::AGENTS {
                        if worker.cancel.load(Ordering::Acquire) {
                            break;
                        }
                        let disabled = prefs["disabledCollectors"]
                            .as_array()
                            .is_some_and(|xs| xs.iter().any(|x| x == agent));
                        let overrides = prefs["sourceOverrides"][agent]
                            .as_array()
                            .map(|a| {
                                a.iter()
                                    .filter_map(|x| x.as_str().map(PathBuf::from))
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default();
                        let discovery = locator.discover(agent, &overrides, &worker.cancel);
                        let mut metrics = ingest::Metrics::default();
                        let mut errors = vec![];
                        let mut source_roots = vec![];
                        let mut count = 0;
                        let installed = profile.installation(agent);
                        let mut source_available = false;
                        if !disabled {
                            match discovery {
                                Ok(d) => {
                                    source_roots = d.roots.clone();
                                    if !d.errors.is_empty() {
                                        errors.push("SOURCE_DISCOVERY_NEEDS_ATTENTION");
                                    }
                                    roots.extend(d.roots);
                                    count = d.sources.len();
                                    if agent == "deepseek-harness" && count > 1 {
                                        errors.push("CHOOSE_ONE_DSH_LEDGER");
                                    }
                                    source_available = count > 0;
                                    if d.limited {
                                        errors.push("DISCOVERY_LIMIT_REACHED")
                                    }
                                    for s in d.sources {
                                        if agent == "deepseek-harness" && count > 1 {
                                            break;
                                        }
                                        if !dirty.is_empty()
                                            && !agentbar_collector::watch::affected(&s.path, &dirty)
                                        {
                                            continue;
                                        }
                                        let progress_app = app.clone();
                                        let base_processed = processed;
                                        let base_inserted = inserted;
                                        let mut emitted = Instant::now() - Duration::from_secs(1);
                                        let gate = Mutex::new(&mut emitted);
                                        let progress = |m: &ingest::Metrics| {
                                            let mut time = gate.lock().unwrap();
                                            if time.elapsed() >= Duration::from_millis(500) {
                                                **time = Instant::now();
                                                {
                                                    let mut h = worker.health.lock().unwrap();
                                                    h["processed"] = json!(
                                                        base_processed + m.records_normalized
                                                    );
                                                    h["inserted"] =
                                                        json!(base_inserted + m.records_inserted);
                                                }
                                                worker.emit(
                                                    &progress_app,
                                                    "collector_status_changed",
                                                );
                                            }
                                        };
                                        match ingest::collect_source_with_progress(
                                            &mut store,
                                            &s,
                                            &Options::default(),
                                            &worker.cancel,
                                            &dirs,
                                            &progress,
                                        ) {
                                            Ok(result) => {
                                                metrics.add(&result.metrics);
                                                if result.diagnostics.iter().any(|d| d=="CLINE_DELETED_SUBAGENT_AGGREGATES_EXCLUDED") {errors.push("Cline deleted/subagent aggregate records excluded; request coverage is partial");}
                                                if matches!(
                                                    result.state,
                                                    CollectorState::Error
                                                        | CollectorState::Degraded
                                                        | CollectorState::RecoveryRequired
                                                ) {
                                                    errors.push("SOURCE_NEEDS_ATTENTION")
                                                }
                                            }
                                            Err(error) => {
                                                let code = error.to_string();
                                                errors.push(if code.starts_with("DSH_") {
                                                    "DSH_LEDGER_NEEDS_ATTENTION"
                                                } else {
                                                    "SOURCE_OR_TRANSACTION_FAILURE"
                                                });
                                            }
                                        };
                                        if worker.cancel.load(Ordering::Acquire) {
                                            break;
                                        }
                                    }
                                }
                                Err(_) => errors.push("SOURCE_DISCOVERY_FAILED"),
                            }
                        }
                        processed += metrics.records_normalized;
                        inserted += metrics.records_inserted;
                        updated += metrics.records_updated;
                        let status = if disabled {
                            "disabled"
                        } else if !errors.is_empty() {
                            if errors.iter().all(|e| *e == "Cline deleted/subagent aggregate records excluded; request coverage is partial") {"partial"} else {"error"}
                        } else if agent == "kimi-cli" {
                            "partial"
                        } else if count == 0 {
                            "unavailable"
                        } else {
                            "healthy"
                        };
                        worker.health.lock().unwrap()["agents"][agent] =
                            json!(if status == "healthy" {
                                "watching"
                            } else {
                                status
                            });
                        let coverage=data::coverage(&store,agent,status,&errors).unwrap_or(Value::Null);
                        reports.push(json!({"descriptor":{"id":agent,"agentID":agent,"name":name,"version":if agent=="gemini"{"1.1.1"}else{"1.0.0"},"parserVersion":agentbar_core::parser::adapter(agent).map(|p|p.version()).unwrap_or("unavailable"),"sourceRoots":source_roots,"sourceDescription":data::source_description(agent),"supportedAgentVersions":["Metadata schema verified against shared anonymous fixtures"],"capabilities":data::capabilities(agent)},"detection":{"installed":!installed.is_empty(),"evidence":installed,"sourceAvailable":source_available},"health":{"status":status,"lastCollection":agentbar_core::domain::iso(chrono::Utc::now()),"compatibility":if agent=="kimi-cli"{"SYSTEM_PARTIAL"}else if ["codex","claude-code","deepseek-harness"].contains(&agent){"SOURCE_VERIFIED"}else{"SCHEMA_FIXTURE_VERIFIED"},"errors":errors,"files":count,"bytesRead":metrics.bytes_read,"imported":metrics.records_inserted,"updated":metrics.records_updated,"duplicates":metrics.duplicates},"enabled":!disabled,"coverage":coverage}));
                    }
                    let inspection_id = "claude-desktop";
                    let inspection_disabled = prefs["disabledCollectors"]
                        .as_array()
                        .is_some_and(|xs| xs.iter().any(|x| x == inspection_id));
                    let inspection_roots = prefs["sourceOverrides"][inspection_id]
                        .as_array()
                        .map(|xs| xs.iter().filter_map(|x| x.as_str().map(PathBuf::from)).collect::<Vec<_>>())
                        .unwrap_or_else(|| profile.roots(inspection_id).unwrap_or_default());
                    let inspection_root_names = inspection_roots.iter().map(|p| p.to_string_lossy().to_string()).collect::<Vec<_>>();
                    let inspection_available = inspection_roots.iter().any(|p| p.is_dir());
                    let inspection_installation = profile.installation(inspection_id);
                    let inspection_status = if inspection_disabled { "disabled" } else { "source_unverified" };
                    let inspection_errors: Vec<&str> = Vec::new();
                    worker.health.lock().unwrap()["agents"][inspection_id] = json!(inspection_status);
                    let inspection_coverage = data::coverage(&store, inspection_id, inspection_status, &inspection_errors).unwrap_or(Value::Null);
                    reports.push(json!({
                        "descriptor":{"id":inspection_id,"agentID":inspection_id,"name":"Claude Desktop","mode":"inspection","version":"1.0.0","parserVersion":"claude-desktop-inspection-v1.0.0","sourceRoots":inspection_root_names,"sourceDescription":data::source_description(inspection_id),"supportedAgentVersions":["Bounded metadata-only source survey"],"capabilities":data::capabilities(inspection_id)},
                        "detection":{"installed":!inspection_installation.is_empty(),"evidence":inspection_installation,"sourceAvailable":inspection_available},
                        "health":{"status":inspection_status,"lastCollection":agentbar_core::domain::iso(chrono::Utc::now()),"compatibility":"NO_USAGE_PARSER_VERIFIED","errors":inspection_errors,"files":0,"bytesRead":0,"imported":0,"updated":0,"duplicates":0},
                        "enabled":!inspection_disabled,"coverage":inspection_coverage
                    }));
                    *worker.collectors.lock().unwrap() = json!(reports);
                    {
                        let mut h = worker.health.lock().unwrap();
                        h["lifecycle"] = json!("running");
                        h["collector"] = json!("running");
                        h["processed"] = json!(processed);
                        h["inserted"] = json!(inserted);
                    }
                    if hints.is_none() {
                        let seconds = prefs["reconciliationSeconds"].as_u64().unwrap_or(120);
                        hints = WatchHints::new(&roots, Duration::from_secs(seconds)).ok();
                    }
                    let day_start = agentbar_core::aggregation::range_filter(
                        "today",
                        chrono::Utc::now(),
                        &worker.timezone,
                    )
                    .ok()
                    .and_then(|f| f.start);
                    let calendar_changed = day_start != previous_day_start;
                    previous_day_start = day_start;
                    if inserted > 0 || updated > 0 || calendar_changed {
                        worker.emit(&app, "data_updated");
                    }
                    if initial_import || manual_sync || inserted > 0 || updated > 0 {
                        worker.emit(&app, "import_completed");
                    }
                    manual_sync = false;
                    worker.emit(&app, "collector_status_changed");
                    initial_import = false;
                    // Low-frequency date reconciliation also refreshes a midnight tooltip without new logs.
                    worker.refresh_tooltip(&app);
                    pending = false;
                    dirty.clear();
                    last = Instant::now();
                }
                match receiver.recv_timeout(Duration::from_millis(500)) {
                    Ok(Work::Stop) => break,
                    Ok(Work::Sync) => {
                        manual_sync = true;
                        pending = true;
                        dirty.clear()
                    }
                    Ok(Work::Survey(agent, response)) => {
                        let result = agentbar_windows_host::survey::run(
                            &mut store,
                            &agent,
                            &profile,
                            &worker.cancel,
                        )
                        .map_err(|_| "Source survey could not be completed".to_owned());
                        let okay = result.is_ok();
                        let _ = response.send(result);
                        if okay {
                            pending = true;
                            dirty.clear();
                            worker.emit(&app, "data_updated");
                        }
                    }
                    Ok(Work::Settings(value, response)) => {
                        let result = data::save_settings(&store, value)
                            .map_err(|_| "INVALID_OR_UNSUPPORTED_SETTINGS".into());
                        let okay = result.is_ok();
                        let _ = response.send(result);
                        if okay {
                            hints = None;
                            pending = true;
                            dirty.clear();
                            worker.emit(&app, "settings_changed")
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    _ => (),
                }
                if let Some(h) = &mut hints {
                    let changes = h.drain();
                    if changes.full_reconcile {
                        dirty.clear();
                        pending = true
                    } else if !changes.changed.is_empty() {
                        dirty.extend(changes.changed);
                        if dirty.len() > 1024 {
                            dirty.clear();
                            pending = true;
                        } else if last.elapsed() > Duration::from_secs(2) {
                            pending = true
                        }
                    }
                } else if last.elapsed() > Duration::from_secs(120) {
                    pending = true;
                    dirty.clear()
                }
                if !dirty.is_empty() && last.elapsed() > Duration::from_secs(2) {
                    pending = true;
                }
            }
            // No work in flight after collect returns. Its final complete batch/cursor is committed.
            let _ = store.db.execute_batch("PRAGMA wal_checkpoint(PASSIVE)");
            drop(store);
            worker.health.lock().unwrap()["lifecycle"] = json!("stopped");
            worker.emit(&app, "collector_status_changed");
        });
        *r.join.lock().unwrap() = Some(handle);
        Ok(r)
    }
    pub fn read(&self, path: &str) -> Result<Value> {
        if path == "host-health" {
            return Ok(self.health.lock().unwrap().clone());
        }
        if path == "collectors" {
            return Ok(self.collectors.lock().unwrap().clone());
        }
        if path == "status" {
            return Ok(
                json!({"schemaVersion":7,"databasePath":self.db,"collecting":self.health.lock().unwrap()["collector"]=="importing","timeZone":self.timezone,"supportsNativeSettings":false}),
            );
        }
        let db = rusqlite::Connection::open_with_flags(
            &self.db,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        db.busy_timeout(Duration::from_millis(1000))?;
        let s = Store { db };
        data::query(
            &s,
            path,
            chrono::Utc::now(),
            &self.timezone,
            &self.health.lock().unwrap().clone(),
            &self.collectors.lock().unwrap().clone(),
        )
    }
    pub fn stop(&self) {
        self.health.lock().unwrap()["lifecycle"] = json!("stopping");
        self.cancel.store(true, Ordering::Release);
        let _ = self.sender.try_send(Work::Stop);
        if let Some(join) = self.join.lock().unwrap().take() {
            let _ = join.join();
        }
    }
    fn emit(&self, app: &AppHandle, event: &str) {
        let h = self.health.lock().unwrap().clone();
        let _ = app.emit(event, &h);
    }
    // Called once per reconciliation, never from batch-progress events.
    fn refresh_tooltip(&self, app: &AppHandle) {
        // Reconcile taskbar-only theme changes too; no usage rescan is needed.
        crate::tray_appearance::refresh(app);
        if let Some(tray) = app.tray_by_id("agentbarbar") {
            let now = chrono::Utc::now();
            if let Ok(filter) =
                agentbar_core::aggregation::range_filter("today", now, &self.timezone)
            {
                let path = format!(
                    "summary?start={}&end={}",
                    agentbar_core::domain::iso(
                        chrono::DateTime::from_timestamp_millis(
                            (filter.start.unwrap() * 1000.) as i64
                        )
                        .unwrap()
                    ),
                    agentbar_core::domain::iso(
                        chrono::DateTime::from_timestamp_millis(
                            (filter.end.unwrap() * 1000.) as i64
                        )
                        .unwrap()
                    )
                );
                let Ok(snapshot) = self.read(&path) else {
                    return;
                };
                let n = snapshot["metrics"]["total"]["value"].as_i64();
                let _ = tray.set_tooltip(Some(format!(
                    "AgentBarBar\nToday: {} tokens",
                    n.map(|x| x.to_string()).unwrap_or("—".into())
                )));
            }
        }
    }
    fn fail(&self, app: &AppHandle) {
        let mut h = self.health.lock().unwrap();
        h["lifecycle"] = json!("degraded");
        h["collector"] = json!("error");
        drop(h);
        self.emit(app, "collector_status_changed")
    }
}
fn system_timezone() -> String {
    #[cfg(windows)]
    {
        #[repr(C)]
        struct St {
            y: u16,
            m: u16,
            dow: u16,
            d: u16,
            h: u16,
            min: u16,
            s: u16,
            ms: u16,
        }
        #[repr(C)]
        struct Tz {
            bias: i32,
            standard: [u16; 32],
            date: St,
            sbias: i32,
            daylight: [u16; 32],
            ddate: St,
            dbias: i32,
            key: [u16; 128],
            disabled: i32,
        }
        #[link(name = "kernel32")]
        extern "system" {
            fn GetDynamicTimeZoneInformation(t: *mut Tz) -> u32;
        }
        let mut t: Tz = unsafe { std::mem::zeroed() };
        let result = unsafe { GetDynamicTimeZoneInformation(&mut t) };
        if result != u32::MAX {
            let n = t.key.iter().position(|x| *x == 0).unwrap_or(t.key.len());
            let key = String::from_utf16_lossy(&t.key[..n]);
            if let Ok(z) = agentbar_core::aggregation::zone(&key) {
                return z.name().into();
            }
        }
        // Never silently count an unmapped Windows timezone as UTC.
        "UNVERIFIED_WINDOWS_TIME_ZONE".into()
    }
    #[cfg(not(windows))]
    {
        "UTC".into()
    }
}
