//! Isolated Phase1 statistics store; never opens third-party Agent databases.
use crate::{
    aggregation::{MetricAggregate, QueryFilter, UsageSummary},
    domain::*,
    Result,
};
use chrono::{DateTime, Utc};
use rusqlite::{params, params_from_iter, types::Value, Connection};
use serde::Serialize;
use std::{path::Path, time::Duration};
pub const SCHEMA_VERSION: u32 = 7;
pub const MIGRATIONS: [&str; 7] = [
    include_str!("../../../migrations/001.sql"),
    include_str!("../../../migrations/002.sql"),
    include_str!("../../../migrations/003.sql"),
    include_str!("../../../migrations/004.sql"),
    include_str!("../../../migrations/005.sql"),
    include_str!("../../../migrations/006.sql"),
    include_str!("../../../migrations/007.sql"),
];
pub fn migrate(db: &mut Connection) -> Result<()> {
    let version: u32 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > 7 {
        return Err("Database schema is newer than this core".into());
    }
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    for sql in &MIGRATIONS[version as usize..] {
        tx.execute_batch(sql)?;
    }
    tx.commit()?;
    Ok(())
}
#[derive(Default, Debug, Serialize)]
pub struct CommitResult {
    pub inserted: usize,
    pub updated: usize,
    pub duplicates: usize,
}
pub struct Store {
    pub db: Connection,
}
#[derive(Default)]
pub struct CommitContext {
    /// Verified by the platform host; Core never probes arbitrary source paths.
    pub missing_source_paths: std::collections::BTreeSet<String>,
    /// Atomically adopt a verified canonical snapshot (including downward corrections).
    pub authoritative_agent: Option<String>,
}
impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let mut db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch(
            "PRAGMA foreign_keys=ON;PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;",
        )?;
        migrate(&mut db)?;
        Ok(Self { db })
    }
    pub fn memory() -> Result<Self> {
        let mut db = Connection::open_in_memory()?;
        db.execute_batch("PRAGMA foreign_keys=ON;")?;
        migrate(&mut db)?;
        Ok(Self { db })
    }
    pub fn events(&self) -> Result<Vec<NormalizedUsageRecord>> {
        let mut stmt = self
            .db
            .prepare("SELECT event_json FROM usage_events ORDER BY source_event_id")?;
        let raw = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        raw.into_iter()
            .map(|s| Ok(serde_json::from_str(&s)?))
            .collect()
    }
    pub fn commit(&mut self, events: &[NormalizedUsageRecord]) -> Result<CommitResult> {
        self.commit_with_context(events, &CommitContext::default())
    }
    pub fn commit_with_context(
        &mut self,
        events: &[NormalizedUsageRecord],
        context: &CommitContext,
    ) -> Result<CommitResult> {
        self.commit_atomic(events, context, |_| Ok(()))
    }
    /// Commit event rows and caller-owned ingest metadata in the SAME SQLite transaction.
    /// Statistical Core knows neither file handles nor the platform checkpoint format.
    pub fn commit_atomic<F>(
        &mut self,
        events: &[NormalizedUsageRecord],
        context: &CommitContext,
        metadata: F,
    ) -> Result<CommitResult>
    where
        F: FnOnce(&rusqlite::Transaction<'_>) -> Result<()>,
    {
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut result = CommitResult::default();
        if let Some(agent) = &context.authoritative_agent {
            if events.iter().any(|e| &e.agent_id != agent) {
                return Err("AUTHORITATIVE_AGENT_MISMATCH".into());
            }
            tx.execute(
                "INSERT INTO superseded_usage_events SELECT *,? FROM usage_events WHERE agent_id=?",
                params![crate::domain::iso(Utc::now()), agent],
            )?;
            tx.execute("DELETE FROM usage_events WHERE agent_id=?", [agent])?;
        }
        for e in events {
            #[cfg(feature = "profiling")]
            let validation = crate::profiling::span("validate");
            e.validate()?;
            #[cfg(feature = "profiling")]
            drop(validation);
            // Mirror Swift's retained legacy-response adoption after a restored rollout.
            #[cfg(feature = "profiling")]
            let lookup = crate::profiling::span("dedup_lookup_including_prepare");
            if e.agent_id == "codex" {
                if let Some(response) = e.source_metadata.get("response_id") {
                    let legacy = format!("codex:response:{response}");
                    let encoded: Option<String> = tx
                        .query_row(
                            "SELECT event_json FROM usage_events WHERE source_event_id=?",
                            [&legacy],
                            |r| r.get(0),
                        )
                        .optional()?;
                    if let Some(encoded) = encoded {
                        let old: NormalizedUsageRecord = serde_json::from_str(&encoded)?;
                        if old.session_id == e.session_id
                            && old
                                .source_metadata
                                .get("coverage_notes")
                                .is_some_and(|s| s.contains("no longer present"))
                        {
                            tx.execute("INSERT INTO superseded_usage_events SELECT *,? FROM usage_events WHERE source_event_id=?", params![e.created_at,legacy])?;
                            tx.execute(
                                "DELETE FROM usage_events WHERE source_event_id=?",
                                [legacy],
                            )?;
                        }
                    }
                }
            }
            let old: Option<String> = tx
                .query_row(
                    "SELECT event_json FROM usage_events WHERE source_event_id=? OR fingerprint=?",
                    params![e.source_event_id, e.fingerprint],
                    |r| r.get(0),
                )
                .optional()?;
            #[cfg(feature = "profiling")]
            drop(lookup);
            if let Some(old) = &old {
                let old: NormalizedUsageRecord = serde_json::from_str(old)?;
                let previous = old.metrics["total"].value;
                let incoming = e.metrics["total"].value;
                let better = incoming.is_some_and(|n| n > previous.unwrap_or(-1));
                let improved = METRICS
                    .iter()
                    .any(|k| old.metrics[*k].value.is_none() && e.metrics[*k].value.is_some());
                let metadata = (old.raw_model_name.is_none() && e.raw_model_name.is_some())
                    || (old.provider.is_none() && e.provider.is_some())
                    || (old.project.is_none() && e.project.is_some())
                    || old.parser_version != e.parser_version
                    || (old.source_path != e.source_path
                        && context.missing_source_paths.contains(&old.source_path));
                let snapshot = matches!(e.agent_id.as_str(), "gemini" | "cline" | "qwen");
                let stale_json = e.agent_id == "gemini" && old.source_type == "local_session_jsonl" && e.source_type == "local_session_json";
                if stale_json || (!snapshot && ((!better && !improved && !metadata)
                    || matches!((previous,incoming),(Some(a),Some(b)) if b<a))) || (snapshot && old.metrics == e.metrics && old.parser_version == e.parser_version && old.source_path == e.source_path && old.source_line == e.source_line && old.source_offset == e.source_offset && old.source_metadata == e.source_metadata && old.raw_model_name == e.raw_model_name && old.provider == e.provider && old.timestamp == e.timestamp && old.project == e.project)
                {
                    result.duplicates += 1;
                    continue;
                }
            }
            #[cfg(feature = "profiling")]
            let dimensions = crate::profiling::span("dimensions_including_prepare");
            tx.execute(
                "INSERT OR IGNORE INTO agents VALUES(?,?,?)",
                params![
                    e.agent_id,
                    e.agent_name,
                    "{\"installed\":true,\"evidence\":[\"usage_source\"],\"sourceAvailable\":true}"
                ],
            )?;
            if let Some(m) = &e.raw_model_name {
                tx.execute("INSERT OR IGNORE INTO models VALUES(?,?)", params![m, m])?;
            }
            if let Some(p) = &e.project {
                tx.execute("INSERT INTO projects VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,path=excluded.path,detection_method=excluded.detection_method,confidence=excluded.confidence",params![p.id,p.name,p.path,p.detection_method,p.confidence])?;
            }
            if let Some(s) = &e.session_id {
                tx.execute(
                    "INSERT OR IGNORE INTO sessions VALUES(?,?,?)",
                    params![format!("{}:{s}", e.agent_id), s, e.agent_id],
                )?;
            }
            #[cfg(feature = "profiling")]
            drop(dimensions);
            #[cfg(feature = "profiling")]
            let encoding = crate::profiling::span("row_encoding_and_sql_construction");
            let text = |s: &str| Value::Text(s.into());
            let opt = |s: Option<&str>| s.map(text).unwrap_or(Value::Null);
            let num = |n: Option<i64>| n.map(Value::Integer).unwrap_or(Value::Null);
            let mut values = vec![
                text(&e.id),
                Value::Real(timestamp(&e.timestamp)?.timestamp_millis() as f64 / 1000.),
                text(&e.agent_id),
                opt(e.raw_model_name.as_deref()),
                opt(e.provider.as_deref()),
                opt(e.session_id.as_deref()),
                opt(e.project.as_ref().map(|p| p.id.as_str())),
            ];
            for k in METRICS {
                values.push(num(e.metrics[k].value));
            }
            values.extend([
                e.cost.map(Value::Real).unwrap_or(Value::Null),
                opt(e.currency.as_deref()),
                Value::Integer(i64::from(e.is_estimated)),
                text(&e.source_event_id),
                text(&e.fingerprint),
                text(&e.source_path),
                text(&e.collector_id),
                text(&serde_json::to_string(e)?),
                text(&e.created_at),
            ]);
            for k in METRICS {
                values.push(text(
                    serde_json::to_value(e.metrics[k].state)?
                        .as_str()
                        .ok_or("State encoding")?,
                ));
            }
            // Source_file copy/rename policy and authoritative-ledger replacement are platform/Phase4 gates.
            let columns = [
                "timestamp",
                "model",
                "provider",
                "session_id",
                "project_id",
                "source_path",
                "input_tokens",
                "output_tokens",
                "cached_input_tokens",
                "cache_write_tokens",
                "cached_output_tokens",
                "reasoning_tokens",
                "total_tokens",
                "cost",
                "currency",
                "event_json",
                "input_state",
                "output_state",
                "cacheRead_state",
                "cacheWrite_state",
                "cachedOutput_state",
                "reasoning_state",
                "total_state",
            ];
            let sql = format!(
                "INSERT INTO usage_events VALUES({}) ON CONFLICT(source_event_id) DO UPDATE SET {}",
                vec!["?"; 30].join(","),
                columns
                    .iter()
                    .map(|c| format!("{c}=excluded.{c}"))
                    .collect::<Vec<_>>()
                    .join(",")
            );
            #[cfg(feature = "profiling")]
            {
                drop(encoding);
                let prepare = crate::profiling::span("usage_insert_prepare");
                if crate::profiling::reuse() {
                    let mut statement = tx.prepare_cached(&sql)?;
                    drop(prepare);
                    let execution = crate::profiling::span("usage_bind_execute_indexes");
                    statement.execute(params_from_iter(values))?;
                    drop(execution);
                } else {
                    let mut statement = tx.prepare(&sql)?;
                    drop(prepare);
                    let execution = crate::profiling::span("usage_bind_execute_indexes");
                    statement.execute(params_from_iter(values))?;
                    drop(execution);
                }
            }
            #[cfg(not(feature = "profiling"))]
            tx.prepare_cached(&sql)?.execute(params_from_iter(values))?;
            if old.is_some() {
                result.updated += 1
            } else {
                result.inserted += 1
            }
        }
        #[cfg(feature = "profiling")]
        let checkpoint = crate::profiling::span("checkpoint_sql");
        metadata(&tx)?;
        #[cfg(feature = "profiling")]
        drop(checkpoint);
        #[cfg(feature = "profiling")]
        let commit = crate::profiling::span("commit");
        tx.commit()?;
        #[cfg(feature = "profiling")]
        drop(commit);
        Ok(result)
    }

    /// Actual SQL aggregation, matching Swift EventStore.summary on isolated schema-v7 stores.
    pub fn summary_sql(&self, filter: &QueryFilter, now: DateTime<Utc>) -> Result<UsageSummary> {
        let columns = [
            "input_tokens",
            "output_tokens",
            "cached_input_tokens",
            "cache_write_tokens",
            "cached_output_tokens",
            "reasoning_tokens",
            "total_tokens",
        ];
        let mut clauses = vec!["1=1".to_string()];
        let mut args = Vec::<Value>::new();
        for (op, bound) in [(">=", filter.start), ("<", filter.end)] {
            if let Some(n) = bound {
                if !n.is_finite() {
                    return Err("Invalid time bound".into());
                }
                clauses.push(format!("timestamp{op}?"));
                args.push(Value::Real(n));
            }
        }
        for (column, value) in [
            ("agent_id", &filter.agent),
            ("model", &filter.model),
            ("project_id", &filter.project),
            ("provider", &filter.provider),
            ("session_id", &filter.session),
        ] {
            if let Some(v) = value {
                clauses.push(if v == "unknown" {
                    format!("({column} IS NULL OR {column}=?)")
                } else {
                    format!("{column}=?")
                });
                args.push(Value::Text(v.clone()));
            }
        }
        let where_sql = clauses.join(" AND ");
        let metrics_sql = columns.iter().zip(METRICS).map(|(col,key)|format!("SUM({col}),COUNT({col}),SUM(CASE WHEN {key}_state='unsupported' THEN 1 ELSE 0 END),SUM(CASE WHEN {key}_state='unknown' THEN 1 ELSE 0 END),SUM(CASE WHEN {key}_state='partial' THEN 1 ELSE 0 END)")).collect::<Vec<_>>().join(",");
        let sql = format!("SELECT count(*),count(DISTINCT agent_id||':'||session_id),count(DISTINCT agent_id),count(DISTINCT project_id),COALESCE(sum(is_estimated),0),sum(cost),count(cost),max(currency),count(DISTINCT CASE WHEN timestamp>={} THEN agent_id END),{metrics_sql},SUM(CASE WHEN agent_id='deepseek-harness' AND source_event_id LIKE 'deepseek-harness:ledger:%' THEN input_tokens-cached_input_tokens-cache_write_tokens END),COUNT(CASE WHEN agent_id='deepseek-harness' AND source_event_id LIKE 'deepseek-harness:ledger:%' THEN input_tokens-cached_input_tokens-cache_write_tokens END) FROM usage_events WHERE {where_sql}", now.timestamp_millis() as f64/1000. - 900.);
        let mut summary = self
            .db
            .query_row(&sql, params_from_iter(args.iter()), |row| {
                let n: usize = row.get(0)?;
                let mut metrics = std::collections::BTreeMap::new();
                for (i, key) in METRICS.iter().enumerate() {
                    let base = 9 + i * 5;
                    let known: usize = row.get(base + 1)?;
                    let unsupported = row.get::<_, Option<usize>>(base + 2)?.unwrap_or(0);
                    let unknown = row.get::<_, Option<usize>>(base + 3)?.unwrap_or(0);
                    let state = if known > 0 {
                        if known < n || row.get::<_, Option<usize>>(base + 4)?.unwrap_or(0) > 0 {
                            MetricState::Partial
                        } else {
                            MetricState::Known
                        }
                    } else if n > 0 && unsupported == n {
                        MetricState::Unsupported
                    } else if n > 0 && unknown == n {
                        MetricState::Unknown
                    } else {
                        MetricState::NotAvailable
                    };
                    metrics.insert(
                        key.to_string(),
                        MetricAggregate {
                            value: row.get(base)?,
                            state,
                            known_events: known,
                            total_events: n,
                        },
                    );
                }
                let raw_count: usize = row.get(45)?;
                Ok(UsageSummary {
                    metrics,
                    events: n,
                    sessions: row.get(1)?,
                    agents: row.get(2)?,
                    projects: row.get(3)?,
                    estimated_events: row.get(4)?,
                    cost: row.get(5)?,
                    cost_known_events: row.get(6)?,
                    currency: row.get(7)?,
                    active_agents: row.get(8)?,
                    uncached_input: if raw_count > 0 {
                        Some(MetricAggregate {
                            value: row.get(44)?,
                            state: if raw_count == n {
                                MetricState::Known
                            } else {
                                MetricState::Partial
                            },
                            known_events: raw_count,
                            total_events: n,
                        })
                    } else {
                        None
                    },
                })
            })?;
        if summary.cost_known_events > 0 {
            let (currencies, absent):(usize,usize)=self.db.query_row(&format!("SELECT count(DISTINCT currency),sum(CASE WHEN currency IS NULL THEN 1 ELSE 0 END) FROM usage_events WHERE {where_sql} AND cost IS NOT NULL"),params_from_iter(args.iter()),|r|Ok((r.get(0)?,r.get(1)?)))?;
            if currencies != 1 || absent > 0 {
                summary.cost = None;
                summary.currency = None;
                summary.cost_known_events = 0;
            }
        }
        Ok(summary)
    }
}
use rusqlite::OptionalExtension;
