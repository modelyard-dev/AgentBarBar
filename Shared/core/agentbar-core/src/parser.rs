use crate::{domain::*, Result};
use chrono::DateTime;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ThreadContext {
    pub model: Option<String>,
    pub provider: Option<String>,
    pub cwd: Option<String>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ParserState {
    pub session: Option<String>,
    pub entrypoint: Option<String>,
    pub root_session: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<String>,
    pub provider: Option<String>,
    pub agent_version: Option<String>,
    pub counters: Option<BTreeMap<String, i64>>,
    pub precise_requests: bool,
    pub forked_from: Option<String>,
    pub session_timestamp: Option<String>,
    pub history_start_ordinal: Option<i64>,
    pub thread_contexts: BTreeMap<String, ThreadContext>,
    pub warnings: Vec<String>,
}
impl ParserState {
    fn warn(&mut self, s: &str) {
        if self.warnings.len() < 8 && !self.warnings.iter().any(|x| x == s) {
            self.warnings.push(s.into());
        }
    }
}
/// Caller-owned platform provenance. No discovery, process inspection, or arbitrary IO in Core.
pub struct ParseContext {
    pub agent: String,
    pub name: String,
    pub collector: String,
    pub collector_version: String,
    pub path: String,
    pub line: u64,
    pub offset: u64,
    pub created_at: String,
    pub kimi_session: Option<String>,
    pub kimi_cwd: Option<String>,
    pub project: Option<ProjectIdentity>,
}
impl ParseContext {
    pub fn fixture(agent: &str, path: &str) -> Self {
        Self {
            agent: agent.into(),
            name: match agent {
                "codex" => "Codex",
                "claude-code" => "Claude Code",
                "kimi-cli" => "Kimi CLI",
                "pi" => "Pi",
                "workbuddy" => "WorkBuddy",
                "deepseek-harness" => "DeepSeek Harness",
                "gemini" => "Gemini CLI",
                "qwen" => "Qwen Code",
                "cline" => "Cline",
                "opencode" => "OpenCode",
                "antigravity" => "Antigravity",
                "antigravity-ide" => "Antigravity IDE",
                _ => agent,
            }
            .into(),
            collector: match agent {
                "claude-code" => "claude-local".into(),
                "kimi-cli" => "kimi-local".into(),
                _ => format!("{agent}-local"),
            },
            collector_version: "1.0.0".into(),
            path: path.into(),
            line: 1,
            offset: 0,
            created_at: "2026-10-05T04:00:00.000Z".into(),
            kimi_session: Some("anonymous-session".into()),
            kimi_cwd: None,
            project: None,
        }
    }
    // Intentional narrow counterpart of Swift ParseContext.event; named semantic inputs stay explicit.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn event(
        &self,
        ts: &str,
        id: &str,
        m: BTreeMap<String, Metric>,
        s: &ParserState,
        version: &str,
        meta: BTreeMap<String, String>,
        partial: bool,
    ) -> Result<NormalizedUsageRecord> {
        let sid = format!("{}:{id}", self.agent);
        let h = hash(&sid);
        let e = NormalizedUsageRecord {
            id: h.clone(),
            timestamp: iso(timestamp(ts)?),
            agent_id: self.agent.clone(),
            agent_name: self.name.clone(),
            provider: s.provider.clone(),
            model: s.model.clone(),
            raw_model_name: s.model.clone(),
            session_id: s.session.clone(),
            working_directory: s.cwd.clone(),
            project: self.project.clone(),
            metrics: m,
            cost: None,
            currency: None,
            cost_state: MetricState::NotAvailable,
            source_type: "local_jsonl".into(),
            source_path: self.path.clone(),
            source_event_id: sid,
            source_line: self.line,
            source_offset: self.offset,
            collector_id: self.collector.clone(),
            collector_version: self.collector_version.clone(),
            parser_version: version.into(),
            is_estimated: false,
            confidence: if partial { 0.8 } else { 1. },
            quality: if partial { "partial" } else { "exact" }.into(),
            fingerprint: h,
            source_metadata: meta,
            created_at: self.created_at.clone(),
        };
        e.validate()?;
        Ok(e)
    }
}
pub trait UsageAdapter {
    fn version(&self) -> &'static str;
    fn parse(
        &self,
        line: &[u8],
        state: &mut ParserState,
        context: &ParseContext,
    ) -> Result<Option<NormalizedUsageRecord>>;
}
pub struct ReferenceAdapter(pub &'static str);
pub fn adapter(agent: &str) -> Result<ReferenceAdapter> {
    match agent {
        "codex" => Ok(ReferenceAdapter("codex")),
        "claude-code" => Ok(ReferenceAdapter("claude-code")),
        "kimi-cli" => Ok(ReferenceAdapter("kimi-cli")),
        "pi" | "workbuddy" | "gemini" | "qwen" | "cline" | "opencode" | "deepseek-harness" | "antigravity"
        | "antigravity-ide" => Ok(ReferenceAdapter(match agent {
            "pi" => "pi",
            "workbuddy" => "workbuddy",
            "gemini" => "gemini",
            "qwen" => "qwen",
            "cline" => "cline",
            "opencode" => "opencode",
            "deepseek-harness" => "deepseek-harness",
            "antigravity" => "antigravity",
            _ => "antigravity-ide",
        })),
        _ => Err("UNKNOWN_AGENT_ADAPTER".into()),
    }
}
fn str_at(v: &Value, k: &str) -> Option<String> {
    v.get(k)?.as_str().map(str::to_owned)
}
pub fn token(v: &Value, k: &str) -> Result<Option<i64>> {
    let Some(n) = v.get(k).filter(|x| !x.is_null()) else {
        return Ok(None);
    };
    let n = n
        .as_number()
        .ok_or("Token must be numeric, not boolean/string")?;
    let f = n.as_f64().ok_or("Non-finite token")?;
    if !f.is_finite() || f < 0. || f > TOKEN_LIMIT as f64 || f.fract() != 0. {
        return Err("Invalid token counter".into());
    }
    Ok(Some(f as i64))
}
fn reported(v: &Value) -> Result<String> {
    let keys = [
        "input_tokens",
        "output_tokens",
        "cached_input_tokens",
        "cache_write_input_tokens",
        "reasoning_output_tokens",
        "total_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
        "input",
        "output",
        "cacheRead",
        "cacheWrite",
        "totalTokens",
        "reasoning",
    ];
    let mut o = BTreeMap::new();
    for k in keys {
        if let Ok(Some(n)) = token(v, k) {
            o.insert(k, n);
        }
    }
    if let Ok(Some(n)) = token(&v["output_tokens_details"], "thinking_tokens") {
        o.insert("thinking_tokens", n);
    }
    Ok(serde_json::to_string(&o)?)
}
fn metrics(v: &Value) -> Result<BTreeMap<String, Metric>> {
    let mut m = empty_metrics();
    for (dest, key) in [
        ("input", "input_tokens"),
        ("output", "output_tokens"),
        ("cacheRead", "cached_input_tokens"),
        ("cacheWrite", "cache_write_input_tokens"),
        ("reasoning", "reasoning_output_tokens"),
        ("total", "total_tokens"),
    ] {
        m.insert(dest.into(), Metric::new(token(v, key)?));
    }
    if m["total"].value.is_none() {
        return Err("Codex total missing".into());
    }
    Ok(m)
}
fn counters(v: &Value) -> Result<BTreeMap<String, i64>> {
    let m = metrics(v)?;
    Ok(m.into_iter()
        .filter_map(|(k, x)| {
            x.value.map(|v| {
                (
                    match k.as_str() {
                        "input" => "input_tokens",
                        "output" => "output_tokens",
                        "cacheRead" => "cached_input_tokens",
                        "cacheWrite" => "cache_write_input_tokens",
                        "reasoning" => "reasoning_output_tokens",
                        _ => "total_tokens",
                    }
                    .into(),
                    v,
                )
            })
        })
        .collect())
}
fn meta(pairs: &[(&str, String)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}
impl UsageAdapter for ReferenceAdapter {
    fn version(&self) -> &'static str {
        match self.0 {
            "codex" => "codex-jsonl-v1.2.0",
            "claude-code" => "claude-jsonl-v1.1.0",
            "kimi-cli" => "kimi-wire-v1.0.0",
            "pi" => "pi-session-v3.1.0",
            "workbuddy" => "workbuddy-jsonl-v1.0.1",
            "gemini" => "gemini-session-v2.0.1",
            "qwen" => crate::release_106::QWEN,
            "cline" => crate::release_106::CLINE,
            "opencode" => "opencode-sqlite-v1.0.0",
            "deepseek-harness" => "dsh-canonical-ledger-v4.1.0",
            _ => "antigravity-sqlite-protobuf-v1.0.0",
        }
    }
    fn parse(
        &self,
        line: &[u8],
        s: &mut ParserState,
        c: &ParseContext,
    ) -> Result<Option<NormalizedUsageRecord>> {
        if c.agent != self.0 {
            return Err("Adapter/context agent mismatch".into());
        }
        if self.0 == "qwen" { return crate::release_106::qwen(line, s, c); }
        if self.0 == "gemini" { return crate::release_106::gemini(line, s, c, false); }
        if !["codex", "claude-code", "kimi-cli"].contains(&self.0) {
            return crate::additional::parse(self.0, line, s, c, self.version());
        }
        let prefix = String::from_utf8_lossy(
            &line[..line.len().min(if self.0 == "claude-code" {
                1500
            } else if self.0 == "kimi-cli" {
                500
            } else {
                300
            })],
        );
        let suffix = String::from_utf8_lossy(&line[line.len().saturating_sub(300)..]);
        let has_claude_entrypoint = self.0 == "claude-code"
            && line.windows(b"\"entrypoint\"".len()).any(|w| w == b"\"entrypoint\"");
        let relevant = match self.0 {
            "claude-code" => prefix.contains("\"assistant\"") || has_claude_entrypoint,
            "kimi-cli" => prefix.contains("\"metadata\"") || prefix.contains("\"StatusUpdate\""),
            _ => [
                "session_meta",
                "turn_context",
                "thread_settings_applied",
                "token_usage_record",
                "token_count",
            ]
            .iter()
            .any(|k| prefix.contains(&format!("\"{k}\"")) || suffix.contains(&format!("\"{k}\""))),
        };
        if !relevant {
            return Ok(None);
        }
        if has_claude_entrypoint {
            #[derive(Deserialize)]
            struct ClaudeHeader {
                #[serde(rename = "type")]
                kind: Option<String>,
                entrypoint: Option<String>,
            }
            let header: ClaudeHeader = serde_json::from_slice(line)?;
            if ["user", "assistant", "system"].contains(&header.kind.as_deref().unwrap_or("")) {
                if let Some(entrypoint) = header.entrypoint {
                    s.entrypoint = Some(match entrypoint.as_str() {
                        "cli" | "claude-desktop" | "sdk" | "claude-code" => entrypoint,
                        _ => "other".into(),
                    });
                }
            }
            if header.kind.as_deref() != Some("assistant") {
                return Ok(None);
            }
        }
        let o: Value = serde_json::from_slice(line)?;
        if !o.is_object() {
            return Err("Expected JSON object".into());
        }
        match self.0 {
            "claude-code" => {
                let u = &o["message"]["usage"];
                let msg = &o["message"];
                if o["type"] != "assistant" || !u.is_object() || msg["model"] == "<synthetic>" {
                    return Ok(None);
                }
                let id = str_at(msg, "id")
                    .filter(|s| !s.is_empty())
                    .ok_or("Claude ID missing")?;
                s.session = str_at(&o, "sessionId");
                s.cwd = str_at(&o, "cwd");
                s.model = str_at(msg, "model");
                s.provider = str_at(msg, "provider").or_else(|| str_at(&o, "provider"));
                s.agent_version = str_at(&o, "version");
                let i = token(u, "input_tokens")?;
                let r = token(u, "cache_read_input_tokens")?;
                let w = token(u, "cache_creation_input_tokens")?;
                let out = token(u, "output_tokens")?;
                if i.is_none() && out.is_none() {
                    return Err("Claude counters missing".into());
                }
                let input = checked_sum(&[i, r, w])?;
                let total = checked_sum(&[input, out])?;
                let mut m = empty_metrics();
                for (k, v) in [
                    ("input", input),
                    ("output", out),
                    ("cacheRead", r),
                    ("cacheWrite", w),
                    (
                        "reasoning",
                        token(&u["output_tokens_details"], "thinking_tokens")?,
                    ),
                    ("total", total),
                ] {
                    m.insert(k.into(), Metric::new(v));
                }
                let identity = format!(
                    "message:{}{id}",
                    str_at(&o, "requestId").map(|r| r + ":").unwrap_or_default()
                );
                let metadata = meta(&[
                    ("reported_usage", reported(u)?),
                    ("counting_method", "message_snapshot_upsert".into()),
                    (
                        "input_semantics",
                        "uncached_plus_cache_read_plus_cache_write".into(),
                    ),
                    (
                        "agent_version",
                        s.agent_version.clone().unwrap_or("unknown".into()),
                    ),
                    (
                        "entrypoint",
                        s.entrypoint.clone().unwrap_or("legacy_or_unknown".into()),
                    ),
                ]);
                Ok(Some(c.event(
                    o["timestamp"].as_str().ok_or("Timestamp missing")?,
                    &identity,
                    m,
                    s,
                    self.version(),
                    metadata,
                    total.is_none(),
                )?))
            }
            "kimi-cli" => {
                if o["type"] == "metadata" {
                    let v = str_at(&o, "protocol_version")
                        .filter(|x| x.starts_with("1."))
                        .ok_or("Kimi wire version unsupported")?;
                    s.agent_version = Some(format!("wire-{v}"));
                    return Ok(None);
                }
                let p = &o["message"]["payload"];
                let u = &p["token_usage"];
                if o["message"]["type"] != "StatusUpdate" || !u.is_object() {
                    return Ok(None);
                }
                let id = str_at(p, "message_id")
                    .filter(|x| !x.is_empty())
                    .ok_or("Kimi ID missing")?;
                let t = o["timestamp"]
                    .as_f64()
                    .filter(|n| n.is_finite() && *n > 0. && *n <= 253_402_300_799.)
                    .ok_or("Kimi timestamp invalid")?;
                let ts = DateTime::from_timestamp(
                    (t * 1000.).round() as i64 / 1000,
                    ((t * 1000.).round() as i64 % 1000) as u32 * 1_000_000,
                )
                .ok_or("Timestamp out of range")?;
                s.session = c.kimi_session.clone();
                s.cwd = c.kimi_cwd.clone();
                s.model = None;
                s.provider = None;
                let mut raw = BTreeMap::new();
                for k in [
                    "input_other",
                    "output",
                    "input_cache_read",
                    "input_cache_creation",
                ] {
                    raw.insert(k, token(u, k)?.ok_or("Kimi components missing")?);
                }
                let input = checked_sum(&[
                    Some(raw["input_other"]),
                    Some(raw["input_cache_read"]),
                    Some(raw["input_cache_creation"]),
                ])?;
                let total = checked_sum(&[input, Some(raw["output"])])?;
                let mut m = empty_metrics();
                for (k, v) in [
                    ("input", input),
                    ("output", Some(raw["output"])),
                    ("cacheRead", Some(raw["input_cache_read"])),
                    ("cacheWrite", Some(raw["input_cache_creation"])),
                    ("total", total),
                ] {
                    m.insert(k.into(), Metric::new(v));
                }
                m.insert("reasoning".into(), Metric::absent(MetricState::Unsupported));
                let metadata = meta(&[
                    ("reported_usage", serde_json::to_string(&raw)?),
                    ("counting_method", "wire_status_request_usage".into()),
                    (
                        "wire_protocol",
                        s.agent_version.clone().unwrap_or("unverified".into()),
                    ),
                    (
                        "model_availability",
                        "historical wire does not report model".into(),
                    ),
                    (
                        "input_normalization",
                        "input_other + input_cache_read + input_cache_creation".into(),
                    ),
                ]);
                Ok(Some(c.event(
                    &iso(ts),
                    &format!("message:{id}"),
                    m,
                    s,
                    self.version(),
                    metadata,
                    false,
                )?))
            }
            _ => parse_codex(&o, s, c, self.version()),
        }
    }
}
fn inherited(o: &Value, s: &ParserState) -> bool {
    if s.forked_from.is_none() {
        false
    } else if let (Some(b), Some(n)) = (s.history_start_ordinal, o["ordinal"].as_i64()) {
        n < b
    } else {
        o["timestamp"].as_str() == s.session_timestamp.as_deref()
    }
}
fn parse_codex(
    o: &Value,
    s: &mut ParserState,
    c: &ParseContext,
    version: &str,
) -> Result<Option<NormalizedUsageRecord>> {
    let p = &o["payload"];
    let typ = o["type"].as_str().unwrap_or("");
    if typ == "session_meta" {
        s.session = str_at(p, "id");
        s.root_session = str_at(p, "session_id");
        s.cwd = str_at(p, "cwd");
        s.provider = str_at(p, "model_provider");
        s.agent_version = str_at(p, "cli_version");
        s.forked_from = str_at(p, "forked_from_id");
        s.session_timestamp = str_at(o, "timestamp");
        s.history_start_ordinal = p["forked_from_ordinal_exclusive"]
            .as_i64()
            .or(p["subagent_history_start_ordinal"].as_i64());
        return Ok(None);
    }
    if typ == "event_msg"
        && p["type"] == "thread_settings_applied"
        && p["thread_settings"].is_object()
    {
        if let Some(owner) = str_at(p, "thread_id") {
            let v = &p["thread_settings"];
            let tc = ThreadContext {
                model: str_at(v, "model"),
                provider: str_at(v, "model_provider_id"),
                cwd: str_at(v, "cwd"),
            };
            if s.session.as_ref() == Some(&owner) {
                s.model = tc.model.clone();
                s.provider = tc.provider.clone();
                s.cwd = tc.cwd.clone().or(s.cwd.clone());
            }
            s.thread_contexts.insert(owner, tc);
        }
        return Ok(None);
    }
    if typ == "turn_context" {
        s.model = str_at(p, "model");
        s.cwd = str_at(p, "cwd").or(s.cwd.clone());
        return Ok(None);
    }
    let Some(session) = s.session.clone() else {
        if typ == "token_usage_record" || p["type"] == "token_count" {
            return Err("Codex session metadata missing".into());
        }
        return Ok(None);
    };
    if typ == "token_usage_record" {
        let id = str_at(p, "response_id")
            .filter(|x| !x.is_empty())
            .ok_or("Codex response ID missing")?;
        let m = metrics(&p["usage"])?;
        let owner = str_at(p, "thread_id").unwrap_or(session.clone());
        if inherited(o, s) && (p.get("thread_id").is_none() || owner == session) {
            return Ok(None);
        }
        if owner == session {
            if p["thread_token_usage"].is_object() {
                s.counters = Some(counters(&p["thread_token_usage"])?)
            }
            s.precise_requests = true;
        }
        // Event attribution needs four fields, not a clone of the growing owner-context map.
        // Keeping thread_contexts out avoids O(requests * known owners) work on copied histories.
        let mut a = ParserState {
            session: Some(owner.clone()),
            model: s.model.clone(),
            provider: s.provider.clone(),
            cwd: s.cwd.clone(),
            ..Default::default()
        };
        if owner != session {
            let tc = s.thread_contexts.get(&owner).cloned().unwrap_or_default();
            a.model = tc.model;
            a.provider = tc.provider;
            a.cwd = tc.cwd;
        }
        let mut md = meta(&[
            ("reported_usage", reported(&p["usage"])?),
            ("counting_method", "request_usage".into()),
            (
                "agent_version",
                s.agent_version.clone().unwrap_or("unknown".into()),
            ),
            ("thread_id", owner.clone()),
            ("response_id", id.clone()),
            ("physical_thread_id", session.clone()),
            ("owner_matches_file", (owner == session).to_string()),
        ]);
        for k in ["turn_id", "root_turn_id", "session_id"] {
            if let Some(v) = str_at(p, k) {
                md.insert(k.into(), v);
            }
        }
        if let Some(root) = &s.root_session {
            md.insert(
                "root_session_id".into(),
                str_at(p, "session_id").unwrap_or(root.clone()),
            );
        }
        if owner != session {
            md.insert("timestamp_semantics".into(),"Timestamp reported by copied rollout; original execution time is not independently verified".into());
            md.insert("attribution_quality".into(), "partial".into());
        }
        return Ok(Some(c.event(
            o["timestamp"].as_str().ok_or("Timestamp missing")?,
            &format!("thread:{owner}:response:{id}"),
            m,
            &a,
            version,
            md,
            owner != session,
        )?));
    }
    if typ != "event_msg" || p["type"] != "token_count" || s.precise_requests {
        return Ok(None);
    }
    let info = &p["info"];
    if !info.is_object() {
        return Ok(None);
    }
    let next = counters(&info["total_token_usage"])?;
    if inherited(o, s) {
        s.counters = Some(next);
        return Ok(None);
    }
    if s.counters.as_ref() == Some(&next) {
        return Ok(None);
    }
    let previous = s.counters.clone();
    let mut delta = next.clone();
    let mut partial = false;
    let mut method = "cumulative_difference";
    if let Some(old) = &previous {
        if next["total_tokens"] == old["total_tokens"] {
            s.counters = Some(next);
            return Ok(None);
        }
        if next["total_tokens"] < old["total_tokens"] {
            s.warn(
                "Out-of-order cumulative snapshot ignored; legacy attribution coverage is partial",
            );
            return Ok(None);
        }
        for (k, v) in &next {
            match old.get(k) {
                Some(n) if v >= n => {
                    delta.insert(k.clone(), v - n);
                }
                Some(_) => {
                    delta.remove(k);
                    partial = true;
                    s.warn("Legacy cumulative component corrected by source; breakdown unavailable for this interval");
                }
                None => {
                    delta.remove(k);
                    partial = true;
                }
            }
        }
    } else if info["last_token_usage"].is_object() {
        let last = counters(&info["last_token_usage"])?;
        if last["total_tokens"] != next["total_tokens"] {
            delta = last;
            partial = true;
            method = "last_request_in_partial_history";
            s.warn("History baseline unavailable: first cumulative snapshot exceeds last request");
        }
    } else {
        return Err("Codex first snapshot baseline missing".into());
    }
    s.counters = Some(next.clone());
    let m = metrics(&serde_json::to_value(delta)?)?;
    if m["total"].value == Some(0) {
        return Ok(None);
    }
    let ts = o["timestamp"].as_str().ok_or("Timestamp missing")?;
    let id = format!(
        "counter:{}",
        hash(&format!("{ts}:{}", serde_json::to_string(&next)?))
    );
    let mut md = meta(&[
        ("reported_usage", reported(&info["total_token_usage"])?),
        ("counting_method", method.into()),
        (
            "agent_version",
            s.agent_version.clone().unwrap_or("unknown".into()),
        ),
    ]);
    if let Some(old) = previous {
        md.insert(
            "previous_cumulative_usage".into(),
            serde_json::to_string(&old)?,
        );
    }
    if info["last_token_usage"].is_object() {
        md.insert(
            "last_request_usage".into(),
            reported(&info["last_token_usage"])?,
        );
    }
    if let Some(root) = &s.root_session {
        md.insert("root_session_id".into(), root.clone());
    }
    md.insert("thread_id".into(), session);
    if !s.warnings.is_empty() {
        md.insert("coverage_notes".into(), s.warnings.join("; "));
    }
    Ok(Some(c.event(
        ts,
        &id,
        m,
        s,
        version,
        md,
        partial || !s.warnings.is_empty(),
    )?))
}
