use agentbar_core::storage::Store;
use serde_json::json;
use std::{fs, process::Command};
#[test]
fn process_crashes_at_all_boundaries_replay_to_identical_logical_rows() {
    for point in [
        "after-read",
        "after-parse",
        "before-checkpoint",
        "during-checkpoint",
        "after-commit",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().canonicalize().unwrap();
        let root = base.join("sources");
        fs::create_dir(&root).unwrap();
        let mut text = format!(
            "{}\n",
            json!({"type":"session_meta","timestamp":"2026-10-05T04:00:00Z","payload":{"id":"anonymous-crash"}})
        );
        for n in 0..1000 {
            text += &format!(
                "{}\n",
                json!({"type":"token_usage_record","timestamp":"2026-10-05T04:00:01Z","payload":{"response_id":format!("anonymous-{n}"),"usage":{"input_tokens":100,"output_tokens":23,"cached_input_tokens":40,"cache_write_input_tokens":2,"reasoning_output_tokens":7,"total_tokens":123}}})
            );
        }
        fs::write(root.join("rollout-crash.jsonl"), text).unwrap();
        let db = base.join("database/usage.sqlite");
        let args = [
            "collect",
            "codex",
            "--root",
            root.to_str().unwrap(),
            "--db",
            db.to_str().unwrap(),
        ];
        let crashed = Command::new(env!("CARGO_BIN_EXE_agentbar-core-cli"))
            .args(args)
            .args(["--qa-fault", "--fault", point])
            .output()
            .unwrap();
        assert_eq!(
            crashed.status.code(),
            Some(86),
            "fault {point}: {}",
            String::from_utf8_lossy(&crashed.stderr)
        );
        for repeat in 0..3 {
            let restarted = Command::new(env!("CARGO_BIN_EXE_agentbar-core-cli"))
                .args(args)
                .output()
                .unwrap();
            assert!(
                restarted.status.success(),
                "{point}: {}",
                String::from_utf8_lossy(&restarted.stderr)
            );
            let report: serde_json::Value = serde_json::from_slice(&restarted.stdout).unwrap();
            assert_eq!(report["agents"]["codex"]["ranges"]["all"]["events"], 1000);
            if repeat > 0 {
                assert_eq!(report["metrics"]["bytesRead"], 0);
            }
        }
        let store = Store::open(&db).unwrap();
        assert_eq!(store.events().unwrap().len(), 1000);
        let integrity: String = store
            .db
            .query_row("PRAGMA integrity_check", [], |r| r.get(0))
            .unwrap();
        assert_eq!(integrity, "ok");
    }
}
#[test]
fn batch_601_exception_rolls_back_prior_600_and_cursor() {
    let mut store = Store::memory().unwrap();
    agentbar_collector::ingest::initialize(&store).unwrap();
    let payload: serde_json::Value = serde_json::from_slice(include_bytes!(
        "../../../../Tests/Fixtures/Contracts/normalized-swift.json"
    ))
    .unwrap();
    let original: agentbar_core::domain::NormalizedUsageRecord =
        serde_json::from_value(payload[0].clone()).unwrap();
    let mut events = Vec::new();
    for n in 0..1000 {
        let mut e = original.clone();
        e.source_event_id = format!("{}:anonymous-batch-{n}", e.agent_id);
        e.id = agentbar_core::domain::hash(&e.source_event_id);
        e.fingerprint = e.id.clone();
        events.push(e);
    }
    events[600].id = "malformed-id".into();
    let result = store.commit_atomic(&events, &Default::default(), |tx| {
        tx.execute(
            "INSERT INTO agentbar_source_checkpoints VALUES('anonymous','codex','fixture','{}')",
            [],
        )?;
        Ok(())
    });
    assert!(result.is_err());
    assert_eq!(store.events().unwrap().len(), 0);
    assert_eq!(
        store
            .db
            .query_row(
                "SELECT COUNT(*) FROM agentbar_source_checkpoints",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
}
