//! Read-only SQLite metadata and bounded whole-session JSON. Source databases are never migrated.
use crate::{
    ingest::{self, CollectorState, Metrics, Options, SourceResult},
    io,
    locator::{Confidence, SourceDescriptor},
};
use agentbar_core::{
    domain::{hash, iso, NormalizedUsageRecord},
    parser::{adapter, ParseContext, ParserState, UsageAdapter},
    storage::{CommitContext, Store},
    Result,
};
use rusqlite::{params, Connection, OpenFlags};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::BTreeMap,
    io::Read,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
fn check(cancel: &AtomicBool) -> Result<()> {
    if cancel.load(Ordering::Relaxed) {
        Err("COLLECTION_CANCELLED".into())
    } else {
        Ok(())
    }
}
fn source_db(source: &SourceDescriptor) -> Result<Connection> {
    io::safe_path(&source.path)?;
    let db = Connection::open_with_flags(
        &source.path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(Duration::from_millis(1000))?;
    db.execute_batch("BEGIN")?;
    Ok(db)
}
fn columns(db: &Connection, table: &str, required: &[&str]) -> Result<()> {
    let mut q = db.prepare(&format!("PRAGMA table_info({table})"))?;
    let cols = q
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if required.iter().any(|c| !cols.iter().any(|n| n == c)) {
        return Err("SOURCE_SCHEMA_UNSUPPORTED".into());
    }
    Ok(())
}
fn signature(source: &SourceDescriptor) -> Result<String> {
    let mut s = String::new();
    for p in [
        source.path.clone(),
        std::path::PathBuf::from(format!("{}-wal", source.path.display())),
    ] {
        if p.exists() {
            let (_, m) = io::open_read(&p)?;
            s.push_str(&format!("{:?}:{}:{};", m.identity, m.size, m.modified))
        } else {
            s.push_str("absent;")
        }
    }
    Ok(hash(&s))
}
#[derive(Deserialize)]
struct GeminiSession {
    #[serde(rename = "sessionId")]
    session_id: String,
    messages: Vec<GeminiMessage>,
}
#[derive(Clone, Deserialize, serde::Serialize)]
struct GeminiMessage {
    id: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "type")]
    kind: String,
    tokens: Option<BTreeMap<String, Option<i64>>>,
    model: Option<String>,
    provider: Option<String>,
}
#[derive(Clone)]
struct GeminiLocation { line: u64, offset: u64, pointer: Option<String> }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiStreamRow {
    session_id: Option<String>,
    id: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
    tokens: Option<BTreeMap<String, Option<i64>>>,
    model: Option<String>,
    messages: Option<Vec<GeminiMessage>>,
    #[serde(rename = "$set")]
    set: Option<GeminiSet>,
    #[serde(rename = "$rewindTo")]
    rewind: Option<String>,
    #[serde(rename = "$patch")]
    patch: Option<GeminiPatch>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiSet {session_id: Option<String>, messages: Option<Vec<GeminiMessage>>}
#[derive(Deserialize)]
struct GeminiPatch {} // Content edits cannot create or erase billed usage.
type GeminiReplay = (GeminiSession, BTreeMap<String,GeminiLocation>, BTreeMap<String,String>);
fn read_gemini_stream(bytes: &[u8]) -> Result<GeminiReplay> {
    let mut session = None;
    let mut messages = BTreeMap::<String,GeminiMessage>::new();
    let mut order = vec![];
    let mut locations = BTreeMap::new();
    let (mut rewind, mut patch, mut offset) = (0,0,0u64);
    for (index, line) in bytes.split_inclusive(|b| *b == b'\n').enumerate() {
        if !line.ends_with(b"\n") {break;}
        let location = GeminiLocation {line:index as u64+1,offset,pointer:None};
        offset += line.len() as u64;
        let raw = &line[..line.len()-1];
        if raw.is_empty() {continue;}
        let row: GeminiStreamRow = serde_json::from_slice(raw)?;
        let has_session = row.session_id.is_some();
        if has_session {session=row.session_id;}
        let mut remember = |message: GeminiMessage, location: GeminiLocation| -> Result<()> {
            let id = message.id.clone().filter(|s|!s.is_empty()).ok_or("GEMINI_MESSAGE_ID_MISSING")?;
            if !messages.contains_key(&id) {order.push(id.clone());}
            if message.tokens.is_some() || messages.get(&id).is_none_or(|m|m.tokens.is_none()) {
                messages.insert(id.clone(),message); locations.insert(id,location);
            }
            Ok(())
        };
        if let Some(set) = row.set {
            if set.session_id.is_some() {session=set.session_id;}
            for (i,message) in set.messages.unwrap_or_default().into_iter().enumerate() {
                let mut loc=location.clone(); loc.pointer=Some(format!("$set/messages/{i}"));remember(message,loc)?;
            }
        } else if row.rewind.is_some() {rewind+=1;}
        else if row.patch.is_some() {patch+=1;}
        else if let (Some(kind),Some(id)) = (row.kind,row.id) {
            remember(GeminiMessage {id:Some(id),kind,timestamp:row.timestamp,tokens:row.tokens,model:row.model,provider:None},location)?;
        } else if let Some(checkpoint) = row.messages {
            for (i,message) in checkpoint.into_iter().enumerate() {
                let mut loc=location.clone();loc.pointer=Some(format!("messages/{i}"));remember(message,loc)?;
            }
        } else if !has_session {return Err("GEMINI_STREAM_RECORD_UNSUPPORTED".into());}
    }
    Ok((GeminiSession {session_id:session.filter(|s|!s.is_empty()).ok_or("GEMINI_SESSION_ID_MISSING")?,
        messages:order.into_iter().filter_map(|id|messages.remove(&id)).collect()},locations,
        BTreeMap::from([("rewind_records".into(),rewind.to_string()),("patch_records".into(),patch.to_string()),
            ("history_semantics".into(),"all observed usage retained across rewind/patch/checkpoint; latest counters per message".into())])))
}
pub fn collect(
    store: &mut Store,
    source: &SourceDescriptor,
    options: &Options,
    cancel: &AtomicBool,
    progress: &dyn Fn(&Metrics),
) -> Result<SourceResult> {
    let start = Instant::now();
    check(cancel)?;
    let (_, current) = io::open_read(&source.path)?;
    if current.identity != source.snapshot.identity {
        return Err("SOURCE_REPLACED_DURING_DISCOVERY".into());
    }
    let sig = signature(source)?;
    let saved = ingest::load(store, &source.source_id)?;
    let mut cp = saved.clone().unwrap_or_else(|| ingest::base(source));
    let mut metrics = Metrics {
        sources: 1,
        ..Default::default()
    };
    let mut out = SourceResult {
        source_id: source.source_id.clone(),
        agent: source.agent.clone(),
        state: CollectorState::Idle,
        confidence: Confidence::Probable,
        metrics: Metrics::default(),
        diagnostics: vec![],
        schema_fingerprints: BTreeMap::new(),
        checkpoint_age_seconds: None,
        token_field_known_records: BTreeMap::new(),
        earliest_timestamp: None,
        latest_timestamp: None,
    };
    if cp.boundary_hash == sig
        && cp.identity == current.identity
        && cp.parser_version == source.parser_version
        && !options.force_reconcile
    {
        metrics.unchanged_files = 1;
        out.confidence = if cp.verified_usage {
            Confidence::Confirmed
        } else {
            Confidence::Probable
        };
        out.diagnostics.extend(cp.error.clone());
        out.metrics = metrics;
        return Ok(out);
    }
    let parser = adapter(&source.agent)?;
    let mut ctx = ParseContext::fixture(&source.agent, &source.path.to_string_lossy());
    ctx.created_at = iso(chrono::Utc::now());
    ctx.line = 0;
    ctx.collector_version = "native-metadata-v1".into();
    let mut events = vec![];
    let mut state = ParserState::default();
    let mut canonical = None;
    match source.agent.as_str() {
        "gemini" => {
            if current.size > 64 * 1024 * 1024 {
                return Err("GEMINI_SESSION_SIZE_LIMIT".into());
            }
            let (mut file, _) = io::open_read(&source.path)?;
            let mut bytes = Vec::new();
            file.by_ref()
                .take(64 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
            if bytes.len() > 64 * 1024 * 1024 {
                return Err("GEMINI_SESSION_SIZE_LIMIT".into());
            }
            metrics.bytes_read = bytes.len() as u64;
            let stream = source.path.extension().is_some_and(|e| e == "jsonl");
            let (session, locations, notes) = if stream { read_gemini_stream(&bytes)? } else {
                (serde_json::from_slice::<GeminiSession>(&bytes)?, BTreeMap::new(), BTreeMap::new())
            };
            if session.session_id.is_empty() {return Err("GEMINI_SESSION_ID_MISSING".into());}
            state.session = Some(session.session_id);
            ctx.collector_version = "1.1.1".into();
            let project = source
                .path
                .parent()
                .and_then(|p| p.parent())
                .map(|p| p.join(".project_root"));
            if let Some(p) = project {
                if let Ok((mut f, m)) = io::open_read(&p) {
                    if m.size <= 4096 {
                        let mut cwd = String::new();
                        if f.read_to_string(&mut cwd).is_ok() {
                            let cwd = cwd.trim();
                            if std::path::Path::new(cwd).is_absolute() {
                                state.cwd = Some(cwd.into())
                            }
                        }
                    }
                }
            }
            for (index, message) in session.messages.into_iter().enumerate() {
                check(cancel)?;
                if message.kind != "gemini" || message.tokens.is_none() {
                    continue;
                }
                let location = message.id.as_ref().and_then(|id| locations.get(id));
                ctx.line = location.map_or(0, |l| l.line);
                ctx.offset = location.map_or(0, |l| l.offset);
                if let Some(mut e) = agentbar_core::release_106::gemini(&serde_json::to_vec(&message)?, &mut state, &ctx, stream)? {
                    e.source_metadata.extend(notes.clone());
                    if !stream {e.source_metadata.insert("json_pointer".into(),format!("messages/{index}"));}
                    else if let Some(pointer) = location.and_then(|l| l.pointer.clone()) {e.source_metadata.insert("json_pointer".into(),pointer);}
                    if state.cwd.is_some() {e.source_metadata.insert("cwd_source".into(),"project_root_metadata".into());}
                    events.push(e)
                }
            }
        }
        "cline" => {
            if current.size > 64 * 1024 * 1024 {return Err("CLINE_TASK_SIZE_LIMIT".into());}
            let (mut file, _) = io::open_read(&source.path)?;
            let mut bytes = Vec::new();
            file.by_ref().take(64 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
            if bytes.len() > 64 * 1024 * 1024 {return Err("CLINE_TASK_SIZE_LIMIT".into());}
            metrics.bytes_read = bytes.len() as u64;
            let task = source.path.parent().and_then(|p|p.file_name()).and_then(|s|s.to_str()).ok_or("CLINE_TASK_ID_MISSING")?;
            ctx.collector_version = "1.0.0".into();
            let parsed = agentbar_core::release_106::cline(&bytes, task, &ctx)?;
            events = parsed.0;
            if parsed.1 > 0 {out.diagnostics.push("CLINE_DELETED_SUBAGENT_AGGREGATES_EXCLUDED".into());}
        }
        "deepseek-harness" => {
            let db = source_db(source)?;
            columns(
                &db,
                "usage_records",
                &[
                    "canonical_id",
                    "session_id",
                    "timestamp",
                    "provider",
                    "model",
                    "input_tokens",
                    "output_tokens",
                    "cache_read_tokens",
                    "cache_write_tokens",
                    "reasoning_tokens",
                    "total_tokens",
                    "unclassified",
                    "source_type",
                    "historical_or_live",
                    "updated_at",
                    "schema_version",
                    "accounting_version",
                    "excluded_reason",
                ],
            )?;
            let(schema,generation,aggregate,migration):(i64,i64,i64,String)=db.query_row("SELECT storage_schema_version,record_generation,aggregate_generation,migration_status FROM meta WHERE id=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
            let fresh_ledger = migration == "not_started"
                && !source
                    .path
                    .with_file_name("dsh_token_usage_sidebar.json")
                    .exists();
            if schema != 4 || generation != aggregate || !(migration == "done" || fresh_ledger) {
                return Err("DSH_ACCOUNTING_MIGRATION_UNFINISHED".into());
            }
            let expected: (i64, i64) = db.query_row(
                "SELECT calls,total_tokens FROM aggregate_global WHERE id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            let actual:(i64,i64)=db.query_row("SELECT count(*),coalesce(sum(total_tokens),0) FROM usage_records WHERE excluded_reason IS NULL",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
            if expected != actual {
                return Err("DSH_LEDGER_AGGREGATE_MISMATCH".into());
            }
            let mut query=db.prepare("SELECT canonical_id,session_id,timestamp,provider,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,total_tokens,unclassified,schema_version,accounting_version FROM usage_records WHERE excluded_reason IS NULL ORDER BY canonical_id")?;
            let mut rows = query.query([])?;
            while let Some(r) = rows.next()? {
                check(cancel)?;
                let row = json!({"canonical_id":r.get::<_,String>(0)?,"session_id":r.get::<_,String>(1)?,"timestamp":r.get::<_,i64>(2)?,"provider":r.get::<_,Option<String>>(3)?,"model":r.get::<_,Option<String>>(4)?,"input_tokens":r.get::<_,i64>(5)?,"output_tokens":r.get::<_,i64>(6)?,"cache_read_tokens":r.get::<_,i64>(7)?,"cache_write_tokens":r.get::<_,i64>(8)?,"reasoning_tokens":r.get::<_,i64>(9)?,"total_tokens":r.get::<_,i64>(10)?,"unclassified":r.get::<_,i64>(11)?,"schema_version":r.get::<_,i64>(12)?,"accounting_version":r.get::<_,i64>(13)?,"excluded_reason":null});
                let raw = serde_json::to_vec(&row)?;
                metrics.bytes_read += raw.len() as u64;
                if let Some(e) = parser.parse(&raw, &mut state, &ctx)? {
                    events.push(e)
                }
            }
            let sum = events.iter().try_fold(0i64, |n, e| {
                n.checked_add(e.metrics["total"].value.unwrap_or(0))
                    .ok_or("DSH_TOTAL_OVERFLOW")
            })?;
            if events.len() as i64 != expected.0 || sum != expected.1 {
                return Err("DSH_NORMALIZED_RECONCILIATION_MISMATCH".into());
            }
            canonical = Some(expected);
            cp.state.counters = Some(BTreeMap::from([("record_generation".into(), generation)]));
        }
        "opencode" => {
            let db = source_db(source)?;
            columns(
                &db,
                "message",
                &["id", "session_id", "time_created", "time_updated", "data"],
            )?;
            columns(
                &db,
                "session",
                &["id", "directory", "parent_id", "time_created"],
            )?;
            let mut q=db.prepare("SELECT json_object('id',m.id,'session_id',m.session_id,'role',json_extract(m.data,'$.role'),'created',json_extract(m.data,'$.time.created'),'completed',json_extract(m.data,'$.time.completed'),'model',json_extract(m.data,'$.modelID'),'provider',json_extract(m.data,'$.providerID'),'tokens',json_extract(m.data,'$.tokens'),'has_error',CASE WHEN json_type(m.data,'$.error') IS NOT NULL AND json_type(m.data,'$.error')!='null' THEN 1 ELSE 0 END,'cwd',coalesce(json_extract(m.data,'$.path.cwd'),s.directory),'parent_id',s.parent_id,'session_created',s.time_created) FROM message m JOIN session s ON s.id=m.session_id WHERE json_extract(m.data,'$.role')='assistant' ORDER BY m.time_updated,m.id")?;
            let mut rows = q.query([])?;
            while let Some(r) = rows.next()? {
                check(cancel)?;
                let raw: String = r.get(0)?;
                metrics.bytes_read += raw.len() as u64;
                if let Some(e) = parser.parse(raw.as_bytes(), &mut state, &ctx)? {
                    events.push(e)
                }
            }
        }
        "antigravity" | "antigravity-ide" => {
            let db = source_db(source)?;
            events = generations(&db, source, cancel, &mut metrics, &ctx)?
        }
        _ => return Err("STRUCTURED_SOURCE_UNSUPPORTED".into()),
    }
    check(cancel)?;
    cp.identity = current.identity;
    cp.path = source.path.clone();
    cp.parser_version = source.parser_version.clone();
    cp.source_schema_version = source.source_schema_version.clone();
    cp.boundary_hash = sig;
    cp.last_seen_size = current.size;
    cp.last_seen_modified = current.modified;
    cp.offset = current.size;
    cp.error = out.diagnostics.first().cloned();
    cp.verified_usage = !events.is_empty();
    cp.pending_import = false;
    metrics.records_parsed = events.len() as u64;
    metrics.records_normalized = events.len() as u64;
    if let Some(expected) = canonical {
        // The verified ledger is authoritative. Replace only this Agent inside one transaction;
        // source exclusions and downward corrections cannot be suppressed by generic upsert policy.
        cp.saved_at = iso(chrono::Utc::now());
        let body = serde_json::to_string(&cp)?;
        let envelope = serde_json::to_string(&json!({"checksum":hash(&body),"checkpoint":cp}))?;
        let result=store.commit_atomic(&events,&CommitContext{authoritative_agent:Some(source.agent.clone()),..Default::default()},|tx|{let own:(i64,i64)=tx.query_row("SELECT count(*),coalesce(sum(total_tokens),0) FROM usage_events WHERE agent_id=?",[&source.agent],|r|Ok((r.get(0)?,r.get(1)?)))?;if own!=expected{return Err("DSH_COMMIT_RECONCILIATION_MISMATCH".into())}tx.execute("INSERT INTO agentbar_source_checkpoints VALUES(?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET envelope_json=excluded.envelope_json,path=excluded.path",params![source.source_id,source.agent,source.path.to_string_lossy(),envelope])?;Ok(())})?;
        metrics.records_inserted = result.inserted as u64;
        metrics.records_updated = result.updated as u64;
        metrics.duplicates = result.duplicates as u64;
        metrics.commits = 1;
    } else {
        for batch in events.chunks(options.batch_events.max(1)) {
            check(cancel)?;
            let mut batch_cp = cp.clone();
            batch_cp.boundary_hash.clear();
            batch_cp.pending_import = true;
            ingest::save_batch(store, batch, &mut batch_cp, &mut metrics, options)?;
            progress(&metrics)
        }
        ingest::save_batch(store, &[], &mut cp, &mut metrics, options)?;
    }
    metrics.elapsed_ms = start.elapsed().as_millis() as u64;
    out.confidence = if events.is_empty() {
        Confidence::Probable
    } else {
        Confidence::Confirmed
    };
    out.metrics = metrics;
    progress(&out.metrics);
    Ok(out)
}
#[derive(Default)]
struct Proto {
    ints: BTreeMap<u64, Vec<u64>>,
    bytes: BTreeMap<u64, Vec<Vec<u8>>>,
}
fn varint(raw: &[u8], pos: &mut usize) -> Result<u64> {
    let mut n = 0u64;
    for shift in (0..70).step_by(7) {
        let b = *raw.get(*pos).ok_or("PROTOBUF_TRUNCATED")?;
        *pos += 1;
        if shift == 63 && b > 1 {
            return Err("PROTOBUF_OVERFLOW".into());
        }
        n |= ((b & 127) as u64) << shift;
        if b & 128 == 0 {
            return Ok(n);
        }
    }
    Err("PROTOBUF_VARINT_INVALID".into())
}
impl Proto {
    fn parse(raw: &[u8], allowed: &[u64]) -> Result<Self> {
        let mut out = Self::default();
        let mut pos = 0;
        while pos < raw.len() {
            let key = varint(raw, &mut pos)?;
            let field = key >> 3;
            if field == 0 {
                return Err("PROTOBUF_FIELD_ZERO".into());
            }
            match key & 7 {
                0 => {
                    let n = varint(raw, &mut pos)?;
                    if allowed.contains(&field) {
                        out.ints.entry(field).or_default().push(n)
                    }
                }
                2 => {
                    let size = usize::try_from(varint(raw, &mut pos)?)
                        .map_err(|_| "PROTOBUF_SIZE_INVALID")?;
                    let end = pos
                        .checked_add(size)
                        .filter(|n| *n <= raw.len())
                        .ok_or("PROTOBUF_TRUNCATED")?;
                    if allowed.contains(&field) {
                        out.bytes
                            .entry(field)
                            .or_default()
                            .push(raw[pos..end].to_vec())
                    }
                    pos = end
                }
                1 | 5 => {
                    pos = pos
                        .checked_add(if key & 7 == 1 { 8 } else { 4 })
                        .filter(|n| *n <= raw.len())
                        .ok_or("PROTOBUF_TRUNCATED")?
                }
                _ => return Err("PROTOBUF_WIRE_UNSUPPORTED".into()),
            }
        }
        Ok(out)
    }
    fn int(&self, k: u64) -> Option<u64> {
        self.ints.get(&k)?.first().copied()
    }
    fn bytes(&self, k: u64) -> Option<&[u8]> {
        self.bytes.get(&k)?.first().map(Vec::as_slice)
    }
    fn text(&self, k: u64) -> Option<String> {
        std::str::from_utf8(self.bytes(k)?).ok().map(str::to_owned)
    }
    fn packed(&self, k: u64) -> Result<Vec<u64>> {
        if let Some(ns) = self.ints.get(&k) {
            return Ok(ns.clone());
        }
        let Some(bytes) = self.bytes(k) else {
            return Ok(vec![]);
        };
        let mut pos = 0;
        let mut out = vec![];
        while pos < bytes.len() {
            out.push(varint(bytes, &mut pos)?)
        }
        Ok(out)
    }
}
fn generations(
    db: &Connection,
    source: &SourceDescriptor,
    cancel: &AtomicBool,
    metrics: &mut Metrics,
    ctx: &ParseContext,
) -> Result<Vec<NormalizedUsageRecord>> {
    columns(db, "gen_metadata", &["idx", "data"])?;
    columns(db, "steps", &["idx", "status", "metadata"])?;
    let mut q = db.prepare("SELECT idx,data FROM gen_metadata ORDER BY idx")?;
    let mut rows = q.query([])?;
    let mut events = vec![];
    let parser = adapter(&source.agent)?;
    while let Some(row) = rows.next()? {
        check(cancel)?;
        let index: i64 = row.get(0)?;
        let blob: Vec<u8> = row.get(1)?;
        if index < 0 || blob.len() > 64 * 1024 * 1024 {
            return Err("GENERATION_METADATA_INVALID".into());
        }
        metrics.bytes_read += blob.len() as u64;
        let generation = Proto::parse(&blob, &[1, 2, 4])?;
        let Some(chat) = generation.bytes(1) else {
            continue;
        };
        let chat = Proto::parse(chat, &[4, 9, 19, 22])?;
        let Some(u) = chat.bytes(4) else { continue };
        let usage = Proto::parse(u, &[1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12])?;
        let (input, output, read, write, reasoning) = (
            usage.int(2).unwrap_or(0),
            usage.int(3).unwrap_or(0),
            usage.int(5).unwrap_or(0),
            usage.int(4).unwrap_or(0),
            usage.int(9).unwrap_or(0),
        );
        if [input, output, read, write, reasoning]
            .iter()
            .any(|n| *n > agentbar_core::domain::TOKEN_LIMIT as u64)
        {
            return Err("GENERATION_COUNTER_INVALID".into());
        }
        if input + output + read + write == 0 {
            continue;
        }
        let mut step_meta = None;
        if let Some(step) = generation.packed(2)?.first() {
            let step = i64::try_from(*step).map_err(|_| "GENERATION_STEP_OVERFLOW")?;
            let mut stmt = db.prepare("SELECT status,metadata FROM steps WHERE idx=?")?;
            let mut steps = stmt.query([step])?;
            let Some(r) = steps.next()? else { continue };
            let status: i64 = r.get(0)?;
            if ![3, 6, 7, 12].contains(&status) {
                continue;
            }
            step_meta = r.get::<_, Option<Vec<u8>>>(1)?;
        }
        let mut stamp = if let Some(start) = chat.bytes(9) {
            Proto::parse(start, &[4])?.bytes(4).map(<[u8]>::to_vec)
        } else {
            None
        };
        if stamp.is_none() {
            if let Some(step) = step_meta {
                let p = Proto::parse(&step, &[1, 7, 8, 32])?;
                stamp = p
                    .bytes(8)
                    .or_else(|| p.bytes(7))
                    .or_else(|| p.bytes(32))
                    .or_else(|| p.bytes(1))
                    .map(<[u8]>::to_vec)
            }
        }
        let stamp = Proto::parse(&stamp.ok_or("GENERATION_TIMESTAMP_MISSING")?, &[1, 2])?;
        let sec = stamp.int(1).ok_or("GENERATION_TIMESTAMP_MISSING")?;
        let nano = stamp.int(2).unwrap_or(0);
        if sec == 0 || sec >= 253402300799 || nano >= 1_000_000_000 {
            return Err("GENERATION_TIMESTAMP_INVALID".into());
        }
        let request = usage
            .text(11)
            .or_else(|| usage.text(12))
            .or_else(|| usage.text(7))
            .or_else(|| generation.text(4))
            .filter(|s| !s.is_empty())
            .ok_or("GENERATION_REQUEST_MISSING")?;
        let model = chat
            .text(22)
            .or_else(|| chat.text(19))
            .or_else(|| usage.int(1).map(|n| format!("model_enum:{n}")));
        let provider = usage.int(6).map(|n| match n {
            1 => "API_PROVIDER_INTERNAL".into(),
            3 => "API_PROVIDER_GOOGLE_VERTEX".into(),
            24 => "API_PROVIDER_GOOGLE_GEMINI".into(),
            26 => "API_PROVIDER_ANTHROPIC_VERTEX".into(),
            30 => "API_PROVIDER_GOOGLE_EVERGREEN".into(),
            31 => "API_PROVIDER_OPENAI_VERTEX".into(),
            _ => format!("api_provider_enum:{n}"),
        });
        let v = json!({"request_id":request,"timestamp":iso(chrono::DateTime::from_timestamp(sec as i64,nano as u32).ok_or("GENERATION_TIMESTAMP_INVALID")?),"session":source.path.file_stem().map(|s|s.to_string_lossy()),"model":model,"provider":provider,"index":index,"usage":{"input_tokens":input,"output_tokens":output,"cache_read_tokens":read,"cache_write_tokens":write,"thinking_output_tokens":reasoning}});
        if let Some(e) = parser.parse(&serde_json::to_vec(&v)?, &mut ParserState::default(), ctx)? {
            events.push(e)
        }
    }
    Ok(events)
}
