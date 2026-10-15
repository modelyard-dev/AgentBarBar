use agentbar_collector::{
    cli::open_owned,
    ingest::{self, Options},
    locator::{NativeLocator, Profile, SourceLocator},
};
use agentbar_core::storage::Store;
use std::{path::Path, sync::atomic::AtomicBool};
fn profile(home: &Path) -> Profile {
    Profile {
        home: home.into(),
        appdata: None,
        localappdata: None,
        codex_home: None,
        claude_config: None,
    }
}
fn collect(store: &mut Store, home: &Path, agent: &str) -> ingest::Metrics {
    let mut locator = NativeLocator::new(profile(home));
    locator.probe = false;
    let cancel = AtomicBool::new(false);
    let d = locator.discover(agent, &[], &cancel).unwrap();
    assert!(!d.sources.is_empty(), "{agent}");
    let mut metrics = ingest::Metrics::default();
    for s in d.sources {
        let result =
            ingest::collect_source(store, &s, &Options::default(), &cancel, &Default::default())
                .unwrap();
        assert!(
            !matches!(
                result.state,
                ingest::CollectorState::Degraded | ingest::CollectorState::Error
            ),
            "{agent}: {:?}",
            result.diagnostics
        );
        metrics.add(&result.metrics)
    }
    metrics
}
fn write(root: &Path, path: &str, bytes: &[u8]) {
    let p = root.join(path);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap()
}
#[test]
fn all_remaining_collectors_replay_dedup_and_preserve_source() {
    let t = tempfile::tempdir().unwrap();
    let base = t.path().canonicalize().unwrap();
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    write(
        &home,
        ".pi/agent/sessions/a.jsonl",
        include_bytes!("fixtures/pi.jsonl"),
    );
    write(
        &home,
        ".pi/agent/sessions/tools.jsonl",
        include_bytes!("fixtures/pi-tool-usage.jsonl"),
    );
    write(
        &home,
        ".workbuddy/projects/a.jsonl",
        include_bytes!("fixtures/workbuddy.jsonl"),
    );
    write(
        &home,
        ".gemini/tmp/project/chats/session-a.json",
        include_bytes!("fixtures/gemini-session.json"),
    );
    for (path, sql) in [
        (
            ".dsh/storages/dsh_token_usage_sidebar.sqlite",
            include_str!("fixtures/dsh-ledger-v4.sql"),
        ),
        (
            ".local/share/opencode/opencode.db",
            include_str!("fixtures/opencode.sql"),
        ),
    ] {
        let p = home.join(path);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        rusqlite::Connection::open(p)
            .unwrap()
            .execute_batch(sql)
            .unwrap();
    }
    let mut store = open_owned(&base.join("owned/usage.sqlite"), &[]).unwrap();
    for (agent, count) in [
        ("pi", 3),
        ("workbuddy", 2),
        ("gemini", 2),
        ("deepseek-harness", 2),
        ("opencode", 1),
    ] {
        collect(&mut store, &home, agent);
        let actual: i64 = store
            .db
            .query_row(
                "SELECT count(*) FROM usage_events WHERE agent_id=?",
                [agent],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(actual, count, "{agent}");
        let idle = collect(&mut store, &home, agent);
        assert_eq!(idle.records_inserted, 0);
        assert_eq!(idle.bytes_read, 0);
    }
    let events = store.events().unwrap();
    assert!(!serde_json::to_string(&events)
        .unwrap()
        .contains("SECRET_CANARY"));
    let dsh: Vec<_> = events
        .iter()
        .filter(|e| e.agent_id == "deepseek-harness")
        .collect();
    assert_eq!(
        dsh.iter()
            .map(|e| e.metrics["total"].value.unwrap())
            .sum::<i64>(),
        410
    );
    assert_eq!(dsh[0].metrics["input"].value, Some(150));
    let p = home.join(".dsh/storages/dsh_token_usage_sidebar.sqlite");
    let source_before = std::fs::read(&p).unwrap();
    collect(&mut store, &home, "deepseek-harness");
    assert_eq!(std::fs::read(&p).unwrap(), source_before);
    // Canonical corrections lower a request and exclude another. No log counts survive.
    let db = rusqlite::Connection::open(&p).unwrap();
    db.execute_batch("UPDATE usage_records SET input_tokens=10,total_tokens=120,updated_at=3000 WHERE canonical_id='anonymous-session:1:1'; UPDATE usage_records SET excluded_reason='corrected',updated_at=3000 WHERE canonical_id='anonymous-session:1:2'; UPDATE meta SET record_generation=3,aggregate_generation=3; UPDATE aggregate_global SET calls=1,total_tokens=120;").unwrap();
    drop(db);
    collect(&mut store, &home, "deepseek-harness");
    let actual: (i64, i64) = store
        .db
        .query_row(
            "SELECT count(*),sum(total_tokens) FROM usage_events WHERE agent_id='deepseek-harness'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(actual, (1, 120));
    // An unfinished accounting migration must not replace the last valid snapshot.
    let db = rusqlite::Connection::open(&p).unwrap();
    db.execute_batch("UPDATE meta SET aggregate_generation=2")
        .unwrap();
    drop(db);
    let mut locator = NativeLocator::new(profile(&home));
    locator.probe = false;
    let cancel = AtomicBool::new(false);
    let d = locator.discover("deepseek-harness", &[], &cancel).unwrap();
    assert!(ingest::collect_source(
        &mut store,
        &d.sources[0],
        &Options::default(),
        &cancel,
        &Default::default()
    )
    .is_err());
    assert_eq!(
        store
            .db
            .query_row(
                "SELECT sum(total_tokens) FROM usage_events WHERE agent_id='deepseek-harness'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        120
    );
}
fn n(field: u64, value: u64) -> Vec<u8> {
    let mut out = v(field << 3);
    out.extend(v(value));
    out
}
fn v(mut value: u64) -> Vec<u8> {
    let mut out = vec![];
    loop {
        let byte = (value & 127) as u8;
        value >>= 7;
        out.push(byte | if value > 0 { 128 } else { 0 });
        if value == 0 {
            return out;
        }
    }
}
fn b(field: u64, data: &[u8]) -> Vec<u8> {
    let mut out = v(field << 3 | 2);
    out.extend(v(data.len() as u64));
    out.extend(data);
    out
}
#[test]
fn antigravity_both_variants_wait_for_completion_and_ignore_content() {
    let t = tempfile::tempdir().unwrap();
    let base = t.path().canonicalize().unwrap();
    let home = base.join("home");
    let mut store = open_owned(&base.join("owned/usage.sqlite"), &[]).unwrap();
    for (agent, dir) in [
        ("antigravity", ".gemini/antigravity-cli/conversations"),
        ("antigravity-ide", ".gemini/antigravity/conversations"),
    ] {
        let p = home.join(dir).join("anonymous.db");
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        let db = rusqlite::Connection::open(&p).unwrap();
        db.execute_batch("CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB);CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,metadata BLOB);INSERT INTO steps VALUES(2,2,NULL)").unwrap();
        let usage = [
            n(2, 100),
            n(3, 20),
            n(5, 800),
            n(9, 5),
            n(6, 24),
            b(11, b"anonymous-generation"),
        ]
        .concat();
        let chat = [
            b(4, &usage),
            b(9, &b(4, &n(1, 1791115201))),
            b(19, b"gemini/raw"),
            b(1, b"SECRET_CANARY"),
        ]
        .concat();
        let blob = [
            b(1, &chat),
            b(2, &[2]),
            b(4, b"anonymous-execution"),
            b(9, b"SECRET_CANARY"),
        ]
        .concat();
        db.execute("INSERT INTO gen_metadata VALUES(0,?)", [blob])
            .unwrap();
        collect(&mut store, &home, agent);
        assert_eq!(
            store
                .db
                .query_row(
                    "SELECT count(*) FROM usage_events WHERE agent_id=?",
                    [agent],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        db.execute_batch("UPDATE steps SET status=3").unwrap();
        drop(db);
        collect(&mut store, &home, agent);
        let e = store
            .events()
            .unwrap()
            .into_iter()
            .find(|e| e.agent_id == agent)
            .unwrap();
        assert_eq!(e.metrics["total"].value, Some(920));
        assert_eq!(e.metrics["reasoning"].value, Some(5));
        assert!(!serde_json::to_string(&e).unwrap().contains("SECRET_CANARY"));
        assert_eq!(collect(&mut store, &home, agent).bytes_read, 0);
    }
}
#[test]
fn nine_unchanged_agents_match_archived_swift_golden() {
    let t = tempfile::tempdir().unwrap();
    let base = t.path().canonicalize().unwrap();
    let home = base.join("home");
    for (path, bytes) in [
        (
            ".codex/sessions/rollout-request.jsonl",
            include_bytes!("fixtures/golden/codex-request.jsonl").as_slice(),
        ),
        (
            ".claude/projects/anonymous/session.jsonl",
            include_bytes!("fixtures/golden/claude.jsonl").as_slice(),
        ),
        (
            ".pi/agent/sessions/anonymous/session.jsonl",
            include_bytes!("fixtures/golden/pi.jsonl").as_slice(),
        ),
        (
            ".kimi/sessions/anonymous-workdir/anonymous-session/wire.jsonl",
            include_bytes!("fixtures/golden/kimi-wire.jsonl").as_slice(),
        ),
        (
            ".workbuddy/projects/anonymous/session.jsonl",
            include_bytes!("fixtures/golden/workbuddy.jsonl").as_slice(),
        ),
        (
            ".gemini/tmp/anonymous/chats/session-fixture.json",
            include_bytes!("fixtures/golden/gemini-session.json").as_slice(),
        ),
    ] {
        write(&home, path, bytes)
    }
    for (path, sql) in [
        (
            ".dsh/storages/dsh_token_usage_sidebar.sqlite",
            include_str!("fixtures/golden/dsh-ledger-v4.sql"),
        ),
        (
            ".local/share/opencode/opencode.db",
            include_str!("fixtures/golden/opencode.sql"),
        ),
        (
            ".gemini/antigravity-cli/conversations/anonymous.db",
            include_str!("fixtures/golden/antigravity.sql"),
        ),
        (
            ".gemini/antigravity/conversations/anonymous.db",
            include_str!("fixtures/golden/antigravity.sql"),
        ),
    ] {
        let p = home.join(path);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        rusqlite::Connection::open(p)
            .unwrap()
            .execute_batch(sql)
            .unwrap()
    }
    let mut store = open_owned(&base.join("owned/usage.sqlite"), &[]).unwrap();
    for agent in [
        "codex",
        "claude-code",
        "pi",
        "kimi-cli",
        "workbuddy",
        "gemini",
        "deepseek-harness",
        "opencode",
        "antigravity",
        "antigravity-ide",
    ] {
        collect(&mut store, &home, agent);
    }
    let expected: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/golden/expected-swift.json")).unwrap();
    let actual = store.events().unwrap();
    assert_eq!(actual.len(), expected["events"].as_array().unwrap().len());
    // Gemini changed in 1.0.6; retain this archived oracle unchanged.
    // Current Gemini semantics are asserted against ResearchCollectorTests.swift.
    for reference in expected["events"].as_array().unwrap().iter().filter(|e| e["agentID"] != "gemini") {
        let e = actual
            .iter()
            .find(|e| e.source_event_id == reference["sourceEventID"])
            .unwrap_or_else(|| panic!("missing {}", reference["sourceEventID"]));
        let row = serde_json::to_value(e).unwrap();
        for field in [
            "id",
            "timestamp",
            "agentID",
            "provider",
            "rawModelName",
            "sessionID",
            "metrics",
            "sourceEventID",
            "fingerprint",
            "parserVersion",
            "quality",
        ] {
            assert_eq!(
                row.get(field),
                reference.get(field),
                "{} {field}",
                e.source_event_id
            );
        }
    }
}
