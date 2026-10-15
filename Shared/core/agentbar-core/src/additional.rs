//! Metadata parsers ported from the audited Swift collectors; bodies never enter events.
use crate::{
    domain::*,
    parser::{token, ParseContext, ParserState},
    Result,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
fn text(v: &Value, k: &str) -> Option<String> {
    v[k].as_str().filter(|s| !s.is_empty()).map(str::to_owned)
}
fn require(v: &Value, k: &str) -> Result<String> {
    text(v, k).ok_or_else(|| format!("MISSING_METADATA_{k}").into())
}
fn millis(v: &Value) -> Result<String> {
    let n = v.as_i64().filter(|n| *n > 0).ok_or("INVALID_TIMESTAMP")?;
    Ok(iso(
        chrono::DateTime::from_timestamp_millis(n).ok_or("INVALID_TIMESTAMP")?
    ))
}
fn set(m: &mut BTreeMap<String, Metric>, k: &str, n: Option<i64>) {
    m.insert(k.into(), Metric::new(n));
}
fn sum(xs: &[Option<i64>]) -> Result<Option<i64>> {
    checked_sum(xs)
}
pub fn parse(
    agent: &str,
    raw: &[u8],
    s: &mut ParserState,
    c: &ParseContext,
    version: &str,
) -> Result<Option<NormalizedUsageRecord>> {
    let v: Value = serde_json::from_slice(raw)?;
    let mut m = empty_metrics();
    let mut meta = BTreeMap::new();
    let id;
    let ts;
    let mut partial = false;
    let mut source_type = "local_jsonl";
    match agent {
        "pi" => {
            let typ = v["type"].as_str().unwrap_or("");
            if typ == "session" {
                if v["version"] != 3 {
                    return Err("PI_SESSION_VERSION_UNSUPPORTED".into());
                };
                s.session = text(&v, "id");
                s.cwd = text(&v, "cwd");
                return Ok(None);
            }
            if typ == "model_change" {
                s.model = text(&v, "modelId");
                s.provider = text(&v, "provider");
                return Ok(None);
            }
            let msg = &v["message"];
            let summary = ["compaction", "branch_summary"].contains(&typ);
            if !((typ == "message"
                && ["assistant", "toolResult"].contains(&msg["role"].as_str().unwrap_or("")))
                || typ == "usage"
                || summary)
            {
                return Ok(None);
            }
            let u = if typ == "message" {
                &msg["usage"]
            } else {
                &v["usage"]
            };
            if !u.is_object() {
                return Ok(None);
            }
            if s.session.is_none() {
                return Err("PI_SESSION_MISSING".into());
            }
            s.model = if typ == "message" {
                text(msg, "responseModel").or_else(|| text(msg, "model"))
            } else {
                text(&v, "model")
            };
            s.provider = text(if typ == "message" { msg } else { &v }, "provider");
            let input = token(u, "input")?;
            let read = token(u, "cacheRead")?;
            let write = token(u, "cacheWrite")?;
            set(&mut m, "input", sum(&[input, read, write])?);
            for (k, src) in [
                ("output", "output"),
                ("cacheRead", "cacheRead"),
                ("cacheWrite", "cacheWrite"),
                ("reasoning", "reasoning"),
                ("total", "totalTokens"),
            ] {
                set(&mut m, k, token(u, src)?)
            }
            if input.is_none() && m["total"].value.is_none() {
                return Err("PI_COUNTERS_MISSING".into());
            }
            if msg["stopReason"] == "error" && m["total"].value == Some(0) {
                m = empty_metrics();
                meta.insert(
                    "availability_reason".into(),
                    "Error response has empty usage; actual consumption unavailable".into(),
                );
            }
            partial = sum(&[m["input"].value, m["output"].value])? != m["total"].value
                || m["total"].value.is_none()
                || (summary && s.model.is_none());
            ts = require(&v, "timestamp")?;
            id = format!("entry:{}:{ts}", require(&v, "id")?);
            meta.insert("counting_method".into(), "entry_usage".into());
            meta.insert(
                "usage_category".into(),
                if summary || msg["role"] == "toolResult" {
                    "tool_summary"
                } else {
                    "model"
                }
                .into(),
            );
        }
        "workbuddy" => {
            let u = &v["message"]["usage"];
            if !u.is_object()
                || !(v["type"] == "function_call"
                    || (v["type"] == "message" && v["role"] == "assistant"))
            {
                return Ok(None);
            }
            let p = &v["providerData"];
            id = format!("message:{}", require(p, "messageId")?);
            s.session = Some(require(&v, "sessionId")?);
            s.cwd = text(&v, "cwd");
            s.model = text(p, "model");
            s.provider = text(p, "provider");
            ts = millis(&v["timestamp"])?;
            for (k, key) in [
                ("input", "input_tokens"),
                ("output", "output_tokens"),
                ("total", "total_tokens"),
                ("cacheRead", "cache_read_input_tokens"),
            ] {
                set(&mut m, k, token(u, key)?)
            }
            m.insert(
                "cacheWrite".into(),
                Metric::absent(MetricState::Unsupported),
            );
            set(
                &mut m,
                "reasoning",
                token(
                    &p["rawUsage"]["completion_tokens_details"],
                    "reasoning_tokens",
                )?,
            );
            let i = m["input"].value.ok_or("WORKBUDDY_INPUT_MISSING")?;
            let o = m["output"].value.ok_or("WORKBUDDY_OUTPUT_MISSING")?;
            let t = m["total"].value.ok_or("WORKBUDDY_TOTAL_MISSING")?;
            partial = sum(&[Some(i), Some(o)])? != Some(t);
            for (k, max) in [("cacheRead", i), ("reasoning", o)] {
                if m[k].value.is_some_and(|n| n > max) {
                    meta.insert(
                        format!("reported_{k}_tokens"),
                        m[k].value.unwrap().to_string(),
                    );
                    m.insert(k.into(), Metric::absent(MetricState::Unknown));
                    partial = true
                }
            }
            meta.insert("counting_method".into(), "provider_message_usage".into());
        }
        "gemini" => {
            let u = &v["tokens"];
            if v["type"] != "gemini" || !u.is_object() {
                return Ok(None);
            };
            if s.session.is_none() {
                return Err("GEMINI_SESSION_MISSING".into());
            }
            id = format!("message:{}", require(&v, "id")?);
            ts = require(&v, "timestamp")?;
            s.model = text(&v, "model");
            s.provider = text(&v, "provider");
            let i = token(u, "input")?;
            let o = token(u, "output")?;
            let thought = token(u, "thoughts")?;
            let tool = token(u, "tool")?;
            let total = token(u, "total")?;
            let mut output = sum(&[o, thought])?;
            let input = if let (Some(t), Some(o)) = (total, output) {
                if t >= o {
                    Some(t - o)
                } else {
                    sum(&[i, tool])?
                }
            } else {
                sum(&[i, tool])?
            };
            if output.is_none() {
                if let (Some(t), Some(i)) = (total, input) {
                    if t >= i {
                        output = Some(t - i)
                    }
                }
            }
            for (k, n) in [
                ("input", input),
                ("output", output),
                ("total", total),
                ("reasoning", thought),
                ("cacheRead", token(u, "cached")?),
            ] {
                set(&mut m, k, n)
            }
            m.insert(
                "cacheWrite".into(),
                Metric::absent(MetricState::Unsupported),
            );
            if total.is_none() && input.is_none() && output.is_none() {
                return Err("GEMINI_COUNTERS_MISSING".into());
            };
            partial = input.is_none() || output.is_none() || sum(&[input, output])? != total;
            source_type = "local_session_json";
            meta.insert("counting_method".into(), "session_message_usage".into());
        }
        "opencode" => {
            if v["role"] != "assistant" || v["completed"].is_null() {
                return Ok(None);
            }
            if !v["parent_id"].is_null() {
                let created = v["created"].as_i64().ok_or("FORK_CREATED_MISSING")?;
                let fork = v["session_created"]
                    .as_i64()
                    .ok_or("FORK_CREATED_MISSING")?;
                if created < fork {
                    return Ok(None);
                }
            }
            id = format!("message:{}", require(&v, "id")?);
            ts = millis(&v["completed"])?;
            s.session = Some(require(&v, "session_id")?);
            s.cwd = text(&v, "cwd");
            s.model = text(&v, "model");
            s.provider = text(&v, "provider");
            let u = &v["tokens"];
            let mut invalid = false;
            let mut counter = |v: &Value, k: &str| -> Metric {
                match token(v, k) {
                    Ok(n) => Metric::new(n),
                    Err(_) => {
                        invalid = true;
                        Metric::absent(MetricState::Unknown)
                    }
                }
            };
            let input = counter(u, "input");
            let output = counter(u, "output");
            let read = counter(&u["cache"], "read");
            let write = counter(&u["cache"], "write");
            let reasoning = counter(u, "reasoning");
            let total = counter(u, "total");
            let normalized = |xs: &[Metric]| -> Result<Metric> {
                if xs.iter().any(|m| m.state == MetricState::Unknown) {
                    Ok(Metric::absent(MetricState::Unknown))
                } else {
                    Ok(Metric::new(sum(&xs
                        .iter()
                        .map(|m| m.value)
                        .collect::<Vec<_>>())?))
                }
            };
            m.insert(
                "input".into(),
                normalized(&[input, read.clone(), write.clone()])?,
            );
            m.insert("output".into(), normalized(&[output, reasoning.clone()])?);
            m.insert("cacheRead".into(), read);
            m.insert("cacheWrite".into(), write);
            m.insert("reasoning".into(), reasoning);
            m.insert("total".into(), total);
            if m["total"].value.is_none() {
                let total = sum(&[m["input"].value, m["output"].value])?;
                set(&mut m, "total", total)
            }
            if v["has_error"] == 1 && m["total"].value == Some(0) {
                return Ok(None);
            };
            if m["total"].value.is_none() {
                return Err("OPENCODE_TOTAL_MISSING".into());
            };
            partial = invalid;
            source_type = "local_sqlite";
            meta.insert(
                "counting_method".into(),
                "completed_assistant_message".into(),
            );
        }
        "deepseek-harness" => {
            if !v["excluded_reason"].is_null() {
                return Ok(None);
            }
            if ![1, 2, 3, 4].contains(&v["schema_version"].as_i64().unwrap_or(0))
                || ![1, 2].contains(&v["accounting_version"].as_i64().unwrap_or(0))
            {
                return Err("DSH_ACCOUNTING_VERSION_UNSUPPORTED".into());
            }
            let mut ns = Vec::new();
            for k in [
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "reasoning_tokens",
                "total_tokens",
            ] {
                ns.push(token(&v, k)?.ok_or("DSH_COUNTER_MISSING")?)
            }
            let input = sum(&[Some(ns[0]), Some(ns[2]), Some(ns[3])])?.unwrap();
            let unknown = v["unclassified"].as_i64().unwrap_or(0) != 0;
            if !unknown && (sum(&[Some(input), Some(ns[1])])? != Some(ns[5]) || ns[4] > ns[1]) {
                return Err("DSH_COMPONENT_MISMATCH".into());
            }
            for (k, n) in [
                ("input", input),
                ("output", ns[1]),
                ("cacheRead", ns[2]),
                ("cacheWrite", ns[3]),
                ("reasoning", ns[4]),
            ] {
                m.insert(
                    k.into(),
                    if unknown {
                        Metric::absent(MetricState::Unknown)
                    } else {
                        Metric::new(Some(n))
                    },
                );
            }
            set(&mut m, "total", Some(ns[5]));
            let canonical = require(&v, "canonical_id")?;
            id = format!("ledger:{canonical}");
            ts = millis(&v["timestamp"])?;
            s.session = Some(require(&v, "session_id")?);
            s.model = text(&v, "model");
            s.provider = text(&v, "provider");
            s.cwd = None;
            partial = unknown;
            source_type = "local_sqlite";
            meta.insert("canonical_id".into(), canonical);
            meta.insert("reported_uncached_input".into(), ns[0].to_string());
            meta.insert("counting_method".into(), "dsh_canonical_ledger".into());
            meta.insert(
                "input_semantics".into(),
                "normalized input includes cache reads and cache writes; source input is uncached"
                    .into(),
            );
            meta.insert("reasoning_semantics".into(), "included in output".into());
            meta.insert("storage_schema_version".into(), "4".into());
        }
        "antigravity" | "antigravity-ide" => {
            id = format!("generation:{}", require(&v, "request_id")?);
            ts = require(&v, "timestamp")?;
            s.session = text(&v, "session");
            s.cwd = None;
            s.model = text(&v, "model");
            s.provider = text(&v, "provider");
            let u = &v["usage"];
            let input = token(u, "input_tokens")?.ok_or("GENERATION_INPUT_MISSING")?;
            let output = token(u, "output_tokens")?.ok_or("GENERATION_OUTPUT_MISSING")?;
            let read = token(u, "cache_read_tokens")?.ok_or("GENERATION_CACHE_MISSING")?;
            let write = token(u, "cache_write_tokens")?.ok_or("GENERATION_CACHE_MISSING")?;
            let reasoning = token(u, "thinking_output_tokens")?;
            let normalized = sum(&[Some(input), Some(read), Some(write)])?;
            for (k, n) in [
                ("input", normalized),
                ("output", Some(output)),
                ("cacheRead", Some(read)),
                ("cacheWrite", Some(write)),
                ("total", sum(&[normalized, Some(output)])?),
            ] {
                set(&mut m, k, n)
            }
            if reasoning.is_some_and(|n| n > output) {
                m.insert("reasoning".into(), Metric::absent(MetricState::Unknown));
                partial = true
            } else {
                set(&mut m, "reasoning", reasoning)
            }
            source_type = "local_sqlite_protobuf";
            meta.insert(
                "counting_method".into(),
                "completed_generation_usage".into(),
            );
            meta.insert("source_row_id".into(), v["index"].to_string());
        }
        _ => return Err("UNKNOWN_METADATA_ADAPTER".into()),
    }
    // Persist only normalized numeric counters; never serialize the whole source object.
    meta.insert(
        "reported_usage".into(),
        serde_json::to_string(&json!(m
            .iter()
            .filter_map(|(k, v)| v.value.map(|n| (k, n)))
            .collect::<BTreeMap<_, _>>()))?,
    );
    let mut e = c.event(&ts, &id, m, s, version, meta, partial)?;
    e.source_type = source_type.into();
    Ok(Some(e))
}
