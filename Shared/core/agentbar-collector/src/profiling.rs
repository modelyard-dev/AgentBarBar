//! Anonymous benchmark-only SQL timing. Never retains SQL or bound values.
use std::{collections::BTreeMap, sync::{Mutex, OnceLock}, time::Duration};
use serde::Serialize;
#[derive(Default, Serialize)]
struct Counter { calls: u64, sqlite_nanoseconds: u128 }
static COUNTERS: OnceLock<Mutex<BTreeMap<&'static str, Counter>>> = OnceLock::new();
fn bucket(sql: &str) -> &'static str {
    if sql.starts_with("COMMIT") { "commit" }
    else if sql.starts_with("BEGIN") { "begin" }
    else if sql.starts_with("INSERT INTO usage_events") { "usage_insert_and_indexes" }
    else if sql.starts_with("SELECT event_json FROM usage_events") { "dedup_lookup" }
    else if sql.contains("ingest_checkpoints") || sql.contains("source_checkpoints") { "checkpoint" }
    else if sql.starts_with("INSERT") { "dimension_insert" }
    else { "other" }
}
fn capture(sql: &str, elapsed: Duration) {
    let mut counters = COUNTERS.get_or_init(Default::default).lock().unwrap();
    let value = counters.entry(bucket(sql)).or_default();
    value.calls += 1; value.sqlite_nanoseconds += elapsed.as_nanos();
}
pub fn start(db: &mut rusqlite::Connection) {
    COUNTERS.get_or_init(Default::default).lock().unwrap().clear();
    db.profile(Some(capture));
}
pub fn finish(db: &mut rusqlite::Connection) -> serde_json::Value {
    db.profile(None);
    serde_json::json!({"resolution":"SQLite PROFILE millisecond resolution; zeros are sub-ms, not free",
        "sqlOrParametersSaved":false,"buckets":&*COUNTERS.get_or_init(Default::default).lock().unwrap()})
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn classifier_does_not_return_or_persist_parameters() {
        assert_eq!(bucket("INSERT INTO usage_events VALUES('private sentinel')"),"usage_insert_and_indexes");
        assert_eq!(bucket("SELECT event_json FROM usage_events WHERE source_event_id='private sentinel'"),"dedup_lookup");
        assert_eq!(bucket("COMMIT"),"commit");
        let mut db=rusqlite::Connection::open_in_memory().unwrap(); start(&mut db);
        db.execute_batch("CREATE TABLE fixture(v TEXT); INSERT INTO fixture VALUES ('private sentinel');").unwrap();
        let result=finish(&mut db).to_string(); assert!(!result.contains("private sentinel")); assert!(!result.contains("VALUES"));
    }
}
