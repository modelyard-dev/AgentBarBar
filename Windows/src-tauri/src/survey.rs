//! User-initiated bounded metadata survey. Never retains values or raw source lines.
use crate::data;
use agentbar_collector::{
    ingest::{self, CollectorState, Options},
    io,
    locator::{safe_root, NativeLocator, Profile, SourceLocator},
};
use agentbar_core::{
    domain::iso,
    parser::{adapter, UsageAdapter},
    storage::Store,
    Result,
};
use rusqlite::{OpenFlags, OptionalExtension};
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    io::Read,
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
const FIELDS: &[&str] = &[
    "input_tokens",
    "output_tokens",
    "prompt_tokens",
    "completion_tokens",
    "total_tokens",
    "cached_input_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "reasoning_tokens",
    "inputTokens",
    "outputTokens",
    "totalTokens",
    "cacheReadTokens",
    "input",
    "output",
    "cacheRead",
    "cacheWrite",
    "thoughts",
    "cached",
    "usageMetadata",
    "tokenUsage",
    "promptTokenCount",
    "candidatesTokenCount",
    "totalTokenCount",
];
fn excluded(path: &std::path::Path) -> bool {
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    [
        "auth",
        "credential",
        "secret",
        "cookie",
        "preferences",
        "config",
        "settings",
        "local state",
        "local storage",
        "session storage",
        "login data",
        "trust tokens",
        "node_modules",
        "cache",
        ".git",
        "login",
        "keychain",
    ]
    .iter()
    .any(|s| name.contains(s))
        || name.ends_with("-wal")
        || name.ends_with("-shm")
}
pub fn load(store: &Store, agent: &str) -> Result<Value> {
    if !data::supported_agent(agent) {
        return Err("UNKNOWN_AGENT".into());
    }
    let raw: Option<String> = store
        .db
        .query_row(
            "SELECT value_json FROM settings WHERE key=?",
            [format!("token-survey:{agent}")],
            |r| r.get(0),
        )
        .optional()?;
    Ok(raw
        .map(|s| serde_json::from_str(&s))
        .transpose()?
        .unwrap_or(Value::Null))
}
pub fn run(
    store: &mut Store,
    agent: &str,
    profile: &Profile,
    cancel: &AtomicBool,
) -> Result<Value> {
    if agent == "claude-desktop" {
        let prefs = data::settings(store)?;
        let overrides = prefs["sourceOverrides"][agent]
            .as_array()
            .map(|xs| xs.iter().filter_map(|x| x.as_str().map(PathBuf::from)).collect::<Vec<_>>())
            .unwrap_or_default();
        let roots = if overrides.is_empty() { profile.roots(agent)? } else { overrides };
        let mut report = inspect(agent, &roots, profile, cancel, 256, 16 * 1024 * 1024, Duration::from_secs(5));
        let candidate = report["findings"].as_array().is_some_and(|xs| !xs.is_empty());
        let root_found = roots.iter().any(|root| root.is_dir());
        report["verifiedParser"] = Value::Null;
        report["knownEvents"] = Value::Null;
        report["collectionStatus"] = json!(if candidate { "candidate_source" } else if root_found { "no_token_records" } else { "source_unavailable" });
        store.db.execute("INSERT INTO settings(key,value_json) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", rusqlite::params![format!("token-survey:{agent}"), serde_json::to_string(&report)?])?;
        return Ok(report);
    }
    let parser = adapter(agent)?;
    if !data::supported_agent(agent) {
        return Err("UNKNOWN_AGENT".into());
    }
    let prefs = data::settings(store)?;
    let overrides = prefs["sourceOverrides"][agent]
        .as_array()
        .map(|xs| {
            xs.iter()
                .filter_map(|x| x.as_str().map(PathBuf::from))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let roots = if overrides.is_empty() {
        profile.roots(agent)?
    } else {
        overrides.clone()
    };
    let mut report = inspect(
        agent,
        &roots,
        profile,
        cancel,
        256,
        16 * 1024 * 1024,
        Duration::from_secs(5),
    );
    let disabled = prefs["disabledCollectors"]
        .as_array()
        .is_some_and(|xs| xs.iter().any(|x| x == agent));
    let mut collection = "source_unavailable";
    if disabled {
        collection = "disabled"
    } else {
        let mut locator = NativeLocator::new(profile.clone());
        locator.probe = false;
        match locator.discover(agent, &overrides, cancel) {
            Ok(d) => {
                if d.limited || !d.errors.is_empty() {
                    report["limited"] = json!(true)
                }
                if agent == "deepseek-harness" && d.sources.len() > 1 {
                    collection = "error";
                    report["errors"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("Choose one authoritative DSH ledger"))
                } else {
                    let dirs = agentbar_collector::locator::kimi_directories(profile);
                    for source in d.sources {
                        if cancel.load(Ordering::Acquire) {
                            return Err("SURVEY_CANCELLED".into());
                        }
                        match ingest::collect_source(
                            store,
                            &source,
                            &Options::default(),
                            cancel,
                            &dirs,
                        ) {
                            Ok(r) => {
                                if matches!(
                                    r.state,
                                    CollectorState::Error
                                        | CollectorState::Degraded
                                        | CollectorState::RecoveryRequired
                                        | CollectorState::Cancelled
                                ) {
                                    collection = "error";
                                    report["errors"]
                                        .as_array_mut()
                                        .unwrap()
                                        .push(json!("Source collection needs attention"))
                                } else if collection != "error" {
                                    collection = "healthy"
                                }
                            }
                            Err(_) => {
                                collection = "error";
                                report["errors"]
                                    .as_array_mut()
                                    .unwrap()
                                    .push(json!("Source collection needs attention"))
                            }
                        }
                    }
                }
            }
            Err(_) => {
                collection = "error";
                report["errors"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!("Source discovery failed"))
            }
        }
    }
    report["verifiedParser"] = json!(parser.version());
    report["knownEvents"] = json!(store.db.query_row(
        "SELECT count(*) FROM usage_events WHERE agent_id=?",
        [agent],
        |r| r.get::<_, i64>(0)
    )?);
    report["collectionStatus"] = json!(collection);
    store.db.execute("INSERT INTO settings(key,value_json) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json",rusqlite::params![format!("token-survey:{agent}"),serde_json::to_string(&report)?])?;
    Ok(report)
}
fn inspect(
    agent: &str,
    roots: &[PathBuf],
    profile: &Profile,
    cancel: &AtomicBool,
    file_limit: usize,
    byte_limit: usize,
    timeout: Duration,
) -> Value {
    let mut checked = 0usize;
    let mut bytes = 0usize;
    let mut limited = false;
    let mut findings = vec![];
    let mut errors = vec![];
    let start = Instant::now();
    let mut visited = BTreeSet::new();
    let mut entries = 0;
    'roots: for root in roots {
        if safe_root(root, profile).is_err() {
            errors.push("Survey root is too broad or unavailable".to_owned());
            continue;
        }
        if !root.exists() {
            continue;
        }
        let mut stack = vec![(root.clone(), 0usize)];
        while let Some((path, depth)) = stack.pop() {
            if cancel.load(Ordering::Acquire)
                || checked >= file_limit
                || bytes >= byte_limit
                || start.elapsed() >= timeout
                || entries >= 50000
            {
                limited = true;
                break 'roots;
            }
            entries += 1;
            if excluded(&path) || !visited.insert(path.clone()) {
                continue;
            }
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                errors.push("Cannot inspect source metadata".into());
                continue;
            };
            if io::is_reparse(&meta) {
                continue;
            }
            if meta.is_dir() {
                if depth >= 6 {
                    limited = true;
                    continue;
                }
                match std::fs::read_dir(&path) {
                    Ok(children) => {
                        for child in children.flatten() {
                            stack.push((child.path(), depth + 1))
                        }
                    }
                    Err(_) => errors.push("Cannot inspect source directory".into()),
                };
                continue;
            }
            if !meta.is_file() {
                continue;
            }
            checked += 1;
            let ext = path
                .extension()
                .unwrap_or_default()
                .to_string_lossy()
                .to_lowercase();
            let mut found = BTreeSet::new();
            let mut format = None;
            let claude_storage = agent == "claude-desktop"
                && path.components().any(|part| {
                    let name = part.as_os_str().to_string_lossy();
                    name.eq_ignore_ascii_case("IndexedDB")
                        || name.eq_ignore_ascii_case("local-agent-mode-sessions")
                });
            if ["sqlite", "db", "vscdb"].contains(&ext.as_str()) {
                if io::safe_path(&path).is_err() {
                    errors.push("Cannot inspect source schema".into());
                    continue;
                }
                match rusqlite::Connection::open_with_flags(
                    &path,
                    OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )
                .and_then(|db| {
                    db.busy_timeout(Duration::from_millis(250))?;
                    let mut q = db.prepare(
                        "SELECT substr(sql,1,4096) FROM sqlite_master WHERE type='table' LIMIT 256",
                    )?;
                    let mut rows = q.query([])?;
                    while let Some(row) = rows.next()? {
                        if bytes >= byte_limit || start.elapsed() >= timeout {
                            limited = true;
                            break;
                        }
                        let schema: String = row.get::<_, Option<String>>(0)?.unwrap_or_default();
                        bytes += schema.len();
                        for field in FIELDS {
                            if schema.contains(field) {
                                found.insert(field.to_string());
                            }
                        }
                        if ["antigravity", "antigravity-ide"].contains(&agent)
                            && schema.contains("gen_metadata")
                        {
                            found.insert("gen_metadata.data".into());
                        }
                    }
                    Ok(())
                }) {
                    Ok(()) => format = Some("SQLite schema"),
                    Err(_) => errors.push("Cannot inspect source schema".into()),
                }
            } else if ["json", "jsonl", "log"].contains(&ext.as_str())
                || (claude_storage && (ext.is_empty() || ["ldb", "sst"].contains(&ext.as_str())))
            {
                match io::open_read(&path) {
                    Ok((file, snapshot)) => {
                        let amount = (byte_limit - bytes).min(1024 * 1024);
                        let mut raw = Vec::new();
                        if file.take(amount as u64).read_to_end(&mut raw).is_ok() {
                            bytes += raw.len();
                            if snapshot.size > raw.len() as u64 {
                                limited = true
                            }
                            for field in FIELDS {
                                let marker = format!("\"{field}\"");
                                if raw.windows(marker.len()).any(|s| s == marker.as_bytes()) {
                                    found.insert(field.to_string());
                                }
                            }
                            format = Some(if claude_storage && !["json", "jsonl", "log"].contains(&ext.as_str()) {
                                "Claude local metadata blob"
                            } else if ext == "jsonl" {
                                "JSONL"
                            } else if ext == "json" {
                                "JSON"
                            } else {
                                "LOG"
                            })
                        } else {
                            errors.push("Cannot inspect source file".into())
                        }
                    }
                    Err(_) => errors.push("Cannot inspect source file".into()),
                }
            }
            if let Some(format) = format {
                if !found.is_empty() {
                    findings.push(json!({"path":path,"format":format,"fields":found,"status":"candidate_source"}))
                }
            }
        }
    }
    findings.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    errors.sort();
    errors.dedup();
    json!({"version":"token-source-survey-v1.0.0","agentID":agent,"checkedAt":iso(chrono::Utc::now()),"roots":roots,"filesChecked":checked,"bytesRead":bytes,"limited":limited,"findings":findings,"errors":errors,"collectionStatus":"not_collected"})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn survey_reconciles_dsh_persists_metadata_and_skips_secrets() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let home = base.join("home");
        let root = home.join(".dsh/storages");
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("dsh_token_usage_sidebar.sqlite");
        let source = rusqlite::Connection::open(&path).unwrap();
        source
            .execute_batch(include_str!(
                "../../../Shared/core/agentbar-collector/tests/fixtures/dsh-ledger-v4.sql"
            ))
            .unwrap();
        drop(source);
        std::fs::write(
            root.join("auth.json"),
            "{\"input_tokens\":123,\"SECRET_CANARY\":true}",
        )
        .unwrap();
        let before = std::fs::read(&path).unwrap();
        let profile = Profile {
            home,
            appdata: None,
            localappdata: None,
            codex_home: None,
            claude_config: None,
        };
        let mut store =
            agentbar_collector::cli::open_owned(&base.join("owned/usage.sqlite"), &[]).unwrap();
        let cancel = AtomicBool::new(false);
        let report = run(&mut store, "deepseek-harness", &profile, &cancel).unwrap();
        assert_eq!(report["knownEvents"], 2);
        assert_eq!(report["collectionStatus"], "healthy");
        assert_eq!(report["findings"].as_array().unwrap().len(), 1);
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert!(!report.to_string().contains("SECRET_CANARY"));
        assert_eq!(load(&store, "deepseek-harness").unwrap(), report);
        let again = run(&mut store, "deepseek-harness", &profile, &cancel).unwrap();
        assert_eq!(again["knownEvents"], 2);
        let coverage = data::coverage(&store, "deepseek-harness", "healthy", &[]).unwrap();
        assert_eq!(coverage["records"], 2);
        assert_eq!(coverage["status"], "observed");
        assert!(coverage["earliest"].is_string());
        assert!(coverage["latest"].is_string());
        assert_eq!(
            data::query(
                &store,
                "token-survey?agent=deepseek-harness",
                chrono::Utc::now(),
                "UNVERIFIED_WINDOWS_TIME_ZONE",
                &json!({}),
                &json!([])
            )
            .unwrap(),
            again
        );
        let mut prefs = data::defaults();
        prefs["disabledCollectors"] = json!(["deepseek-harness"]);
        data::save_settings(&store, prefs).unwrap();
        assert_eq!(
            run(&mut store, "deepseek-harness", &profile, &cancel).unwrap()["collectionStatus"],
            "disabled"
        );
        assert!(run(&mut store, "unknown-agent", &profile, &cancel).is_err());
    }
    #[test]
    fn claude_desktop_chat_candidates_never_become_usage_events() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let home = base.join("home");
        let appdata = home.join("AppData/Roaming");
        let localappdata = home.join("AppData/Local");
        let cowork = appdata.join("Claude/local-agent-mode-sessions/anonymous-session");
        let indexed = localappdata.join("Claude/IndexedDB");
        std::fs::create_dir_all(&cowork).unwrap();
        std::fs::create_dir_all(&indexed).unwrap();
        std::fs::write(
            cowork.join("audit.jsonl"),
            "{\"input_tokens\":17,\"source_id\":\"anonymous-request\",\"field_value_canary\":\"VALUE_SHOULD_NOT_PERSIST\"}\n",
        )
        .unwrap();
        std::fs::write(indexed.join("000001.ldb"), b"{\"totalTokens\":44}").unwrap();
        let profile = Profile {
            home,
            appdata: Some(appdata),
            localappdata: Some(localappdata),
            codex_home: None,
            claude_config: None,
        };
        let mut store = agentbar_collector::cli::open_owned(&base.join("owned/usage.sqlite"), &[]).unwrap();
        let report = run(&mut store, "claude-desktop", &profile, &AtomicBool::new(false)).unwrap();
        assert_eq!(report["collectionStatus"], "candidate_source");
        assert!(report["verifiedParser"].is_null());
        assert!(report["knownEvents"].is_null());
        assert!(report.to_string().contains("input_tokens"));
        assert!(report.to_string().contains("totalTokens"));
        assert!(!report.to_string().contains("VALUE_SHOULD_NOT_PERSIST"));
        assert!(store.events().unwrap().is_empty());
        assert_eq!(data::coverage(&store, "claude-desktop", "source_unverified", &[]).unwrap()["status"], "source_unverified");
    }
    #[test]
    fn scan_limits_are_explicit_and_values_never_escape() {
        let temp = tempfile::tempdir().unwrap();
        let base = temp.path().canonicalize().unwrap();
        let home = base.join("home");
        let root = home.join(".pi/agent/sessions");
        std::fs::create_dir_all(&root).unwrap();
        for n in 0..3 {
            std::fs::write(
                root.join(format!("{n}.jsonl")),
                "{\"input_tokens\":10,\"content\":\"SECRET_CANARY\"}\n",
            )
            .unwrap()
        }
        let profile = Profile {
            home,
            appdata: None,
            localappdata: None,
            codex_home: None,
            claude_config: None,
        };
        let report = inspect(
            "pi",
            &[root],
            &profile,
            &AtomicBool::new(false),
            1,
            1024,
            Duration::from_secs(5),
        );
        assert_eq!(report["limited"], true);
        assert_eq!(report["filesChecked"], 1);
        assert!(!report.to_string().contains("SECRET_CANARY"));
        assert_eq!(report["findings"][0]["fields"], json!(["input_tokens"]));
    }
}
