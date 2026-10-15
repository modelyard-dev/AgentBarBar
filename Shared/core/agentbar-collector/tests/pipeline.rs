use agentbar_collector::{cli::open_owned, ingest::*, locator::*};
use agentbar_core::{aggregation::QueryFilter, storage::Store};
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    sync::atomic::{AtomicBool, Ordering},
};
struct Fixture {
    dir: tempfile::TempDir,
    profile: Profile,
    root: std::path::PathBuf,
    path: std::path::PathBuf,
    db: std::path::PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().canonicalize().unwrap();
        let root = base.join("source");
        fs::create_dir(&root).unwrap();
        let path = root.join("rollout-test.jsonl");
        fs::write(&path,format!("{}\n",json!({"type":"session_meta","timestamp":"2026-10-05T04:00:00Z","payload":{"id":"anonymous-test"}}))).unwrap();
        let profile = Profile {
            home: base.clone(),
            appdata: None,
            localappdata: None,
            codex_home: None,
            claude_config: None,
        };
        let db = base.join("database/usage.sqlite");
        Self {
            dir,
            profile,
            root,
            path,
            db,
        }
    }
    fn append(&self, id: &str) {
        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(&self.path)
            .unwrap();
        writeln!(file, "{}", row(id)).unwrap();
    }
    fn discover(&self) -> Vec<SourceDescriptor> {
        let mut l = NativeLocator::new(self.profile.clone());
        l.probe = false;
        l.discover(
            "codex",
            std::slice::from_ref(&self.root),
            &AtomicBool::new(false),
        )
        .unwrap()
        .sources
    }
    fn run(&self, store: &mut Store) -> Vec<SourceResult> {
        collect(
            store,
            &self.discover(),
            &Options::default(),
            &AtomicBool::new(false),
            &BTreeMap::new(),
        )
    }
    fn store(&self) -> Store {
        open_owned(&self.db, std::slice::from_ref(&self.root)).unwrap()
    }
}
fn row(id: &str) -> serde_json::Value {
    json!({"type":"token_usage_record","timestamp":"2026-10-05T04:00:01Z","payload":{"response_id":id,"usage":{"input_tokens":100,"output_tokens":23,"cached_input_tokens":40,"cache_write_input_tokens":2,"reasoning_output_tokens":7,"total_tokens":123}}})
}
#[test]
fn append_restart_reimport_100_times() {
    let f = Fixture::new();
    f.append("a");
    {
        let mut store = f.store();
        assert_eq!(f.run(&mut store)[0].metrics.records_inserted, 1);
        assert_eq!(f.run(&mut store)[0].metrics.bytes_read, 0);
    }
    f.append("b");
    for i in 0..100 {
        let mut store = f.store();
        let r = f.run(&mut store);
        assert_eq!(r[0].metrics.records_inserted, if i == 0 { 1 } else { 0 });
        assert_eq!(
            store
                .summary_sql(&QueryFilter::default(), chrono::Utc::now())
                .unwrap()
                .events,
            2
        );
    }
}
#[test]
fn partial_tail_is_never_checkpointed() {
    let f = Fixture::new();
    let mut file = fs::OpenOptions::new().append(true).open(&f.path).unwrap();
    let raw = row("a").to_string();
    file.write_all(&raw.as_bytes()[..raw.len() / 2]).unwrap();
    drop(file);
    let mut store = f.store();
    let r = f.run(&mut store);
    assert_eq!(r[0].metrics.partial_tails, 1);
    let cp = load(&store, &f.discover()[0].source_id).unwrap().unwrap();
    assert!(cp.offset < fs::metadata(&f.path).unwrap().len());
    assert_eq!(f.run(&mut store)[0].metrics.bytes_read, 0);
    let mut file = fs::OpenOptions::new().append(true).open(&f.path).unwrap();
    writeln!(file, "{}", &raw[raw.len() / 2..]).unwrap();
    drop(file);
    assert_eq!(f.run(&mut store)[0].metrics.records_inserted, 1);
}
#[test]
fn rename_uses_same_file_id_without_rescan() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    let before = f.discover();
    f.run(&mut store);
    let renamed = f.root.join("rollout-renamed.jsonl");
    fs::rename(&f.path, &renamed).unwrap();
    let after = f.discover();
    assert_eq!(before[0].source_id, after[0].source_id);
    let r = collect(
        &mut store,
        &after,
        &Options::default(),
        &AtomicBool::new(false),
        &BTreeMap::new(),
    );
    assert_eq!(r[0].metrics.bytes_read, 0);
    assert_eq!(store.events().unwrap().len(), 1);
}
#[test]
fn truncate_recovers_without_duplicate_count() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    f.run(&mut store);
    fs::write(&f.path,format!("{}\n",json!({"type":"session_meta","timestamp":"2026-10-05T04:00:00Z","payload":{"id":"anonymous-test"}}))).unwrap();
    let cut = f.run(&mut store);
    assert_eq!(cut[0].metrics.resets, 1);
    f.append("a");
    f.append("b");
    let r = f.run(&mut store);
    assert_eq!(store.events().unwrap().len(), 2);
    assert_eq!(r[0].metrics.records_inserted, 1);
}
#[test]
fn replacement_identity_and_rotation_dedup() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    let old = f.discover()[0].source_id.clone();
    f.run(&mut store);
    let rotated = f.root.join("rollout-rotated.jsonl");
    fs::rename(&f.path, &rotated).unwrap();
    fs::copy(&rotated, &f.path).unwrap();
    f.append("b");
    let sources = f.discover();
    assert!(sources.iter().any(|s| s.source_id != old));
    f.run(&mut store);
    assert_eq!(store.events().unwrap().len(), 2);
}
#[test]
fn missed_watcher_hint_reconciles_by_metadata() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    f.run(&mut store);
    f.append("b");
    assert_eq!(f.run(&mut store)[0].metrics.records_inserted, 1);
    assert_eq!(f.run(&mut store)[0].metrics.bytes_read, 0);
}
#[test]
fn malformed_line_pauses_without_advancing() {
    let f = Fixture::new();
    f.append("a");
    let good_len = fs::metadata(&f.path).unwrap().len();
    let mut file = fs::OpenOptions::new().append(true).open(&f.path).unwrap();
    writeln!(file, "{{broken}}").unwrap();
    drop(file);
    f.append("b");
    let mut store = f.store();
    let r = f.run(&mut store);
    assert_eq!(r[0].state, CollectorState::Degraded);
    let cp = load(&store, &r[0].source_id).unwrap().unwrap();
    assert_eq!(cp.offset, good_len);
    assert_eq!(store.events().unwrap().len(), 1);
    assert_eq!(f.run(&mut store)[0].metrics.bytes_read, 0);
}
#[test]
fn unknown_schema_is_opaque_and_not_skipped() {
    let f = Fixture::new();
    let mut file = fs::OpenOptions::new().append(true).open(&f.path).unwrap();
    writeln!(
        file,
        "{}",
        json!({"type":"new-accounting-variant","prompt":"PRIVATE_CANARY"})
    )
    .unwrap();
    drop(file);
    f.append("b");
    let mut store = f.store();
    let results = f.run(&mut store);
    assert_eq!(results[0].metrics.unknown, 1);
    let reported = serde_json::to_string(&results).unwrap();
    assert!(!reported.contains("PRIVATE_CANARY"));
    assert!(!reported.contains("new-accounting-variant"));
    assert_eq!(store.events().unwrap().len(), 0);
}
#[test]
fn corrupt_checkpoint_replays_safely() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    let id = f.run(&mut store)[0].source_id.clone();
    store
        .db
        .execute(
            "UPDATE agentbar_source_checkpoints SET envelope_json='{}' WHERE source_id=?",
            [id],
        )
        .unwrap();
    let r = f.run(&mut store);
    assert_eq!(r[0].metrics.resets, 1);
    assert_eq!(store.events().unwrap().len(), 1);
}
#[test]
fn parser_version_change_blocks_until_explicit_upgrade() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    f.run(&mut store);
    let mut sources = f.discover();
    sources[0].parser_version = "new-unapproved".into();
    let r = collect(
        &mut store,
        &sources,
        &Options::default(),
        &AtomicBool::new(false),
        &BTreeMap::new(),
    );
    assert_eq!(r[0].state, CollectorState::RecoveryRequired);
    assert_eq!(store.events().unwrap().len(), 1);
}
#[test]
fn claude_entrypoint_parser_upgrade_replays_metadata_without_duplication() {
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let home = base.join("home");
    let root = home.join(".claude/projects");
    fs::create_dir_all(&root).unwrap();
    let path = root.join("anonymous-session.jsonl");
    fs::write(
        &path,
        "{\"type\":\"user\",\"sessionId\":\"anonymous-session\",\"timestamp\":\"2026-10-13T09:00:00Z\",\"entrypoint\":\"claude-desktop\"}\n{\"type\":\"assistant\",\"sessionId\":\"anonymous-session\",\"timestamp\":\"2026-10-13T09:00:01Z\",\"message\":{\"id\":\"anonymous-message\",\"model\":\"anonymous/model\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"cache_read_input_tokens\":30,\"cache_creation_input_tokens\":4}}}\n",
    )
    .unwrap();
    let profile = Profile {
        home,
        appdata: None,
        localappdata: None,
        codex_home: None,
        claude_config: None,
    };
    let mut locator = NativeLocator::new(profile);
    locator.probe = false;
    let mut source = locator
        .discover("claude-code", &[], &AtomicBool::new(false))
        .unwrap()
        .sources
        .remove(0);
    let current_parser = source.parser_version.clone();
    let mut store = open_owned(&base.join("database/usage.sqlite"), std::slice::from_ref(&root)).unwrap();
    source.parser_version = "claude-jsonl-v1.0.0".into();
    let initial = collect_source(
        &mut store,
        &source,
        &Options::default(),
        &AtomicBool::new(false),
        &BTreeMap::new(),
    )
    .unwrap();
    assert!(!matches!(initial.state, CollectorState::RecoveryRequired));
    source.parser_version = current_parser;
    let upgraded = collect_source(
        &mut store,
        &source,
        &Options::default(),
        &AtomicBool::new(false),
        &BTreeMap::new(),
    )
    .unwrap();
    assert!(!matches!(upgraded.state, CollectorState::RecoveryRequired));
    assert_eq!(upgraded.metrics.resets, 1);
    let events = store.events().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].source_metadata.get("entrypoint").unwrap(), "claude-desktop");
}
#[test]
fn cancellation_leaves_committed_data_valid() {
    let f = Fixture::new();
    f.append("a");
    let mut store = f.store();
    let cancel = AtomicBool::new(true);
    let r = collect(
        &mut store,
        &f.discover(),
        &Options::default(),
        &cancel,
        &BTreeMap::new(),
    );
    assert_eq!(r[0].state, CollectorState::Cancelled);
    assert_eq!(store.events().unwrap().len(), 0);
    cancel.store(false, Ordering::Relaxed);
    assert_eq!(f.run(&mut store)[0].metrics.records_inserted, 1);
}
#[test]
fn bounded_batches_and_readonly_hash() {
    let f = Fixture::new();
    for n in 0..1000 {
        f.append(&format!("anonymous-{n}"));
    }
    let before = fs::read(&f.path).unwrap();
    let mut store = f.store();
    let r = f.run(&mut store);
    assert!(r[0].metrics.max_batch_events <= 200);
    assert!(r[0].metrics.commits >= 5);
    assert_eq!(fs::read(&f.path).unwrap(), before);
    assert_eq!(f.run(&mut store)[0].metrics.bytes_read, 0);
}
#[test]
fn error_in_one_source_does_not_block_other_sources() {
    let f = Fixture::new();
    f.append("a");
    let bad = f.root.join("rollout-bad.jsonl");
    fs::write(bad, b"{broken}\n").unwrap();
    let mut store = f.store();
    let r = f.run(&mut store);
    assert!(r.iter().any(|r| r.state == CollectorState::Degraded));
    assert_eq!(store.events().unwrap().len(), 1);
}
#[test]
fn safe_roots_and_foreign_database_are_rejected() {
    let f = Fixture::new();
    assert!(safe_root(&f.profile.home, &f.profile).is_err());
    let foreign = f.dir.path().join("foreign.sqlite");
    let db = rusqlite::Connection::open(&foreign).unwrap();
    db.execute_batch("CREATE TABLE sensitive(x TEXT)").unwrap();
    drop(db);
    let before = fs::read(&foreign).unwrap();
    assert!(open_owned(&foreign, &[]).is_err());
    assert_eq!(fs::read(foreign).unwrap(), before);
    assert!(open_owned(&f.root.join("never.sqlite"), std::slice::from_ref(&f.root)).is_err());
}
#[cfg(unix)]
#[test]
fn symlink_loop_is_rejected() {
    let f = Fixture::new();
    std::os::unix::fs::symlink(&f.root, f.root.join("loop")).unwrap();
    assert_eq!(f.discover().len(), 1);
    assert!(agentbar_collector::io::open_read(&f.root.join("loop/rollout-test.jsonl")).is_err());
}
#[test]
fn utf8_bom_and_crlf_are_io_variants() {
    let f = Fixture::new();
    let metadata = fs::read(&f.path).unwrap();
    let mut all = vec![0xef, 0xbb, 0xbf];
    all.extend(metadata);
    all.extend(format!("{}\r\n", row("a")).as_bytes());
    fs::write(&f.path, all).unwrap();
    let mut store = f.store();
    assert_eq!(f.run(&mut store)[0].metrics.records_inserted, 1);
}
#[test]
fn windows_claude_nonusage_envelope_fixture_is_explicit() {
    let f = Fixture::new();
    fs::remove_file(&f.path).unwrap();
    let raw = include_bytes!(
        "../../../../Tests/Fixtures/Envelopes/claude-windows-envelope.jsonl"
    );
    fs::write(f.root.join("anonymous.jsonl"), raw).unwrap();
    let mut locator = NativeLocator::new(f.profile.clone());
    locator.probe = false;
    let sources = locator
        .discover(
            "claude-code",
            std::slice::from_ref(&f.root),
            &AtomicBool::new(false),
        )
        .unwrap()
        .sources;
    let mut store = f.store();
    let r = collect(
        &mut store,
        &sources,
        &Options::default(),
        &AtomicBool::new(false),
        &BTreeMap::new(),
    );
    assert_eq!(r[0].metrics.records_inserted, 1);
    assert_eq!(r[0].metrics.ignored, 4);
    assert_eq!(r[0].state, CollectorState::Idle);
}
#[test]
fn real_watcher_notification_is_only_a_hint() {
    let f = Fixture::new();
    let mut hints = agentbar_collector::watch::WatchHints::new(
        std::slice::from_ref(&f.root),
        std::time::Duration::from_millis(300),
    )
    .unwrap();
    let mut store = f.store();
    f.run(&mut store);
    f.append("a");
    let start = std::time::Instant::now();
    let mut changed = false;
    while start.elapsed() < std::time::Duration::from_secs(3) {
        std::thread::sleep(std::time::Duration::from_millis(50));
        let h = hints.drain();
        if !h.changed.is_empty() || h.full_reconcile {
            changed = true;
            break;
        }
    }
    assert!(changed);
    assert_eq!(f.run(&mut store)[0].metrics.records_inserted, 1);
    assert_eq!(f.run(&mut store)[0].metrics.bytes_read, 0);
}
#[cfg(windows)]
#[test]
fn windows_junction_loop_is_never_traversed() {
    let f = Fixture::new();
    let link = f.root.join("loop");
    let result = std::process::Command::new("cmd.exe")
        .args([
            "/c",
            "mklink",
            "/J",
            link.to_str().unwrap(),
            f.root.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(result.status.success());
    assert_eq!(f.discover().len(), 1);
    assert!(agentbar_collector::io::open_read(&link.join("rollout-test.jsonl")).is_err());
}
#[test]
fn committed_progress_can_cancel_gui_import_and_resume() {
 let f=Fixture::new();for i in 0..1000{f.append(&format!("progress-{i}"));}
 let mut store=f.store();let source=f.discover().remove(0);let cancel=AtomicBool::new(false);
 let result=collect_source_with_progress(&mut store,&source,&Options::default(),&cancel,&BTreeMap::new(),&|m|{if m.records_inserted>=200{cancel.store(true,Ordering::Release)}}).unwrap();
 assert_eq!(result.state,CollectorState::Cancelled);assert_eq!(store.events().unwrap().len(),200);assert!(load(&store,&source.source_id).unwrap().unwrap().pending_import);
 drop(store);let mut store=f.store();f.run(&mut store);assert_eq!(store.events().unwrap().len(),1000);assert_eq!(f.run(&mut store)[0].metrics.bytes_read,0);
}
