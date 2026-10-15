use agentbar_core::{adapter::*, aggregation::*, domain::*, parser::*, storage::*};
use serde_json::{json, Value};
use std::{fs, path::PathBuf};
fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}
fn fixture(name: &str) -> Value {
    serde_json::from_slice(
        &fs::read(root().join("Tests/Fixtures/Contracts").join(name)).unwrap(),
    )
    .unwrap()
}
fn corpus() -> Vec<NormalizedUsageRecord> {
    serde_json::from_value(fixture("normalized-swift.json")).unwrap()
}
#[test]
fn expanded_swift_parser_golden_cases() {
    let inputs = fixture("reference-cases.json");
    let expected = fixture("reference-cases-swift.json");
    let mut actual = Vec::new();
    for case in inputs.as_array().unwrap() {
        let agent = case["agent"].as_str().unwrap();
        let parser = adapter(agent).unwrap();
        let ctx = ParseContext::fixture(agent, "fixture");
        let mut state = ParserState::default();
        let mut outputs = Vec::new();
        for line in case["lines"].as_array().unwrap() {
            let previous = state.clone();
            outputs.push(
                match parser.parse(line.to_string().as_bytes(), &mut state, &ctx) {
                    Ok(Some(e)) => e.golden(),
                    Ok(None) => Value::Null,
                    Err(_) => {
                        state = previous;
                        json!({"error":true})
                    }
                },
            );
        }
        actual.push(json!({"name":case["name"],"agent":agent,"outputs":outputs}));
    }
    assert_eq!(serde_json::to_value(actual).unwrap(), expected);
}
#[test]
fn sqlite_sql_matches_swift_and_pure_aggregation() {
    let rows = corpus();
    let expected = fixture("api-swift.json");
    let now = timestamp(expected["now"].as_str().unwrap()).unwrap();
    let mut store = Store::memory().unwrap();
    store.commit(&rows).unwrap();
    for range in ["today", "7", "30", "all"] {
        let filter = range_filter(range, now, "Asia/Shanghai").unwrap();
        let s = store.summary_sql(&filter, now).unwrap();
        assert_eq!(serde_json::to_value(&s).unwrap(), expected["ranges"][range]);
        assert_eq!(s, summarize(&rows, &filter, now).unwrap());
    }
    for filter in [
        QueryFilter {
            agent: Some("codex".into()),
            ..Default::default()
        },
        QueryFilter {
            model: Some("unknown".into()),
            ..Default::default()
        },
        QueryFilter {
            provider: Some("unknown".into()),
            ..Default::default()
        },
    ] {
        assert_eq!(
            store.summary_sql(&filter, now).unwrap(),
            summarize(&rows, &filter, now).unwrap()
        );
    }
}
#[test]
fn actual_authenticated_http_summary_and_models_match_core() {
    let expected = fixture("api-http-swift.json");
    let rows = corpus();
    let now = timestamp("2026-10-05T04:00:00Z").unwrap();
    assert_eq!(
        serde_json::to_value(summarize(&rows, &QueryFilter::default(), now).unwrap()).unwrap(),
        expected["/api/summary?range=all&tz=Asia%2FShanghai"]
    );
    assert_eq!(
        serde_json::to_value(groups(&rows, "models", &QueryFilter::default(), now).unwrap())
            .unwrap(),
        expected["/api/models?range=all&tz=Asia%2FShanghai"]
    );
    // Other response fixtures freeze transport DTOs for Phase4, not an implemented Rust HTTP service.
}
#[test]
fn real_file_wal_restart_and_locking() {
    let path =
        std::env::temp_dir().join(format!("agentbar-phase1-{}-wal.sqlite", std::process::id()));
    assert!(!path.exists());
    {
        let mut store = Store::open(&path).unwrap();
        let mode: String = store
            .db
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        let rows = corpus();
        store.commit(&rows).unwrap();
        let other = rusqlite::Connection::open(&path).unwrap();
        other
            .busy_timeout(std::time::Duration::from_millis(30))
            .unwrap();
        store.db.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(other.execute_batch("BEGIN IMMEDIATE").is_err());
        store.db.execute_batch("ROLLBACK").unwrap();
        other.execute_batch("BEGIN IMMEDIATE;ROLLBACK").unwrap();
    }
    {
        let mut store = Store::open(&path).unwrap();
        assert_eq!(store.events().unwrap().len(), 14);
        assert_eq!(store.commit(&corpus()).unwrap().duplicates, 14);
        assert_eq!(
            store
                .db
                .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
    }
    fs::remove_file(&path).unwrap(); // This test created exactly this disposable file.
}
#[test]
fn incremental_batch_waits_for_complete_line_and_roundtrips_checkpoint() {
    let bytes = fs::read(root().join("Tests/Fixtures/Shared/codex-100.jsonl")).unwrap();
    let parser = adapter("codex").unwrap();
    let mut ctx = ParseContext::fixture("codex", "fixture");
    let initial = Checkpoint::new(&parser);
    let cut = bytes.len() / 2;
    let first = parse_jsonl_batch(&parser, &bytes[..cut], &initial, &mut ctx).unwrap();
    assert!(first.incomplete_tail);
    let state: Checkpoint =
        serde_json::from_str(&serde_json::to_string(&first.checkpoint).unwrap()).unwrap();
    let rest =
        parse_jsonl_batch(&parser, &bytes[state.offset as usize..], &state, &mut ctx).unwrap();
    assert!(!rest.incomplete_tail);
    assert_eq!(rest.checkpoint.offset, bytes.len() as u64);
    assert_eq!(first.events.len() + rest.events.len(), 100);
    assert_eq!(initial.offset, 0);
}
#[test]
fn failing_batch_does_not_advance_checkpoint() {
    let parser = adapter("claude-code").unwrap();
    let initial = Checkpoint::new(&parser);
    let mut ctx = ParseContext::fixture("claude-code", "fixture");
    let bad=b"{\"type\":\"assistant\",\"message\":{\"id\":\"anonymous\",\"usage\":{\"input_tokens\":-1}}}\n";
    assert!(parse_jsonl_batch(&parser, bad, &initial, &mut ctx).is_err());
    assert_eq!(initial.offset, 0);
    assert!(initial.state.session.is_none());
}
#[test]
fn changed_parser_checkpoint_requires_explicit_reimport() {
    let p = adapter("codex").unwrap();
    let mut checkpoint = Checkpoint::new(&p);
    checkpoint.parser_version = "old-parser".into();
    let mut c = ParseContext::fixture("codex", "fixture");
    assert!(parse_jsonl_batch(&p, b"\n", &checkpoint, &mut c).is_err());
}
#[test]
fn path_metadata_improvement_requires_platform_evidence() {
    let mut store = Store::memory().unwrap();
    let mut e = corpus()
        .into_iter()
        .find(|e| e.agent_id == "codex")
        .unwrap();
    store.commit(&[e.clone()]).unwrap();
    let original = e.source_path.clone();
    e.source_path = "fixture/renamed".into();
    assert_eq!(store.commit(&[e.clone()]).unwrap().duplicates, 1);
    let context = CommitContext {
        missing_source_paths: std::collections::BTreeSet::from([original]),
        ..Default::default()
    };
    assert_eq!(
        store.commit_with_context(&[e], &context).unwrap().updated,
        1
    );
}
#[test]
fn aggregate_preserves_int64_above_javascript_safe_limit() {
    let mut rows = corpus()[..2].to_vec();
    for e in &mut rows {
        e.metrics
            .insert("total".into(), Metric::new(Some(TOKEN_LIMIT)));
    }
    let now = timestamp("2026-10-05T04:00:00Z").unwrap();
    let mut store = Store::memory().unwrap();
    store.commit(&rows).unwrap();
    assert_eq!(
        store
            .summary_sql(&QueryFilter::default(), now)
            .unwrap()
            .metrics["total"]
            .value,
        Some(2 * TOKEN_LIMIT)
    );
    assert_eq!(
        summarize(&rows, &QueryFilter::default(), now)
            .unwrap()
            .metrics["total"]
            .value,
        Some(2 * TOKEN_LIMIT)
    );
}
#[test]
fn integer_overflow_is_explicit_not_saturated() {
    assert!(checked_sum(&[Some(i64::MAX), Some(1)]).is_err());
}
#[test]
fn mixed_currencies_and_unpriced_metadata_match_sql() {
    let mut rows = corpus()[..2].to_vec();
    rows[0].cost = Some(1.);
    rows[0].currency = Some("USD".into());
    rows[1].cost = Some(2.);
    rows[1].currency = Some("EUR".into());
    let now = timestamp("2026-10-05T04:00:00Z").unwrap();
    let mut store = Store::memory().unwrap();
    store.commit(&rows).unwrap();
    let pure = summarize(&rows, &QueryFilter::default(), now).unwrap();
    assert_eq!(pure.cost, None);
    assert_eq!(
        pure,
        store.summary_sql(&QueryFilter::default(), now).unwrap()
    );
}
#[test]
fn group_order_is_independent_of_input_iteration() {
    let rows = corpus();
    let mut reversed = rows.clone();
    reversed.reverse();
    let now = timestamp("2026-10-05T04:00:00Z").unwrap();
    for d in ["agents", "models"] {
        assert_eq!(
            groups(&rows, d, &QueryFilter::default(), now).unwrap(),
            groups(&reversed, d, &QueryFilter::default(), now).unwrap()
        );
    }
}
#[test]
fn swift_calendar_time_ranges_golden() {
    for case in fixture("time-cases-swift.json").as_array().unwrap() {
        let now = timestamp(case["now"].as_str().unwrap()).unwrap();
        let tz = case["timeZone"].as_str().unwrap();
        for range in ["today", "7", "30", "yesterday"] {
            let filter = range_filter(range, now, tz).unwrap();
            let expected = &case["ranges"][range];
            assert_eq!(
                filter.start.unwrap(),
                timestamp(expected["start"].as_str().unwrap())
                    .unwrap()
                    .timestamp() as f64,
                "{} {range} start",
                case["name"]
            );
            assert_eq!(
                filter.end.unwrap(),
                timestamp(expected["end"].as_str().unwrap())
                    .unwrap()
                    .timestamp() as f64,
                "{} {range} end",
                case["name"]
            );
        }
    }
}
#[test]
fn differentiated_date_window_golden_and_sql() {
    let rows: Vec<NormalizedUsageRecord> =
        serde_json::from_value(fixture("date-normalized-swift.json")).unwrap();
    let expected = fixture("date-api-swift.json");
    let now = timestamp(expected["now"].as_str().unwrap()).unwrap();
    let mut store = Store::memory().unwrap();
    store.commit(&rows).unwrap();
    for range in ["today", "7", "30", "all"] {
        let f = range_filter(range, now, "Asia/Shanghai").unwrap();
        assert_eq!(
            serde_json::to_value(summarize(&rows, &f, now).unwrap()).unwrap(),
            expected["ranges"][range]
        );
        assert_eq!(
            serde_json::to_value(store.summary_sql(&f, now).unwrap()).unwrap(),
            expected["ranges"][range]
        );
    }
    let raw =
        fs::read(root().join("Tests/Fixtures/Contracts/date-boundaries-codex.jsonl"))
            .unwrap();
    let parser = adapter("codex").unwrap();
    let initial = Checkpoint::new(&parser);
    let mut c = ParseContext::fixture("codex", "fixture");
    let actual = parse_jsonl_batch(&parser, &raw, &initial, &mut c).unwrap();
    assert_eq!(
        actual.events.iter().map(|e| e.golden()).collect::<Vec<_>>(),
        rows.iter().map(|e| e.golden()).collect::<Vec<_>>()
    );
}
#[test]
fn restored_retained_codex_alias_does_not_double_count() {
    let mut new = corpus()
        .into_iter()
        .find(|e| e.agent_id == "codex")
        .unwrap();
    let response = new.source_metadata["response_id"].clone();
    let mut old = new.clone();
    old.source_event_id = format!("codex:response:{response}");
    old.id = hash(&old.source_event_id);
    old.fingerprint = old.id.clone();
    old.source_metadata.insert(
        "coverage_notes".into(),
        "Previously collected source is no longer present; retained metadata is not reverified"
            .into(),
    );
    let mut store = Store::memory().unwrap();
    store.commit(&[old]).unwrap();
    new.source_path = "fixture/restored".into();
    store.commit(&[new]).unwrap();
    assert_eq!(store.events().unwrap().len(), 1);
    assert_eq!(
        store
            .db
            .query_row("SELECT count(*) FROM superseded_usage_events", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
}
