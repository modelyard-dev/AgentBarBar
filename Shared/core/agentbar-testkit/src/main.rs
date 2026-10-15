use agentbar_core::{aggregation::*, domain::*, parser::*, storage::Store, Result};
use std::{env, fs};
fn parse(agent: &str, path: &str, session: Option<String>) -> Result<Vec<NormalizedUsageRecord>> {
    let parser = adapter(agent)?;
    let mut state = ParserState::default();
    let mut ctx = ParseContext::fixture(agent, "fixture");
    if session.is_some() {
        ctx.kimi_session = session;
    }
    let mut events = Vec::new();
    let bytes = fs::read(path)?;
    for line in bytes.split_inclusive(|b| *b == b'\n') {
        if !line.ends_with(b"\n") {
            return Err("Incomplete JSONL tail: checkpoint must not advance".into());
        }
        let raw = &line[..line.len() - 1];
        let raw = raw.strip_suffix(b"\r").unwrap_or(raw);
        if !raw.is_empty() {
            if let Some(e) = parser.parse(raw, &mut state, &ctx)? {
                events.push(e)
            }
        }
        ctx.offset += line.len() as u64;
        ctx.line += 1;
    }
    let mut store = Store::memory()?;
    store.commit(&events)?;
    store.events()
}
fn run() -> Result<serde_json::Value> {
    let a = env::args().skip(1).collect::<Vec<_>>();
    if a.first().is_some_and(|s| {
        [
            "sources",
            "inspect",
            "collect",
            "status",
            "reconcile",
            "watch",
            "stream-benchmark",
            "verify",
        ]
        .contains(&s.as_str())
    }) {
        return agentbar_collector::cli::run(&a);
    }
    match a.first().map(String::as_str){
        Some("benchmark") if a.len()==2=>benchmark(a[1].parse()?),
        Some("snapshot") if a.len()==4=>{let events:Vec<NormalizedUsageRecord>=serde_json::from_slice(&fs::read(&a[1])?)?;let now=timestamp(&a[2])?;let mut ranges=serde_json::Map::new();for r in ["today","7","30","all"]{ranges.insert(r.into(),serde_json::to_value(summarize(&events,&range_filter(r,now,&a[3])?,now)?)?);}Ok(serde_json::json!({"now":a[2],"timeZone":a[3],"ranges":ranges,"agents":groups(&events,"agents",&QueryFilter::default(),now)?,"models":groups(&events,"models",&QueryFilter::default(),now)?}))},
        Some("parse") if a.len()>=3=>{if a[1]=="kimi-cli" && a.get(3).is_none(){return Err("KIMI_SESSION_REQUIRED: host supplies directory-derived identity".into());}Ok(serde_json::to_value(parse(&a[1],&a[2],a.get(3).cloned())?)?)},
        Some("import") if a.len()>=4=>{let events=parse(&a[1],&a[2],a.get(4).cloned())?;let mut store=Store::open(&a[3])?;let result=store.commit(&events)?;Ok(serde_json::json!({"commit":result,"events":store.events()?}))},
        Some("aggregate") if a.len()==5=>{let events:Vec<NormalizedUsageRecord>=serde_json::from_slice(&fs::read(&a[1])?)?;let now=timestamp(&a[2])?;let filter=range_filter(&a[4],now,&a[3])?;Ok(serde_json::to_value(summarize(&events,&filter,now)?)?)},
        Some("golden") if a.len()==3=>{let expected:serde_json::Value=serde_json::from_slice(&fs::read(&a[2])?)?;let mut actual=Vec::new();for(agent,file)in[("codex","codex-request.jsonl"),("claude-code","claude.jsonl"),("kimi-cli","kimi-wire.jsonl")]{for e in parse(agent,&format!("{}/{file}",a[1]),None)?{actual.push(e.golden());}}actual.sort_by_key(|e|e["sourceEventID"].as_str().unwrap().to_string());let want=expected["events"].as_array().ok_or("Invalid Golden")?.iter().filter(|e|["codex","claude-code","kimi-cli"].contains(&e["agentID"].as_str().unwrap_or(""))).cloned().collect::<Vec<_>>();if actual!=want{return Err(format!("Golden mismatch: actual={} expected={}",serde_json::to_string(&actual)?,serde_json::to_string(&want)?).into())}Ok(serde_json::json!({"status":"PASS","portedAdapters":3,"normalizedEvents":actual,"unportedAdapters":7,"scope":"PARSER_GOLDEN_NOT_AGENT_SYSTEM_PASS"}))},
        _=>Err("Usage: agentbar-core-cli parse AGENT FILE [KIMI_SESSION] | import AGENT FILE OWN_DB [KIMI_SESSION] | aggregate EVENTS_JSON NOW TZ today|7|30|all | golden FIXTURES EXPECTED_JSON".into())
    }
}
fn benchmark(n: usize) -> Result<serde_json::Value> {
    use std::time::Instant;
    if !(100..=100_000).contains(&n) {
        return Err("Bounded benchmark: 100..100000".into());
    }
    let raw=(0..n).map(|i|serde_json::json!({"timestamp":"2026-10-05T04:00:00.000Z","type":"token_usage_record","payload":{"thread_id":"anonymous-benchmark","response_id":format!("anonymous-{i:06}"),"usage":{"input_tokens":100,"output_tokens":23,"cached_input_tokens":40,"cache_write_input_tokens":2,"reasoning_output_tokens":7,"total_tokens":123}}}).to_string()).collect::<Vec<_>>();
    let begin = Instant::now();
    let decoded = raw
        .iter()
        .map(|s| serde_json::from_str::<serde_json::Value>(s))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let decode = begin.elapsed().as_secs_f64();
    drop(decoded);
    let parser = adapter("codex")?;
    let mut state = ParserState {
        session: Some("anonymous-benchmark".into()),
        model: Some("anonymous/raw".into()),
        ..Default::default()
    };
    let ctx = ParseContext::fixture("codex", "synthetic-benchmark");
    let begin = Instant::now();
    let records = raw
        .iter()
        .map(|s| {
            parser
                .parse(s.as_bytes(), &mut state, &ctx)?
                .ok_or_else(|| "Missing benchmark event".into())
        })
        .collect::<Result<Vec<_>>>()?;
    let normalized = begin.elapsed().as_secs_f64();
    let begin = Instant::now();
    for e in &records {
        e.validate()?;
        let _wire = serde_json::to_vec(e)?;
    }
    let normalized_wire = begin.elapsed().as_secs_f64();
    let mut store = Store::memory()?;
    let begin = Instant::now();
    let first = store.commit(&records)?;
    let import = begin.elapsed().as_secs_f64();
    let begin = Instant::now();
    let second = store.commit(&records)?;
    let dedup = begin.elapsed().as_secs_f64();
    let begin = Instant::now();
    let summary = summarize(
        &records,
        &QueryFilter::default(),
        timestamp("2026-10-05T05:00:00Z")?,
    )?;
    let aggregate = begin.elapsed().as_secs_f64();
    Ok(
        serde_json::json!({"scope":"ANONYMOUS_SYNTHETIC_PERFORMANCE_NOT_AGENT_USAGE","rows":n,"inputBytes":raw.iter().map(|s|s.len()).sum::<usize>(),"jsonDecodeSeconds":decode,"parseAndNormalizeSeconds":normalized,"normalizedValidationAndWireSeconds":normalized_wire,"recordsPerSecond":n as f64/normalized,"aggregationSeconds":aggregate,"importSeconds":import,"dedupSeconds":dedup,"inserted":first.inserted,"duplicates":second.duplicates,"logicalRows":summary.events,"total":summary.metrics["total"].value}),
    )
}
fn main() {
    match run() {
        Ok(v) => println!(
            "{}",
            serde_json::to_string_pretty(&v).expect("Serializable output")
        ),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    }
}
