//! Core metadata boundary. Hosts own discovery, paths, file identities and watchers.
use crate::{
    domain::NormalizedUsageRecord,
    parser::{ParseContext, ParserState, UsageAdapter},
    Result,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentIdentity {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Detection {
    pub installed: bool,
    pub evidence: Vec<String>,
    pub source_available: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceSpec {
    pub path: String,
    pub kind: String,
    pub identity: String,
}

/// Implemented by an OS host, never by a token parser. No global filesystem scan implied.
pub trait PlatformSourceAdapter {
    fn detect(&self, agent: &AgentIdentity) -> Result<Detection>;
    fn locate_sources(
        &self,
        agent: &AgentIdentity,
        explicit_roots: &[String],
    ) -> Result<Vec<SourceSpec>>;
}

/// Versioned Core checkpoint. It is NOT Swift SourceCursor JSON and cannot replace it.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Checkpoint {
    pub version: u32,
    pub parser_version: String,
    pub offset: u64,
    pub line: u64,
    pub state: ParserState,
}
impl Checkpoint {
    pub fn new(adapter: &dyn UsageAdapter) -> Self {
        Self {
            version: 1,
            parser_version: adapter.version().into(),
            offset: 0,
            line: 0,
            state: ParserState::default(),
        }
    }
}
pub struct ParsedBatch {
    pub events: Vec<NormalizedUsageRecord>,
    pub checkpoint: Checkpoint,
    pub incomplete_tail: bool,
}

/// Parse bytes read starting at the supplied checkpoint, without committing any IO.
/// The caller persists events and the returned checkpoint in one transaction.
pub fn parse_jsonl_batch(
    adapter: &dyn UsageAdapter,
    bytes: &[u8],
    checkpoint: &Checkpoint,
    context: &mut ParseContext,
) -> Result<ParsedBatch> {
    if checkpoint.version != 1 || checkpoint.parser_version != adapter.version() {
        return Err("Checkpoint version mismatch; explicit re-import required".into());
    }
    let mut next = checkpoint.clone();
    let mut events = Vec::new();
    let mut incomplete_tail = false;
    for line in bytes.split_inclusive(|b| *b == b'\n') {
        if line.len() > 64 * 1024 * 1024 {
            return Err("JSONL record exceeds metadata limit".into());
        }
        if !line.ends_with(b"\n") {
            incomplete_tail = true;
            break;
        }
        context.offset = next.offset;
        context.line = next.line + 1;
        let raw = &line[..line.len() - 1];
        if !raw.is_empty() {
            // A failed batch leaves the original checkpoint/state unchanged.
            if let Some(event) = adapter.parse(raw, &mut next.state, context)? {
                events.push(event);
            }
        }
        next.offset = next
            .offset
            .checked_add(line.len() as u64)
            .ok_or("Offset overflow")?;
        next.line += 1;
    }
    Ok(ParsedBatch {
        events,
        checkpoint: next,
        incomplete_tail,
    })
}
