use agentbar_core::{aggregation::*, domain::*, parser::*, storage::*, Result};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    fs,
    path::PathBuf,
};
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}
fn corpus() -> Vec<NormalizedUsageRecord> {
    serde_json::from_slice(
        &fs::read(root().join("Tests/Fixtures/Contracts/normalized-swift.json")).unwrap(),
    )
    .unwrap()
}
fn parse(agent: &str, name: &str) -> Result<Vec<NormalizedUsageRecord>> {
    let bytes = fs::read(root().join("Tests/Fixtures/Shared").join(name))?;
    let p = adapter(agent)?;
    let mut state = ParserState::default();
    let mut ctx = ParseContext::fixture(agent, "fixture");
    let mut events = Vec::new();
    for line in bytes.split_inclusive(|b| *b == 10) {
        if let Some(e) = p.parse(line, &mut state, &ctx)? {
            events.push(e)
        }
        ctx.line += 1;
        ctx.offset += line.len() as u64;
    }
    let mut db = Store::memory()?;
    db.commit(&events)?;
    db.events()
}
#[test]
fn codex_swift_golden() {
    golden("codex", "codex-request.jsonl")
}
#[test]
fn claude_swift_golden() {
    golden("claude-code", "claude.jsonl")
}
#[test]
fn claude_desktop_code_entrypoint_is_metadata_only() {
    let events = parse("claude-code", "claude-entrypoint-v1.jsonl").unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].source_metadata.get("entrypoint").unwrap(), "claude-desktop");
    assert_eq!(events[0].metrics["total"].value, Some(154));
    assert_eq!(events[0].parser_version, "claude-jsonl-v1.1.0");
}
#[test]
fn kimi_swift_golden() {
    golden("kimi-cli", "kimi-wire.jsonl")
}
fn golden(agent: &str, file: &str) {
    let source: Value = serde_json::from_slice(
        &fs::read(root().join("Tests/Fixtures/Shared/expected-swift.json")).unwrap(),
    )
    .unwrap();
    let want = source["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["agentID"] == agent)
        .cloned()
        .collect::<Vec<_>>();
    let actual = parse(agent, file)
        .unwrap()
        .iter()
        .map(|e| e.golden())
        .collect::<Vec<_>>();
    assert_eq!(actual, want);
}
#[test]
fn all_ten_agents_normalized_contract_and_dedup() {
    let rows = corpus();
    assert_eq!(rows.len(), 14);
    let mut db = Store::memory().unwrap();
    assert_eq!(db.commit(&rows).unwrap().inserted, 14);
    assert_eq!(db.commit(&rows).unwrap().duplicates, 14);
    assert_eq!(db.events().unwrap(), rows);
    for e in rows {
        e.validate().unwrap();
    }
}
#[test]
fn actual_swift_api_summaries_and_groups() {
    let events = corpus();
    let expected: Value = serde_json::from_slice(
        &fs::read(root().join("Tests/Fixtures/Contracts/api-swift.json")).unwrap(),
    )
    .unwrap();
    let now = timestamp(expected["now"].as_str().unwrap()).unwrap();
    let tz = expected["timeZone"].as_str().unwrap();
    for range in ["today", "7", "30", "all"] {
        let f = range_filter(range, now, tz).unwrap();
        assert_eq!(
            serde_json::to_value(summarize(&events, &f, now).unwrap()).unwrap(),
            expected["ranges"][range],
            "range {range}"
        );
    }
    for dimension in ["agents", "models"] {
        assert_eq!(
            serde_json::to_value(groups(&events, dimension, &QueryFilter::default(), now).unwrap())
                .unwrap(),
            expected[dimension],
            "dimension {dimension}"
        );
    }
}
#[test]
fn repeated_100_requests_100_imports() {
    let events = parse("codex", "codex-100.jsonl").unwrap();
    let mut db = Store::memory().unwrap();
    for iteration in 0..100 {
        // Re-read and re-parse the source on every import, not merely replay a cached event vector.
        let reparsed = parse("codex", "codex-100.jsonl").unwrap();
        assert_eq!(reparsed, events);
        let r = db.commit(&reparsed).unwrap();
        assert_eq!(r.inserted, if iteration == 0 { 100 } else { 0 });
        assert_eq!(db.events().unwrap().len(), 100);
    }
    let s = summarize(
        &db.events().unwrap(),
        &QueryFilter::default(),
        timestamp("2026-10-05T05:00:00Z").unwrap(),
    )
    .unwrap();
    let expected: Value = serde_json::from_slice(
        &fs::read(root().join("Tests/Fixtures/Shared/expected-100.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(s.events, 100);
    for k in METRICS {
        if k != "cachedOutput" {
            assert_eq!(s.metrics[k].value, expected[k].as_i64());
        }
    }
}
#[test]
fn true_zero_and_unavailable_are_distinct() {
    assert_eq!(token(&json!({"x":0}), "x").unwrap(), Some(0));
    assert_eq!(token(&json!({}), "x").unwrap(), None);
    assert_ne!(Metric::new(Some(0)), Metric::default());
}
#[test]
fn invalid_tokens_rejected() {
    for v in [
        json!(true),
        json!("1"),
        json!(-1),
        json!(0.5),
        json!(9007199254740992u64),
    ] {
        assert!(token(&json!({"x":v}), "x").is_err());
    }
    assert_eq!(
        token(&json!({"x":9007199254740991u64}), "x").unwrap(),
        Some(TOKEN_LIMIT)
    );
}
#[test]
fn no_cache_or_reasoning_double_sum() {
    let rows = parse("codex", "codex-request.jsonl").unwrap();
    let summary = summarize(
        &rows,
        &QueryFilter::default(),
        timestamp("2026-10-05T04:00:00Z").unwrap(),
    )
    .unwrap();
    assert_eq!(summary.metrics["total"].value, Some(81465));
    assert_eq!(summary.metrics["cacheRead"].value, Some(35712));
}
#[test]
fn incomplete_claude_cache_is_not_zero() {
    let p = adapter("claude-code").unwrap();
    let mut s = ParserState::default();
    let c = ParseContext::fixture("claude-code", "fixture");
    let raw = json!({"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"anonymous","usage":{"input_tokens":1,"output_tokens":2}}});
    let e = p
        .parse(raw.to_string().as_bytes(), &mut s, &c)
        .unwrap()
        .unwrap();
    assert_eq!(e.metrics["total"].value, None);
    assert_eq!(e.quality, "partial");
}
#[test]
fn source_canary_is_not_persisted() {
    let p = adapter("claude-code").unwrap();
    let mut s = ParserState::default();
    let c = ParseContext::fixture("claude-code", "fixture");
    let raw = json!({"type":"assistant","timestamp":"2026-01-01T00:00:00Z","prompt":"SECRET_CANARY","message":{"id":"anonymous","content":"SECRET_CANARY","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}});
    let e = p
        .parse(raw.to_string().as_bytes(), &mut s, &c)
        .unwrap()
        .unwrap();
    let mut store = Store::memory().unwrap();
    store.commit(&[e]).unwrap();
    assert!(!serde_json::to_string(&store.events().unwrap())
        .unwrap()
        .contains("SECRET_CANARY"));
}
#[test]
fn streaming_smaller_snapshot_rejected() {
    let mut e = parse("claude-code", "claude.jsonl").unwrap().remove(0);
    let mut db = Store::memory().unwrap();
    db.commit(&[e.clone()]).unwrap();
    e.metrics.insert("total".into(), Metric::new(Some(30000)));
    assert_eq!(db.commit(&[e.clone()]).unwrap().updated, 1);
    e.metrics.insert("total".into(), Metric::new(Some(28000)));
    assert_eq!(db.commit(&[e]).unwrap().duplicates, 1);
    assert_eq!(db.events().unwrap()[0].metrics["total"].value, Some(30000));
}
#[test]
fn replay_copy_path_does_not_change_identity() {
    let mut e = parse("codex", "codex-request.jsonl").unwrap().remove(0);
    let mut db = Store::memory().unwrap();
    db.commit(&[e.clone()]).unwrap();
    e.source_path = "C:\\anonymous\\renamed.jsonl".into();
    e.source_line = 99;
    e.source_offset = 700;
    assert_eq!(db.commit(&[e]).unwrap().duplicates, 1);
    assert_eq!(db.events().unwrap().len(), 1);
}
#[test]
fn partial_metric_coverage_matches_swift() {
    let mut rows = parse("codex", "codex-request.jsonl").unwrap();
    rows[1]
        .metrics
        .insert("reasoning".into(), Metric::default());
    let s = summarize(
        &rows,
        &QueryFilter::default(),
        timestamp("2026-10-05T04:00:00Z").unwrap(),
    )
    .unwrap();
    assert_eq!(s.metrics["reasoning"].value, Some(0));
    assert_eq!(s.metrics["reasoning"].state, MetricState::Partial);
}
#[test]
fn half_open_timestamp_boundary() {
    let rows = parse("codex", "codex-request.jsonl").unwrap();
    let cut = timestamp(&rows[1].timestamp).unwrap().timestamp_millis() as f64 / 1000.;
    let f = QueryFilter {
        end: Some(cut),
        ..Default::default()
    };
    assert_eq!(
        summarize(&rows, &f, timestamp("2026-10-05T04:00:00Z").unwrap())
            .unwrap()
            .events,
        1
    );
}
#[test]
fn dst_calendar_ranges_not_86400_seconds() {
    for (now, tz, hours) in [
        ("2026-03-08T18:00:00Z", "America/Los_Angeles", 23.),
        ("2026-11-01T18:00:00Z", "America/Los_Angeles", 25.),
        ("2026-03-29T12:00:00Z", "Europe/Berlin", 23.),
    ] {
        let f = range_filter("today", timestamp(now).unwrap(), tz).unwrap();
        assert_eq!((f.end.unwrap() - f.start.unwrap()) / 3600., hours);
    }
}
#[test]
fn windows_timezone_mapping() {
    let now = timestamp("2026-10-05T04:00:00Z").unwrap();
    let a = range_filter("7", now, "China Standard Time").unwrap();
    let b = range_filter("7", now, "Asia/Shanghai").unwrap();
    assert_eq!((a.start, a.end), (b.start, b.end));
    assert!(zone("Unrecognized OS Zone").is_err());
}
#[test]
fn all_migration_versions_to_seven() {
    for version in 0..=7 {
        let mut db = rusqlite::Connection::open_in_memory().unwrap();
        for sql in &MIGRATIONS[..version] {
            db.execute_batch(sql).unwrap();
        }
        migrate(&mut db).unwrap();
        let schema: i64 = db
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(schema, 7);
        let n: i64 = db
            .query_row("select count(*) from schema_migrations", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 7);
    }
}
#[test]
fn schema_matches_actual_swift_database() {
    use std::collections::BTreeMap;
    let expected: Value = serde_json::from_slice(
        &fs::read(root().join("Tests/Fixtures/Contracts/schema-swift.json")).unwrap(),
    )
    .unwrap();
    let store = Store::memory().unwrap();
    let mut tables = BTreeMap::<String, Vec<Value>>::new();
    let names=store.db.prepare("select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name").unwrap().query_map([],|r|r.get::<_,String>(0)).unwrap().collect::<std::result::Result<Vec<_>,_>>().unwrap();
    for name in names {
        let rows = store
            .db
            .prepare(&format!("pragma table_info({name})"))
            .unwrap()
            .query_map([], |r| {
                Ok(json!([
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, i64>(5)?
                ]))
            })
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();
        tables.insert(name, rows);
    }
    let indices=store.db.prepare("select name,tbl_name from sqlite_master where type='index' and name not like 'sqlite_%' order by name").unwrap().query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).unwrap().collect::<std::result::Result<BTreeMap<_,_>,_>>().unwrap();
    assert_eq!(serde_json::to_value(tables).unwrap(), expected["tables"]);
    assert_eq!(serde_json::to_value(indices).unwrap(), expected["indices"]);
}
#[test]
fn migration_corrects_streaming_timestamp_and_metric_states() {
    let mut db = rusqlite::Connection::open_in_memory().unwrap();
    db.execute_batch(MIGRATIONS[0]).unwrap();
    db.execute(
        "INSERT INTO agents VALUES('anonymous','Anonymous','{}')",
        [],
    )
    .unwrap();
    let e = corpus().remove(0);
    let body = serde_json::to_string(&e).unwrap();
    db.execute("INSERT INTO usage_events(id,timestamp,agent_id,is_estimated,source_event_id,fingerprint,source_path,collector_id,event_json,created_at) VALUES('anonymous',0,'anonymous',0,'anonymous:1','anonymous','fixture','fixture',?,?)",rusqlite::params![body,e.created_at]).unwrap();
    migrate(&mut db).unwrap();
    let (epoch, state): (f64, String) = db
        .query_row("select timestamp,total_state from usage_events", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap();
    assert!(
        (epoch - timestamp(&e.timestamp).unwrap().timestamp_millis() as f64 / 1000.).abs()
            < 0.000_001
    );
    assert_eq!(state, "known");
}
#[test]
fn future_schema_rejected_unchanged() {
    let mut db = rusqlite::Connection::open_in_memory().unwrap();
    db.execute_batch("PRAGMA user_version=8").unwrap();
    assert!(migrate(&mut db).is_err());
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        8
    );
}
#[test]
fn malformed_transaction_rolls_back() {
    let mut db = Store::memory().unwrap();
    let good = parse("claude-code", "claude.jsonl").unwrap().remove(0);
    let mut bad = good.clone();
    bad.id = "wrong".into();
    assert!(db.commit(&[good, bad]).is_err());
    assert_eq!(db.events().unwrap().len(), 0);
}
#[test]
fn foreign_keys_and_json_sql_enabled() {
    let db = Store::memory().unwrap();
    assert_eq!(
        db.db
            .query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        db.db
            .query_row("select json_extract('{\"x\":7}','$.x')", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        7
    );
}
#[test]
fn ffi_version_buffer_lifecycle_and_error() {
    use agentbar_core::ffi::*;
    assert_eq!(agentbar_core_abi_version(), 1);
    unsafe {
        assert!(agentbar_core_parse_json(std::ptr::null()).is_null());
        let request = CString::new("{\"agent\":\"unknown\",\"line\":\"SECRET_CANARY\"}").unwrap();
        let p = agentbar_core_parse_json(request.as_ptr());
        let s = CStr::from_ptr(p).to_str().unwrap();
        assert!(s.contains("INVALID_METADATA_REQUEST"));
        assert!(!s.contains("SECRET_CANARY"));
        agentbar_core_free(p);
        agentbar_core_free(std::ptr::null_mut());
    }
}
#[test]
fn parser_state_checkpoint_roundtrip() {
    let raw =
        fs::read(root().join("Tests/Fixtures/Shared/codex-request.jsonl")).unwrap();
    let mut a = ParserState::default();
    let p = adapter("codex").unwrap();
    let c = ParseContext::fixture("codex", "fixture");
    for line in raw.split(|x| *x == 10).filter(|x| !x.is_empty()) {
        let expected = p.parse(line, &mut a, &c).unwrap();
        let mut b: ParserState = serde_json::from_str(&serde_json::to_string(&a).unwrap()).unwrap();
        assert_eq!(
            p.parse(line, &mut b, &c).unwrap().map(|e| e.id),
            expected.map(|e| e.id)
        );
    }
}
