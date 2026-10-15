//! Metadata-only contracts matching the macOS 1.0.6 adapters.
use crate::{domain::*, parser::{token, ParseContext, ParserState}, Result};
use serde_json::Value;
use std::collections::BTreeMap;

pub const QWEN: &str = "qwen-token-ledger-v1.0.0";
pub const CLINE: &str = "cline-task-ui-v1.0.0";
pub const GEMINI_JSON: &str = "gemini-session-json-v1.1.0";
pub const GEMINI_JSONL: &str = "gemini-session-jsonl-v1.0.1";
fn text(v: &Value, key: &str) -> Option<String> {
    v[key].as_str().filter(|s| !s.is_empty()).map(str::to_owned)
}
fn required(v: &Value, key: &str) -> Result<String> {
    text(v, key).ok_or_else(|| format!("MISSING_METADATA_{key}").into())
}
fn counters(v: &Value, keys: &[&str]) -> Result<BTreeMap<String, i64>> {
    let mut out = BTreeMap::new();
    for key in keys { if let Some(n) = token(v, key)? { out.insert((*key).into(), n); } }
    Ok(out)
}
pub fn qwen(raw: &[u8], s: &mut ParserState, c: &ParseContext) -> Result<Option<NormalizedUsageRecord>> {
    let v: Value = serde_json::from_slice(raw)?;
    if token(&v, "schemaVersion")? != Some(1) { return Err("QWEN_SCHEMA_UNSUPPORTED".into()); }
    let id = required(&v, "id")?;
    s.session = Some(required(&v, "sessionId")?);
    s.model = text(&v, "model").filter(|m| m != "unknown");
    s.provider = None; s.cwd = None;
    let raw = counters(&v, &["inputTokens","outputTokens","cachedTokens","thoughtsTokens","totalTokens"])?;
    let get = |k: &str| raw.get(k).copied();
    if get("totalTokens").is_none() && get("inputTokens").is_none() && get("outputTokens").is_none() { return Err("QWEN_COUNTERS_MISSING".into()); }
    let mut m = empty_metrics();
    for (key, n) in [("input",get("inputTokens")),("output",checked_sum(&[get("outputTokens"),get("thoughtsTokens")])?),
        ("cacheRead",get("cachedTokens")),("reasoning",get("thoughtsTokens")),("total",get("totalTokens"))] {
        m.insert(key.into(), Metric { value:n, state:if n.is_some(){MetricState::Partial}else{MetricState::NotAvailable} });
    }
    m.insert("cacheWrite".into(), Metric::absent(MetricState::Unsupported));
    let mut meta = BTreeMap::from([
        ("reported_usage".into(),serde_json::to_string(&raw)?),
        ("counting_method".into(),"independent_request_ledger".into()),
        ("usage_scope".into(),"request".into()),
        ("input_semantics".into(),"cached tokens included; input may be a lower bound".into()),
        ("output_semantics".into(),"candidate output plus thoughts".into()),
        ("source_reliability".into(),"upstream normalized; missing/invalid counters may become zero".into()),
        ("total_semantics".into(),"upstream reported or derived; origin not retained".into()),
    ]);
    for (key, len) in [("localDate",10),("localMonth",7)] {
        if let Some(t) = text(&v,key) { if t.len()==len && t.bytes().enumerate().all(|(i,b)| if i==4 || i==7 {b==b'-'}else{b.is_ascii_digit()}) {meta.insert(key.into(),t);} }
    }
    if let Some(source) = text(&v,"source") {meta.insert("agent_scope".into(),if source=="main"{"main"}else{"subagent"}.into());}
    if let (Some(i),Some(o),Some(t)) = (m["input"].value,m["output"].value,m["total"].value) {
        meta.insert("component_reconciliation".into(),if checked_sum(&[Some(i),Some(o)])?==Some(t){"matched"}else{"mismatch"}.into());
    }
    let mut e = c.event(&required(&v,"timestamp")?, &format!("ledger:{id}"), m, s, QWEN, meta, true)?;
    e.source_type="local_token_ledger_jsonl".into(); Ok(Some(e))
}
pub fn gemini(raw: &[u8], s: &mut ParserState, c: &ParseContext, stream: bool) -> Result<Option<NormalizedUsageRecord>> {
    let v: Value = serde_json::from_slice(raw)?;
    let u = &v["tokens"];
    if v["type"]!="gemini" || !u.is_object() {return Ok(None);}
    if s.session.is_none() {return Err("GEMINI_SESSION_MISSING".into());}
    let id=required(&v,"id")?;
    let raw=counters(u,&["input","output","thoughts","tool","cached","total"])?;
    let get=|k:&str| raw.get(k).copied();
    let mut input=get("input");
    let mut output=checked_sum(&[get("output"),get("thoughts")])?;
    let total=get("total");
    let mut derived_input=false; let mut derived_output=false;
    if !stream {
        if let (None,Some(t),Some(o))=(input,total,output) {if t>=o {input=Some(t-o);derived_input=true;}}
        if let (None,Some(t),Some(i))=(output,total,input) {if t>=i {output=Some(t-i);derived_output=true;}}
    }
    if total.is_none() && input.is_none() && if stream {get("output").is_none()}else{output.is_none()} {return Err("GEMINI_COUNTERS_MISSING".into());}
    let mut m=empty_metrics();
    for (k,n,derived) in [("input",input,derived_input),("output",output,derived_output),("total",total,false),
        ("cacheRead",get("cached"),false),("reasoning",get("thoughts"),false)] {
        let mut metric=Metric::new(n); if n.is_some() && (n==Some(0)||derived) {metric.state=MetricState::Partial;} m.insert(k.into(),metric);
    }
    m.insert("cacheWrite".into(),Metric::absent(MetricState::Unsupported));
    s.model=text(&v,"model"); s.provider=if stream {None}else{text(&v,"provider")};
    let matched=total.is_some() && checked_sum(&[input,output])?==total;
    let partial=!matched || raw.values().any(|n|*n==0) || derived_input || derived_output;
    let meta=BTreeMap::from([
        ("reported_usage".into(),serde_json::to_string(&raw)?),
        ("counting_method".into(),"session_message_usage".into()),
        ("usage_scope".into(),"request".into()),
        ("input_semantics".into(),"reported prompt; cache is a subset; tool bucket not added".into()),
        ("output_semantics".into(),"candidate output plus thoughts when both present".into()),
        ("source_reliability".into(),"upstream may substitute zero for absent provider counters".into()),
        ("component_reconciliation".into(),if matched{"matched"}else{"incomplete_or_mismatch"}.into()),
    ]);
    let mut e=c.event(&required(&v,"timestamp")?,&format!("message:{id}"),m,s,if stream{GEMINI_JSONL}else{GEMINI_JSON},meta,partial)?;
    e.source_type=if stream{"local_session_jsonl"}else{"local_session_json"}.into(); Ok(Some(e))
}
pub fn cline(data: &[u8], task: &str, c: &ParseContext) -> Result<(Vec<NormalizedUsageRecord>,usize)> {
    let rows: Vec<Value>=serde_json::from_slice(data)?;
    let is=|v:&Value,say:&str| v["type"]=="say" && v["say"]==say;
    let excluded=rows.iter().filter(|r|is(r,"subagent_usage")||is(r,"deleted_api_reqs")).count();
    let usage=|v:&Value| -> Result<BTreeMap<String,Option<i64>>> {
        let Some(t)=v["text"].as_str() else{return Ok(BTreeMap::new());};
        let v:Value=serde_json::from_str(t)?;
        let mut out=BTreeMap::new();for key in ["tokensIn","tokensOut","cacheReads","cacheWrites"] {if v.get(key).is_some() {out.insert(key.into(),token(&v,key)?);}}
        Ok(out)
    };
    let s=ParserState {session:Some(task.into()),..Default::default()};
    let mut events=vec![];
    for (index,row) in rows.iter().enumerate().filter(|(_,r)|is(r,"api_req_started")) {
        let mut raw=usage(row)?;
        for next in rows.iter().skip(index+1) {
            if is(next,"api_req_started") {break;}
            if is(next,"api_req_finished") {raw.extend(usage(next)?);break;}
        }
        let raw:BTreeMap<String,i64>=raw.into_iter().filter_map(|(k,v)|v.map(|n|(k,n))).collect();
        if raw.is_empty(){continue;}
        let ts=token(row,"ts")?.ok_or("CLINE_TIMESTAMP_MISSING")?;
        let stamp=iso(chrono::DateTime::from_timestamp_millis(ts).ok_or("CLINE_TIMESTAMP_INVALID")?);
        let get=|k:&str|raw.get(k).copied();
        let mut m=empty_metrics();
        let input=checked_sum(&[get("tokensIn"),get("cacheReads"),get("cacheWrites")])?;
        let output=get("tokensOut");let total=checked_sum(&[input,output])?;
        for (key,n) in [("input",input),("output",output),("cacheRead",get("cacheReads")),("cacheWrite",get("cacheWrites")),("total",total)] {m.insert(key.into(),Metric::new(n));}
        m.insert("reasoning".into(),Metric::absent(MetricState::Unsupported));
        let meta=BTreeMap::from([
            ("reported_usage".into(),serde_json::to_string(&raw)?),("json_pointer".into(),index.to_string()),
            ("usage_scope".into(),"request".into()),("counting_method".into(),"task_request_carrier".into()),
            ("input_semantics".into(),"uncached input plus cache reads and writes only when all reported".into()),
            ("total_semantics".into(),"derived from complete input plus output".into()),
            ("excluded_aggregate_records".into(),excluded.to_string()),
            ("coverage_notes".into(),"deleted request and subagent aggregates excluded; model/project unavailable".into()),
        ]);
        let mut e=c.event(&stamp,&format!("task:{task}:request:{ts}"),m,&s,CLINE,meta,total.is_none()||excluded>0)?;
        e.source_type="local_task_ui_json".into();events.push(e);
    }
    Ok((events,excluded))
}
