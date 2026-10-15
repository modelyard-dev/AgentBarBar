//! Internal headless host. Does not return conversation bodies or raw records.
use crate::{
    ingest::{self, CollectorState, Metrics, Options},
    locator::{kimi_directories, NativeLocator, Profile, SourceLocator},
    watch,
};
use agentbar_core::{
    aggregation::{range_filter, QueryFilter},
    storage::Store,
    Result,
};
use serde_json::json;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
    time::{Duration, Instant},
};
fn arg(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|v| v == key)
        .and_then(|p| args.get(p + 1))
        .cloned()
}
fn roots(args: &[String]) -> Vec<PathBuf> {
    args.windows(2)
        .filter(|v| v[0] == "--root")
        .map(|v| PathBuf::from(&v[1]))
        .collect()
}
pub fn default_database() -> Result<PathBuf> {
    let base = std::env::var_os(if cfg!(windows) {
        "LOCALAPPDATA"
    } else {
        "XDG_DATA_HOME"
    })
    .map(PathBuf::from)
    .or_else(|| {
        if cfg!(windows) {
            None
        } else {
            std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
        }
    })
    .ok_or("LOCAL_APPLICATION_DATA_UNAVAILABLE")?;
    Ok(base.join("AgentBarBar/database/usage.sqlite"))
}
pub fn open_owned(path: &Path, sources: &[PathBuf]) -> Result<Store> {
    crate::io::safe_path(path)?;
    for root in sources {
        if path.starts_with(root) {
            return Err("DATABASE_CANNOT_RESIDE_IN_AGENT_SOURCE".into());
        }
    }
    if path.exists() {
        let db = rusqlite::Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        let own: bool = db.query_row(
            "SELECT count(*)>0 FROM sqlite_master WHERE name='agentbar_ingest_meta'",
            [],
            |r| r.get(0),
        )?;
        if !own {
            return Err("REFUSE_NON_INGEST_DATABASE".into());
        }
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let store = Store::open(path)?;
    ingest::initialize(&store)?;
    Ok(store)
}
pub fn run(args: &[String]) -> Result<serde_json::Value> {
    let command = args.first().map(String::as_str).ok_or("COMMAND_REQUIRED")?;
    if command == "stream-benchmark" {
        return benchmark(args);
    }
    let mut profile = Profile::current()?;
    if let Some(home) = arg(args, "--home") {
        profile.home = PathBuf::from(home);
        profile.codex_home = None;
        profile.claude_config = None;
    }
    let agents = arg(args, "--agents")
        .unwrap_or_else(|| {
            args.get(1)
                .filter(|v| !v.starts_with('-'))
                .cloned()
                .unwrap_or("codex,claude-code,kimi-cli,deepseek-harness,workbuddy,pi,gemini,qwen,cline,opencode,antigravity,antigravity-ide".into())
        })
        .split(',')
        .map(str::to_owned)
        .collect::<Vec<_>>();
    for agent in &agents {
        agentbar_core::parser::adapter(agent)?;
    }
    let overrides = roots(args);
    if !overrides.is_empty() && agents.len() != 1 {
        return Err("EXPLICIT_ROOT_REQUIRES_SINGLE_AGENT".into());
    }
    let cancel = AtomicBool::new(false);
    let mut locator = NativeLocator::new(profile.clone());
    locator.probe = matches!(command, "sources");
    let mut discoveries = Vec::new();
    for agent in &agents {
        discoveries.push(locator.discover(agent, &overrides, &cancel)?);
    }
    if command == "sources" {
        return Ok(
            json!({"sourceClass":"WindowsNative","discoveries":discoveries,"scope":"bounded_schema_probe_not_system_pass"}),
        );
    }
    let source_roots = discoveries
        .iter()
        .flat_map(|d| d.roots.clone())
        .collect::<Vec<_>>();
    let dry = args.iter().any(|a| a == "--dry-run") || command == "inspect";
    let db_path = arg(args, "--db")
        .map(PathBuf::from)
        .unwrap_or(default_database()?);
    if command == "status" && !db_path.exists() {
        return Ok(json!({"state":"unavailable","databaseExists":false}));
    }
    if let Some(p) = arg(args, "--fault") {
        if !args.iter().any(|a| a == "--qa-fault")
            || !args.iter().any(|a| a == "--db")
            || overrides.is_empty()
        {
            return Err("FAULT_INJECTION_REQUIRES_EXPLICIT_QA_SOURCE_AND_DATABASE".into());
        }
        if ![
            "after-read",
            "after-parse",
            "before-checkpoint",
            "during-checkpoint",
            "after-commit",
        ]
        .contains(&p.as_str())
        {
            return Err("INVALID_FAULT_POINT".into());
        }
    }
    let mut store = if dry {
        let s = Store::memory()?;
        ingest::initialize(&s)?;
        s
    } else if command == "verify" || command == "status" {
        open_for_inspection(&db_path)?
    } else {
        open_owned(&db_path, &source_roots)?
    };
    if command == "verify" {
        return semantic_digest(&store, &agents);
    }
    if command == "status" {
        return ingest::status(&store);
    }
    if !["collect", "inspect", "reconcile", "watch"].contains(&command) {
        return Err("UNKNOWN_INGEST_COMMAND".into());
    }
    let options = Options {
        fault: arg(args, "--fault"),
        force_reconcile: command == "reconcile",
        ..Default::default()
    };
    let dirs = kimi_directories(&profile);
    let sources = discoveries
        .iter()
        .flat_map(|d| d.sources.clone())
        .collect::<Vec<_>>();
    let results = ingest::collect(&mut store, &sources, &options, &cancel, &dirs);
    for result in &results {
        eprintln!(
            "{}",
            json!({"timestamp":agentbar_core::domain::iso(chrono::Utc::now()),"level":if result.state==CollectorState::Error {"error"}else if result.state==CollectorState::Degraded||result.state==CollectorState::RecoveryRequired {"warning"}else{"info"},"component":"collector","agent":result.agent,"sourceId":result.source_id,"event":"source_reconciled","state":result.state,"durationMs":result.metrics.elapsed_ms,"records":result.metrics.records_normalized})
        );
    }
    let mut metrics = Metrics::default();
    for result in &results {
        metrics.add(&result.metrics);
    }
    let now = chrono::Utc::now();
    let timezone = arg(args, "--tz").unwrap_or("UTC".into());
    let mut summaries = serde_json::Map::new();
    for agent in &agents {
        let f = QueryFilter {
            agent: Some(agent.clone()),
            ..Default::default()
        };
        let mut ranges = serde_json::Map::new();
        for r in ["today", "7", "30", "all"] {
            let mut filter = range_filter(r, now, &timezone)?;
            filter.agent = f.agent.clone();
            ranges.insert(
                r.into(),
                serde_json::to_value(store.summary_sql(&filter, now)?)?,
            );
        }
        summaries.insert(agent.clone(), json!({"ranges":ranges}));
    }
    let mut output = json!({"dryRun":dry,"now":agentbar_core::domain::iso(now),"timeZone":timezone,"discoveredSources":sources.len(),"discoveryLimited":discoveries.iter().any(|d|d.limited),"probeBytes":discoveries.iter().map(|d|d.probe_bytes).sum::<u64>(),"results":results,"metrics":metrics,"agents":summaries,"checkpoint":ingest::status(&store)?});
    if command == "watch" {
        if dry {
            return Err("WATCH_DRY_RUN_UNSUPPORTED_USE_INSPECT".into());
        }
        let duration = arg(args, "--seconds")
            .unwrap_or("120".into())
            .parse::<u64>()?
            .min(3600);
        let mut hints = watch::WatchHints::new(&source_roots, Duration::from_secs(120))?;
        let start = Instant::now();
        let mut cycles = Vec::new();
        let mut pending = std::collections::BTreeSet::new();
        let mut full = false;
        let mut deadline: Option<Instant> = None;
        while start.elapsed() < Duration::from_secs(duration) {
            std::thread::sleep(Duration::from_millis(200));
            let events = hints.drain();
            full |= events.full_reconcile;
            for path in events.changed {
                if pending.len() < 1024 {
                    pending.insert(path);
                } else {
                    full = true;
                }
            }
            if !full && pending.is_empty() {
                continue;
            }
            let due = deadline.get_or_insert_with(|| Instant::now() + Duration::from_secs(2));
            if Instant::now() < *due {
                continue;
            }
            let changed = pending.iter().cloned().collect::<Vec<_>>();
            let mut next = Vec::new();
            for agent in &agents {
                next.extend(locator.discover(agent, &overrides, &cancel)?.sources);
            }
            let selected = if full {
                next
            } else {
                next.into_iter()
                    .filter(|s| watch::affected(&s.path, &changed))
                    .collect()
            };
            let reports =
                ingest::collect(&mut store, &selected, &Options::default(), &cancel, &dirs);
            cycles.push(json!({"fullReconcile":full,"reports":reports}));
            if cycles.len() > 128 {
                cycles.remove(0);
            }
            pending.clear();
            full = false;
            deadline = None;
        }
        output["watch"] =
            json!({"state":"watching_then_stopped","fallbackSeconds":120,"cycles":cycles});
    }
    Ok(output)
}
fn benchmark(args: &[String]) -> Result<serde_json::Value> {
    let sql_profile = args.iter().any(|a| a == "--sql-profile");
    #[cfg(not(feature = "profiling"))]
    if sql_profile {
        return Err("SQL_PROFILE_REQUIRES_PROFILING_FEATURE".into());
    }
    let rows = args
        .get(1)
        .ok_or("BENCHMARK_ROWS_REQUIRED")?
        .parse::<usize>()?;
    if !(1000..=500000).contains(&rows) {
        return Err("BENCHMARK_LIMIT_1K_TO_500K".into());
    }
    let root = PathBuf::from(arg(args, "--qa-dir").ok_or("BENCHMARK_REQUIRES_NEW_OWNED_QA_DIR")?);
    if root.exists() {
        return Err("BENCHMARK_WILL_NOT_OVERWRITE_QA_DIRECTORY".into());
    }
    fs::create_dir_all(root.join("sources"))?;
    let path = root.join("sources/rollout-benchmark.jsonl");
    use std::io::Write;
    let mut f = fs::File::create(&path)?;
    writeln!(
        f,
        "{}",
        json!({"type":"session_meta","timestamp":"2026-10-05T04:00:00Z","payload":{"id":"anonymous-benchmark"}})
    )?;
    for i in 0..rows {
        writeln!(
            f,
            "{}",
            json!({"timestamp":"2026-10-05T04:00:01Z","type":"token_usage_record","payload":{"response_id":format!("anonymous-{i:06}"),"usage":{"input_tokens":100,"output_tokens":23,"cached_input_tokens":40,"cache_write_input_tokens":2,"reasoning_output_tokens":7,"total_tokens":123}}})
        )?;
    }
    drop(f);
    let profile = Profile {
        home: root.clone(),
        appdata: None,
        localappdata: None,
        codex_home: None,
        claude_config: None,
    };
    let mut locator = NativeLocator::new(profile);
    locator.probe = false;
    let cancel = AtomicBool::new(false);
    let sources = locator
        .discover("codex", &[root.join("sources")], &cancel)?
        .sources;
    let mut store = open_owned(&root.join("database/usage.sqlite"), &[root.join("sources")])?;
    #[cfg(feature = "profiling")]
    if sql_profile {
        crate::profiling::start(&mut store.db);
        agentbar_core::profiling::reset(args.iter().any(|a| a == "--reuse-statements"));
    }
    let profile_clock = std::time::Instant::now();
    let results = ingest::collect(
        &mut store,
        &sources,
        &Options::default(),
        &cancel,
        &BTreeMap::new(),
    );
    let import_ms = profile_clock.elapsed().as_millis();
    #[cfg(feature = "profiling")]
    let sql_timings = if sql_profile {
        serde_json::json!({"sqliteExecution":crate::profiling::finish(&mut store.db),"rustStages":agentbar_core::profiling::snapshot()})
    } else {
        serde_json::Value::Null
    };
    #[cfg(not(feature = "profiling"))]
    let sql_timings = serde_json::Value::Null;
    println!(
        "{}",
        json!({"phase":"import_complete","rows":rows,"results":results,"importMs":import_ms,"sqlProfile":sql_timings})
    );
    std::io::stdout().flush()?;
    let pause = arg(args, "--idle-ms")
        .unwrap_or("1000".into())
        .parse::<u64>()?
        .min(10000);
    std::thread::sleep(Duration::from_millis(pause));
    let mut polls = Vec::new();
    for _ in 0..5 {
        polls.push(ingest::collect(
            &mut store,
            &sources,
            &Options::default(),
            &cancel,
            &BTreeMap::new(),
        ));
        std::thread::sleep(Duration::from_millis(200));
    }
    println!(
        "{}",
        json!({"phase":"steady_idle","rows":rows,"polls":polls})
    );
    std::io::stdout().flush()?;
    std::thread::sleep(Duration::from_millis(pause));
    let summary = store.summary_sql(&QueryFilter::default(), chrono::Utc::now())?;
    if summary.events != rows
        || summary.metrics["total"].value != Some((rows as i64) * 123)
        || results
            .iter()
            .any(|r| r.state == CollectorState::Error || r.state == CollectorState::Degraded)
    {
        return Err("STREAMING_BENCHMARK_RECONCILIATION_FAILED".into());
    }
    Ok(
        json!({"phase":"complete","rows":rows,"summary":summary,"businessDigest":semantic_digest(&store,&["codex".into()])?,"readOnlyFixture":true}),
    )
}
use std::collections::BTreeMap;

// Hash ONLY business metadata. No body or raw request ID leaves the private store.
fn semantic_digest(store: &Store, agents: &[String]) -> Result<serde_json::Value> {
    use sha2::{Digest, Sha256};
    let mut results = serde_json::Map::new();
    for agent in agents {
        let mut digest = Sha256::new();
        let mut count = 0usize;
        let mut statement = store.db.prepare(
            "SELECT event_json FROM usage_events WHERE agent_id=? ORDER BY source_event_id",
        )?;
        let mut rows = statement.query([agent])?;
        while let Some(row) = rows.next()? {
            let e: agentbar_core::domain::NormalizedUsageRecord =
                serde_json::from_str(&row.get::<_, String>(0)?)?;
            let v = serde_json::json!({"agent":e.agent_id,"identityHash":e.id,"timestamp":e.timestamp,"model":e.raw_model_name,"provider":e.provider,"sessionHash":e.session_id.as_ref().map(|s|agentbar_core::domain::hash(s)),"metrics":e.metrics});
            digest.update(serde_json::to_vec(&v)?);
            digest.update(b"\n");
            count += 1;
        }
        results.insert(agent.clone(),json!({"records":count,"businessSHA256":format!("{:x}",digest.finalize()),"summary":store.summary_sql(&QueryFilter{agent:Some(agent.clone()),..Default::default()},chrono::Utc::now())?}));
    }
    Ok(json!({"verification":"PRIVATE_METADATA_ONLY","agents":results}))
}

/// Diagnostics must not acquire a second writer or run migrations on a live host DB.
fn open_for_inspection(path: &Path) -> Result<Store> {
    crate::io::safe_path(path)?;
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    db.busy_timeout(Duration::from_secs(5))?;
    Ok(Store { db })
}
#[cfg(test)]
mod inspection_tests {
    use super::*;
    #[test]
    fn inspection_is_readonly_and_never_creates_database() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().canonicalize().unwrap().join("usage.sqlite");
        assert!(open_for_inspection(&path).is_err());
        assert!(!path.exists());
        drop(Store::open(&path).unwrap());
        let inspection = open_for_inspection(&path).unwrap();
        assert!(inspection
            .db
            .is_readonly(rusqlite::DatabaseName::Main)
            .unwrap());
        assert!(inspection
            .db
            .execute_batch("CREATE TABLE forbidden(v INTEGER)")
            .is_err());
        let version: i64 = inspection
            .db
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, 7);
    }
}
