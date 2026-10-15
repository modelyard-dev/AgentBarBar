use crate::{
    io,
    locator::{Confidence, SourceDescriptor},
};
use agentbar_core::{
    domain::{hash, iso},
    parser::{adapter, ParseContext, ParserState, UsageAdapter},
    storage::{CommitContext, Store},
    Result,
};
use chrono::Utc;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};
const CHECKPOINT_VERSION: u32 = 1;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceCheckpoint {
    pub version: u32,
    pub source_id: String,
    pub agent: String,
    pub path: std::path::PathBuf,
    pub identity: io::FileIdentity,
    pub offset: u64,
    pub line: u64,
    pub last_seen_size: u64,
    pub last_seen_modified: u64,
    pub parser_version: String,
    pub source_schema_version: String,
    pub state: ParserState,
    pub boundary_hash: String,
    pub head_hash: String,
    pub head_len: u64,
    pub verified_usage: bool,
    #[serde(default)]
    pub pending_import: bool,
    pub error: Option<String>,
    pub saved_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Envelope {
    checksum: String,
    checkpoint: SourceCheckpoint,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CollectorState {
    Unavailable,
    Discovered,
    Importing,
    Watching,
    Idle,
    Degraded,
    Error,
    RecoveryRequired,
    Cancelled,
}
#[derive(Default, Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub sources: usize,
    pub bytes_read: u64,
    pub bytes_incremental: u64,
    pub bytes_boundary: u64,
    pub records_parsed: u64,
    pub records_normalized: u64,
    pub records_inserted: u64,
    pub records_updated: u64,
    pub duplicates: u64,
    pub ignored: u64,
    pub unknown: u64,
    pub malformed: u64,
    pub commits: u64,
    pub max_batch_events: usize,
    pub max_line_bytes: usize,
    pub elapsed_ms: u64,
    pub sqlite_ms: u64,
    pub unchanged_files: usize,
    pub resets: usize,
    pub partial_tails: usize,
}
impl Metrics {
    pub fn add(&mut self, m: &Self) {
        self.sources += m.sources;
        self.bytes_read += m.bytes_read;
        self.bytes_incremental += m.bytes_incremental;
        self.bytes_boundary += m.bytes_boundary;
        self.records_parsed += m.records_parsed;
        self.records_normalized += m.records_normalized;
        self.records_inserted += m.records_inserted;
        self.records_updated += m.records_updated;
        self.duplicates += m.duplicates;
        self.ignored += m.ignored;
        self.unknown += m.unknown;
        self.malformed += m.malformed;
        self.commits += m.commits;
        self.max_batch_events = self.max_batch_events.max(m.max_batch_events);
        self.max_line_bytes = self.max_line_bytes.max(m.max_line_bytes);
        self.elapsed_ms += m.elapsed_ms;
        self.sqlite_ms += m.sqlite_ms;
        self.unchanged_files += m.unchanged_files;
        self.resets += m.resets;
        self.partial_tails += m.partial_tails;
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceResult {
    pub source_id: String,
    pub agent: String,
    pub state: CollectorState,
    pub confidence: Confidence,
    pub metrics: Metrics,
    pub diagnostics: Vec<String>,
    pub schema_fingerprints: BTreeMap<String, u64>,
    pub checkpoint_age_seconds: Option<i64>,
    pub token_field_known_records: BTreeMap<String, u64>,
    pub earliest_timestamp: Option<String>,
    pub latest_timestamp: Option<String>,
}
#[derive(Clone)]
pub struct Options {
    pub batch_events: usize,
    pub batch_lines: usize,
    pub max_line_bytes: usize,
    pub fault: Option<String>,
    pub force_reconcile: bool,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            batch_events: 200,
            batch_lines: 1000,
            max_line_bytes: 64 * 1024 * 1024,
            fault: None,
            force_reconcile: false,
        }
    }
}
pub fn initialize(store: &Store) -> Result<()> {
    store.db.execute_batch("PRAGMA cache_size=-4096;PRAGMA mmap_size=0;CREATE TABLE IF NOT EXISTS agentbar_ingest_meta(id INTEGER PRIMARY KEY,version INTEGER NOT NULL);INSERT OR IGNORE INTO agentbar_ingest_meta VALUES(1,1);CREATE TABLE IF NOT EXISTS agentbar_source_checkpoints(source_id TEXT PRIMARY KEY,agent_id TEXT NOT NULL,path TEXT NOT NULL,envelope_json TEXT NOT NULL);CREATE INDEX IF NOT EXISTS agentbar_checkpoint_agent ON agentbar_source_checkpoints(agent_id);")?;
    let v: i64 = store.db.query_row(
        "SELECT version FROM agentbar_ingest_meta WHERE id=1",
        [],
        |r| r.get(0),
    )?;
    if v != 1 {
        return Err("INGEST_SCHEMA_VERSION_UNSUPPORTED".into());
    }
    Ok(())
}
pub fn load(store: &Store, source: &str) -> Result<Option<SourceCheckpoint>> {
    let raw: Option<String> = store
        .db
        .query_row(
            "SELECT envelope_json FROM agentbar_source_checkpoints WHERE source_id=?",
            [source],
            |r| r.get(0),
        )
        .optional()?;
    let Some(raw) = raw else { return Ok(None) };
    let envelope: Envelope = serde_json::from_str(&raw).map_err(|_| "CHECKPOINT_CORRUPT")?;
    let body = serde_json::to_string(&envelope.checkpoint)?;
    if hash(&body) != envelope.checksum {
        return Err("CHECKPOINT_CHECKSUM_MISMATCH".into());
    }
    Ok(Some(envelope.checkpoint))
}
pub fn status(store: &Store) -> Result<serde_json::Value> {
    let mut stmt=store.db.prepare("SELECT agent_id,COUNT(*),SUM(json_extract(envelope_json,'$.checkpoint.offset')),MAX(json_extract(envelope_json,'$.checkpoint.savedAt')) FROM agentbar_source_checkpoints GROUP BY agent_id ORDER BY agent_id")?;
    let rows=stmt.query_map([],|r|Ok(serde_json::json!({"agent":r.get::<_,String>(0)?,"sources":r.get::<_,i64>(1)?,"committedBytes":r.get::<_,Option<i64>>(2)?,"lastCheckpoint":r.get::<_,Option<String>>(3)?})))?.collect::<std::result::Result<Vec<_>,_>>()?;
    Ok(serde_json::json!({"checkpointVersion":1,"sources":rows}))
}
fn fault(options: &Options, point: &str) {
    if options.fault.as_deref() == Some(point) {
        std::process::exit(86)
    }
}
pub(crate) fn save_batch(
    store: &mut Store,
    events: &[agentbar_core::domain::NormalizedUsageRecord],
    checkpoint: &mut SourceCheckpoint,
    metrics: &mut Metrics,
    options: &Options,
) -> Result<()> {
    fault(options, "after-parse");
    let begin = Instant::now();
    checkpoint.saved_at = iso(Utc::now());
    let body = serde_json::to_string(checkpoint)?;
    let payload = serde_json::to_string(&Envelope {
        checksum: hash(&body),
        checkpoint: checkpoint.clone(),
    })?;
    let mut context = CommitContext::default();
    for e in events {
        if e.source_path != checkpoint.path.to_string_lossy() {
            context.missing_source_paths.insert(e.source_path.clone());
        }
    }
    let result=store.commit_atomic(events,&context,|tx|{fault(options,"before-checkpoint");tx.execute("INSERT INTO agentbar_source_checkpoints VALUES(?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET agent_id=excluded.agent_id,path=excluded.path,envelope_json=excluded.envelope_json",params![checkpoint.source_id,checkpoint.agent,checkpoint.path.to_string_lossy(),payload])?;fault(options,"during-checkpoint");Ok(())})?;
    fault(options, "after-commit");
    metrics.sqlite_ms += begin.elapsed().as_millis() as u64;
    metrics.records_inserted += result.inserted as u64;
    metrics.records_updated += result.updated as u64;
    metrics.duplicates += result.duplicates as u64;
    metrics.commits += 1;
    metrics.max_batch_events = metrics.max_batch_events.max(events.len());
    Ok(())
}
fn fragment(file: &mut std::fs::File, start: u64, len: u64) -> Result<String> {
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = vec![0; len as usize];
    file.read_exact(&mut bytes)?;
    Ok(hash(&format!("{:?}", bytes)))
}
#[derive(Deserialize)]
struct Shape {
    payload: Option<Payload>,
    message: Option<Message>,
}
#[derive(Deserialize)]
struct Payload {
    #[serde(rename = "type")]
    kind: Option<String>,
}
#[derive(Deserialize)]
struct Message {
    #[serde(rename = "type")]
    kind: Option<String>,
}
#[derive(PartialEq)]
enum Class {
    Known,
    Ignored,
    Unknown,
    Malformed,
}
fn classify(agent: &str, raw: &[u8]) -> (Class, String) {
    #[derive(Deserialize)]
    struct Top {
        #[serde(rename = "type")]
        kind: Option<String>,
    }
    let top: Top = match serde_json::from_slice(raw) {
        Ok(v) => v,
        Err(_) => return (Class::Malformed, hash("invalid_json")),
    };
    let typ = top.kind.as_deref().unwrap_or("");
    if agent == "qwen" {
        // Schema and counter validation belongs to the versioned ledger parser.
        return (Class::Known, hash("qwen-monthly-ledger-schema1"));
    }
    if agent == "pi" {
        return (
            if [
                "session",
                "model_change",
                "message",
                "usage",
                "compaction",
                "branch_summary",
            ]
            .contains(&typ)
            {
                Class::Known
            } else if [
                "thinking_level_change",
                "custom",
                "custom_message",
                "label",
                "session_info",
            ]
            .contains(&typ)
            {
                Class::Ignored
            } else {
                Class::Unknown
            },
            hash(&format!("pi:{typ}")),
        );
    }
    if agent == "workbuddy" {
        return (
            if ["message", "function_call"].contains(&typ) {
                Class::Known
            } else {
                Class::Ignored
            },
            hash(&format!("workbuddy:{typ}")),
        );
    }
    if agent == "claude-code"
        && ["user", "system"].contains(&typ)
        && raw.windows(b"\"entrypoint\"".len()).any(|w| w == b"\"entrypoint\"")
    {
        // The versioned Claude parser reads only the top-level entrypoint field from this envelope.
        // It returns no usage event and never retains the user content.
        return (Class::Known, hash("claude-code:user-entrypoint-metadata"));
    }
    let ignored_top = match agent {
        "codex" => ["response_item", "compacted", "world_state"].contains(&typ),
        "claude-code" => [
            "user",
            "system",
            "progress",
            "summary",
            "file-history-snapshot",
            "queue-operation",
            "custom-title",
            "last-prompt",
            "agent-name",
            "agent-color",
            "pr-link",
            "mode",
            "permission-mode",
            "attachment",
            "ai-title",
        ]
        .contains(&typ),
        _ => false,
    };
    if ignored_top {
        return (Class::Ignored, hash(&format!("{agent}:{typ}:ignored")));
    }
    if (agent == "codex" && ["session_meta", "turn_context", "token_usage_record"].contains(&typ))
        || (agent == "claude-code" && typ == "assistant")
        || (agent == "kimi-cli" && typ == "metadata")
    {
        return (Class::Known, hash(&format!("{agent}:{typ}:metadata")));
    }
    let shape: Shape = match serde_json::from_slice(raw) {
        Ok(v) => v,
        Err(_) => return (Class::Malformed, hash("invalid_envelope")),
    };
    let sub = shape
        .payload
        .as_ref()
        .and_then(|p| p.kind.as_deref())
        .unwrap_or("");
    let msg = shape
        .message
        .as_ref()
        .and_then(|m| m.kind.as_deref())
        .unwrap_or("");
    let known = (agent == "codex"
        && typ == "event_msg"
        && ["token_count", "thread_settings_applied"].contains(&sub))
        || (agent == "kimi-cli" && msg == "StatusUpdate");
    let ignored = (agent == "codex"
        && typ == "event_msg"
        && [
            "task_started",
            "item_completed",
            "task_complete",
            "turn_aborted",
            "thread_goal_updated",
        ]
        .contains(&sub))
        || (agent == "kimi-cli"
            && [
                "TurnBegin",
                "StepBegin",
                "ContentPart",
                "ToolCall",
                "ApprovalRequest",
                "ToolCallPart",
                "ApprovalResponse",
                "ToolResult",
                "TurnEnd",
                "StepInterrupted",
            ]
            .contains(&msg));
    let fp = hash(&format!("{agent}:{typ}:{sub}:{msg}"));
    (
        if known {
            Class::Known
        } else if ignored {
            Class::Ignored
        } else {
            Class::Unknown
        },
        fp,
    )
}

pub(crate) fn base(source: &SourceDescriptor) -> SourceCheckpoint {
    SourceCheckpoint {
        version: CHECKPOINT_VERSION,
        source_id: source.source_id.clone(),
        agent: source.agent.clone(),
        path: source.path.clone(),
        identity: source.snapshot.identity.clone(),
        offset: 0,
        line: 0,
        last_seen_size: 0,
        last_seen_modified: 0,
        parser_version: source.parser_version.clone(),
        source_schema_version: source.source_schema_version.clone(),
        state: ParserState::default(),
        boundary_hash: String::new(),
        head_hash: String::new(),
        head_len: 0,
        verified_usage: false,
        pending_import: false,
        error: None,
        saved_at: iso(Utc::now()),
    }
}
fn approved_metadata_upgrade(agent: &str, previous: &str, next: &str) -> bool {
    matches!(
        (agent, previous, next),
        ("claude-code", "claude-jsonl-v1.0.0", "claude-jsonl-v1.1.0")
    )
}
pub fn collect_source(
    store: &mut Store,
    source: &SourceDescriptor,
    options: &Options,
    cancel: &AtomicBool,
    kimi_dirs: &BTreeMap<String, String>,
) -> Result<SourceResult> {
    collect_source_with_progress(store, source, options, cancel, kimi_dirs, &|_| {})
}
/// Observer receives committed-batch metrics only; never raw records or UI types.
pub fn collect_source_with_progress(
    store: &mut Store,
    source: &SourceDescriptor,
    options: &Options,
    cancel: &AtomicBool,
    kimi_dirs: &BTreeMap<String, String>,
    progress: &dyn Fn(&Metrics),
) -> Result<SourceResult> {
    if source.format != "UTF8_JSONL" {
        return crate::structured::collect(store, source, options, cancel, progress);
    }
    let start = Instant::now();
    let mut metrics = Metrics {
        sources: 1,
        ..Default::default()
    };
    let mut out = SourceResult {
        source_id: source.source_id.clone(),
        agent: source.agent.clone(),
        state: CollectorState::Importing,
        confidence: source.confidence.clone(),
        metrics: Metrics::default(),
        diagnostics: Vec::new(),
        schema_fingerprints: BTreeMap::new(),
        checkpoint_age_seconds: None,
        token_field_known_records: BTreeMap::new(),
        earliest_timestamp: None,
        latest_timestamp: None,
    };
    let (mut file, current) = io::open_read(&source.path)?;
    if current.identity != source.snapshot.identity {
        return Err("SOURCE_REPLACED_DURING_DISCOVERY".into());
    }
    let saved = match load(store, &source.source_id) {
        Ok(v) => v,
        Err(_) => {
            out.diagnostics
                .push("CHECKPOINT_CORRUPT_RECOVERY_REPLAY".into());
            metrics.resets += 1;
            None
        }
    };
    let mut checkpoint = saved.clone().unwrap_or_else(|| base(source));
    let mut parser_upgrade = false;
    if checkpoint.version != 1 || checkpoint.source_schema_version != source.source_schema_version {
        out.state = CollectorState::RecoveryRequired;
        out.diagnostics
            .push("PARSER_OR_SCHEMA_VERSION_CHANGED".into());
        return Ok(out);
    }
    if checkpoint.parser_version != source.parser_version {
        if approved_metadata_upgrade(&source.agent, &checkpoint.parser_version, &source.parser_version) {
            metrics.resets += 1;
            parser_upgrade = true;
            checkpoint = base(source);
        } else {
            out.state = CollectorState::RecoveryRequired;
            out.diagnostics
                .push("PARSER_OR_SCHEMA_VERSION_CHANGED".into());
            return Ok(out);
        }
    }
    if let Ok(t) = agentbar_core::domain::timestamp(&checkpoint.saved_at) {
        out.checkpoint_age_seconds = Some((Utc::now() - t).num_seconds().max(0));
    }
    let unchanged = saved.is_some()
        && checkpoint.identity == current.identity
        && checkpoint.last_seen_size == current.size
        && checkpoint.last_seen_modified == current.modified
        && checkpoint.path == source.path
        && !options.force_reconcile
        && !checkpoint.pending_import
        && !parser_upgrade;
    if unchanged {
        metrics.unchanged_files = 1;
        out.state = if checkpoint.error.is_some() {
            CollectorState::Degraded
        } else {
            CollectorState::Idle
        };
        out.confidence = if checkpoint.verified_usage {
            Confidence::Confirmed
        } else {
            source.confidence.clone()
        };
        out.diagnostics.extend(checkpoint.error.clone());
        out.metrics = metrics;
        return Ok(out);
    }
    let mut reset = checkpoint.identity != current.identity
        || checkpoint.offset > current.size
        || checkpoint.head_len > current.size;
    if !reset && checkpoint.head_len > 0 {
        metrics.bytes_boundary += checkpoint.head_len;
        reset = fragment(&mut file, 0, checkpoint.head_len)? != checkpoint.head_hash;
    }
    if !reset && checkpoint.offset > 0 {
        let n = checkpoint.offset.min(256);
        metrics.bytes_boundary += n;
        reset = fragment(&mut file, checkpoint.offset - n, n)? != checkpoint.boundary_hash;
    }
    if checkpoint.offset == current.size
        && checkpoint.last_seen_modified != current.modified
        && current.size > 0
    {
        reset = true;
    }
    if reset {
        metrics.resets += 1;
        checkpoint = base(source);
        out.diagnostics.push("SOURCE_RESET_SAFE_REPLAY".into());
    }
    checkpoint.path = source.path.clone();
    checkpoint.identity = current.identity.clone();
    checkpoint.error = None;
    checkpoint.pending_import = false;
    if checkpoint.head_len == 0 && current.size > 0 {
        checkpoint.head_len = current.size.min(256);
        checkpoint.head_hash = fragment(&mut file, 0, checkpoint.head_len)?;
        metrics.bytes_boundary += checkpoint.head_len;
    }
    let begin_offset = checkpoint.offset;
    file.seek(SeekFrom::Start(begin_offset))?;
    let take = file.take(current.size - begin_offset);
    let mut reader = BufReader::with_capacity(256 * 1024, take);
    let parser = adapter(&source.agent)?;
    let mut context = ParseContext::fixture(&source.agent, &source.path.to_string_lossy());
    context.created_at = iso(Utc::now());
    context.collector_version = if source.agent == "qwen" {"1.0.0"} else {"phase2-native-jsonl-v1"}.into();
    context.kimi_session = source
        .path
        .parent()
        .and_then(|p| p.file_name())
        .map(|n| n.to_string_lossy().into_owned());
    context.kimi_cwd = source
        .path
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.file_name())
        .and_then(|n| kimi_dirs.get(&n.to_string_lossy().to_string()))
        .cloned();
    let mut raw = Vec::with_capacity(64 * 1024);
    let mut events = Vec::with_capacity(options.batch_events);
    let mut batch_lines = 0usize;
    loop {
        if cancel.load(Ordering::Relaxed) {
            out.state = CollectorState::Cancelled;
            checkpoint.pending_import = true;
            break;
        }
        raw.clear();
        let mut complete = false;
        let mut oversized = false;
        loop {
            if cancel.load(Ordering::Relaxed) {
                out.state = CollectorState::Cancelled;
                checkpoint.pending_import = true;
                break;
            }
            let chunk = reader.fill_buf()?;
            if chunk.is_empty() {
                break;
            }
            let n = chunk
                .iter()
                .position(|b| *b == 10)
                .map(|p| p + 1)
                .unwrap_or(chunk.len());
            if raw.len() + n > options.max_line_bytes {
                oversized = true;
                break;
            }
            raw.extend_from_slice(&chunk[..n]);
            metrics.bytes_read += n as u64;
            reader.consume(n);
            if raw.last() == Some(&10) {
                complete = true;
                break;
            }
        }
        if oversized {
            checkpoint.error = Some("OVERSIZED_RECORD_REQUIRES_RECOVERY".into());
            out.state = CollectorState::Degraded;
            metrics.malformed += 1;
            break;
        }
        if out.state == CollectorState::Cancelled || raw.is_empty() {
            break;
        }
        fault(options, "after-read");
        metrics.max_line_bytes = metrics.max_line_bytes.max(raw.len());
        if !complete {
            metrics.partial_tails += 1;
            break;
        }
        let line_start = checkpoint.offset;
        let mut payload = &raw[..raw.len() - 1];
        if line_start == 0 {
            payload = payload.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(payload);
        }
        if !payload.iter().all(|b| b.is_ascii_whitespace()) {
            let (class, fingerprint) = classify(&source.agent, payload);
            *out.schema_fingerprints.entry(fingerprint).or_default() += 1;
            if class == Class::Unknown || class == Class::Malformed {
                if class == Class::Unknown {
                    metrics.unknown += 1;
                    checkpoint.error = Some("UNKNOWN_SCHEMA_PAUSED_NO_SKIP".into());
                } else {
                    metrics.malformed += 1;
                    checkpoint.error = Some("MALFORMED_JSON_PAUSED_NO_SKIP".into());
                }
                out.state = CollectorState::Degraded;
                break;
            }
            if class == Class::Known {
                context.line = checkpoint.line + 1;
                context.offset = line_start;
                let previous = checkpoint.state.clone();
                metrics.records_parsed += 1;
                #[cfg(feature = "profiling")]
                let parse_span = agentbar_core::profiling::span("parse_and_normalize");
                match parser.parse(payload, &mut checkpoint.state, &context) {
                    Ok(Some(event)) => {
                        for (name, metric) in &event.metrics {
                            if metric.value.is_some() {
                                *out.token_field_known_records
                                    .entry(name.clone())
                                    .or_default() += 1;
                            }
                        }
                        if out
                            .earliest_timestamp
                            .as_ref()
                            .is_none_or(|v| event.timestamp < *v)
                        {
                            out.earliest_timestamp = Some(event.timestamp.clone());
                        }
                        if out
                            .latest_timestamp
                            .as_ref()
                            .is_none_or(|v| event.timestamp > *v)
                        {
                            out.latest_timestamp = Some(event.timestamp.clone());
                        }
                        events.push(event);
                        metrics.records_normalized += 1;
                        checkpoint.verified_usage = true;
                    }
                    Ok(None) => metrics.ignored += 1,
                    Err(_) => {
                        checkpoint.state = previous;
                        checkpoint.error = Some("MALFORMED_USAGE_PAUSED_NO_SKIP".into());
                        metrics.malformed += 1;
                        out.state = CollectorState::Degraded;
                        break;
                    }
                }
                #[cfg(feature = "profiling")]
                drop(parse_span);
            } else {
                metrics.ignored += 1;
            }
        } else {
            metrics.ignored += 1;
        }
        checkpoint.offset += raw.len() as u64;
        checkpoint.line += 1;
        batch_lines += 1;
        if events.len() >= options.batch_events || batch_lines >= options.batch_lines {
            // Boundary derives from the same source handle; seek then restore the buffered read position.
            let handle = reader.get_mut().get_mut();
            let position = handle.stream_position()?;
            let n = checkpoint.offset.min(256);
            checkpoint.boundary_hash = fragment(handle, checkpoint.offset - n, n)?;
            handle.seek(SeekFrom::Start(position))?;
            metrics.bytes_boundary += n;
            checkpoint.last_seen_size = current.size;
            checkpoint.last_seen_modified = current.modified;
            // A process may die just after this transaction. Remaining history must resume
            // even when identity/size/mtime are unchanged on the next launch.
            checkpoint.pending_import = checkpoint.offset < current.size;
            save_batch(store, &events, &mut checkpoint, &mut metrics, options)?;
            progress(&metrics);
            events.clear();
            batch_lines = 0;
        }
    }
    let handle = reader.get_mut().get_mut();
    let n = checkpoint.offset.min(256);
    checkpoint.boundary_hash = if n > 0 {
        metrics.bytes_boundary += n;
        fragment(handle, checkpoint.offset - n, n)?
    } else {
        String::new()
    };
    checkpoint.last_seen_size = current.size;
    checkpoint.last_seen_modified = current.modified;
    checkpoint.pending_import = out.state == CollectorState::Cancelled;
    save_batch(store, &events, &mut checkpoint, &mut metrics, options)?;
    metrics.bytes_incremental = if saved.is_some() && !reset {
        metrics.bytes_read
    } else {
        0
    };
    metrics.elapsed_ms = start.elapsed().as_millis() as u64;
    if out.state == CollectorState::Importing {
        out.state = CollectorState::Idle;
    }
    out.confidence = if checkpoint.verified_usage {
        Confidence::Confirmed
    } else {
        source.confidence.clone()
    };
    out.diagnostics.extend(checkpoint.error.clone());
    out.metrics = metrics;
    Ok(out)
}
pub fn collect(
    store: &mut Store,
    sources: &[SourceDescriptor],
    options: &Options,
    cancel: &AtomicBool,
    kimi_dirs: &BTreeMap<String, String>,
) -> Vec<SourceResult> {
    sources
        .iter()
        .map(
            |source| match collect_source(store, source, options, cancel, kimi_dirs) {
                Ok(r) => r,
                Err(_) => SourceResult {
                    source_id: source.source_id.clone(),
                    agent: source.agent.clone(),
                    state: CollectorState::Error,
                    confidence: source.confidence.clone(),
                    metrics: Metrics::default(),
                    diagnostics: vec!["SOURCE_OR_TRANSACTION_FAILURE".into()],
                    schema_fingerprints: BTreeMap::new(),
                    checkpoint_age_seconds: None,
                    token_field_known_records: BTreeMap::new(),
                    earliest_timestamp: None,
                    latest_timestamp: None,
                },
            },
        )
        .collect()
}
