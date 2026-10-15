//! Host DTO adapter. No raw source IO, HTTP listener or Tauri dependency here.
use agentbar_core::{
    aggregation::{range_filter, QueryFilter},
    domain::{iso, timestamp, NormalizedUsageRecord},
    storage::Store,
    Result,
};
use chrono::{DateTime, Days, Months, Utc};
use rusqlite::{params_from_iter, types::Value as Sql, OptionalExtension};
use serde_json::{json, Value};
use std::collections::BTreeMap;
pub const AGENTS: [(&str, &str); 12] = [
    ("codex", "Codex"),
    ("claude-code", "Claude Code"),
    ("kimi-cli", "Kimi CLI"),
    ("deepseek-harness", "DeepSeek Harness"),
    ("workbuddy", "WorkBuddy"),
    ("pi", "Pi"),
    ("gemini", "Gemini CLI"),
    ("qwen", "Qwen Code"),
    ("cline", "Cline"),
    ("opencode", "OpenCode"),
    ("antigravity", "Antigravity"),
    ("antigravity-ide", "Antigravity IDE"),
];
pub const INSPECTION_AGENTS: [(&str, &str); 1] = [("claude-desktop", "Claude Desktop")];
pub fn supported_agent(agent: &str) -> bool {
    AGENTS.iter().chain(INSPECTION_AGENTS.iter()).any(|(id, _)| *id == agent)
}

pub fn source_description(agent: &str) -> &'static str {
    match agent {
        "claude-desktop" => "Claude Desktop local chat and Cowork metadata inspection; no verified Token parser",
        "qwen" => "Qwen Code independent monthly Token ledger (upstream normalized counters)",
        "cline" => "Cline historical task ui_messages.json; aggregates excluded",
        "gemini" => "Gemini CLI local chat session JSON / append-only JSONL",
        _ => "Read-only local Agent usage data",
    }
}
pub fn capabilities(agent: &str) -> Value {
    if agent == "claude-desktop" {
        return json!({"input":"unsupported","output":"unsupported","cacheRead":"unsupported","cacheWrite":"unsupported","total":"unsupported","reasoning":"unsupported","cachedOutput":"unsupported","model":"unsupported","session":"unsupported","project":"unsupported","cost":"Not available"});
    }
    let mut caps = json!({"input":"Source reported","output":"Source reported","cacheRead":"Source reported when available",
        "cacheWrite":if ["workbuddy","gemini","qwen"].contains(&agent){"unsupported"}else{"Source reported when available"},
        "total":"Source reported","reasoning":if ["kimi-cli","cline"].contains(&agent){"unsupported"}else{"Source reported when available"},
        "cachedOutput":"unsupported","model":"Source reported when available","session":"Source reported","project":"Explicit working directory only","cost":"Not available"});
    if agent == "qwen" {
        for key in ["input","output","total","cacheRead","reasoning"] {caps[key]=json!("conditional");}
        caps["project"]=json!("unsupported");
    } else if agent == "cline" {
        caps["input"]=json!("conditional");
        caps["total"]=json!("derived");
        caps["model"]=json!("unsupported");caps["project"]=json!("unsupported");
    }
    caps
}
pub fn defaults() -> Value {
    json!({"language":"system","dashboardTheme":"forest","dashboardAppearance":"system","menuBarMode":"icon","port":0,"reconciliationSeconds":120,"disabledCollectors":[],"sourceOverrides":{},"customAgents":[]})
}
pub fn settings(store: &Store) -> Result<Value> {
    let s: Option<String> = store
        .db
        .query_row(
            "SELECT value_json FROM settings WHERE key='windows-host'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(s.map(|s| serde_json::from_str(&s))
        .transpose()?
        .unwrap_or_else(defaults))
}
pub fn save_settings(store: &Store, value: Value) -> Result<Value> {
    if !value.is_object() {
        return Err("INVALID_SETTINGS".into());
    }
    for (key, allowed) in [
        ("language", &["system", "en", "zh-Hans"][..]),
        ("dashboardTheme", &["forest", "paper", "ocean", "mono"][..]),
        ("dashboardAppearance", &["system", "light", "dark"][..]),
        ("menuBarMode", &["icon", "tokens", "agents", "cost"][..]),
    ] {
        if !allowed.contains(&value[key].as_str().unwrap_or("")) {
            return Err("INVALID_SETTINGS".into());
        }
    }
    let interval = value["reconciliationSeconds"]
        .as_u64()
        .ok_or("INVALID_SETTINGS")?;
    if !(60..=3600).contains(&interval) || value["port"] != 0 {
        return Err("INVALID_SETTINGS".into());
    }
    if value["customAgents"]
        .as_array()
        .is_none_or(|a| !a.is_empty())
    {
        return Err("CUSTOM_ADAPTER_NOT_IMPLEMENTED".into());
    }
    let disabled = value["disabledCollectors"]
        .as_array()
        .ok_or("INVALID_SETTINGS")?;
    if disabled
        .iter()
        .any(|v| !supported_agent(v.as_str().unwrap_or("")))
    {
        return Err("INVALID_SETTINGS".into());
    }
    let overrides = value["sourceOverrides"]
        .as_object()
        .ok_or("INVALID_SETTINGS")?;
    for (agent, roots) in overrides {
        if !supported_agent(agent) {
            return Err("SOURCE_NOT_SUPPORTED".into());
        }
        for root in roots.as_array().ok_or("INVALID_SETTINGS")? {
            let root = std::path::Path::new(root.as_str().ok_or("INVALID_SETTINGS")?);
            agentbar_collector::locator::safe_root(
                root,
                &agentbar_collector::locator::Profile::current()?,
            )?;
        }
    }
    // Do not persist arbitrary frontend fields.
    let mut clean = defaults();
    for k in [
        "language",
        "dashboardTheme",
        "dashboardAppearance",
        "menuBarMode",
        "reconciliationSeconds",
        "disabledCollectors",
        "sourceOverrides",
    ] {
        clean[k] = value[k].clone()
    }
    store.db.execute("INSERT INTO settings VALUES('windows-host',?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json",[serde_json::to_string(&clean)?])?;
    Ok(clean)
}
pub fn filter(query: &BTreeMap<String, String>) -> Result<QueryFilter> {
    let mut f = QueryFilter::default();
    for (key, target) in [("start", &mut f.start), ("end", &mut f.end)] {
        if let Some(s) = query.get(key) {
            *target = Some(timestamp(s)?.timestamp_millis() as f64 / 1000.)
        }
    }
    if matches!((f.start,f.end),(Some(a),Some(b)) if b<=a) {
        return Err("INVALID_RANGE".into());
    }
    f.agent = query.get("agent").cloned();
    f.model = query.get("model").cloned();
    f.project = query.get("project").cloned();
    f.provider = query.get("provider").cloned();
    f.session = query.get("session").cloned();
    Ok(f)
}
pub fn predicate(f: &QueryFilter) -> (String, Vec<Sql>) {
    let mut clauses = vec!["1=1".to_owned()];
    let mut args = vec![];
    for (op, v) in [(">=", f.start), ("<", f.end)] {
        if let Some(v) = v {
            clauses.push(format!("timestamp{op}?"));
            args.push(Sql::Real(v))
        }
    }
    for (k, v) in [
        ("agent_id", &f.agent),
        ("model", &f.model),
        ("project_id", &f.project),
        ("provider", &f.provider),
        ("session_id", &f.session),
    ] {
        if let Some(v) = v {
            clauses.push(if v == "unknown" {
                format!("({k}=? OR {k} IS NULL)")
            } else {
                format!("{k}=?")
            });
            args.push(Sql::Text(v.clone()))
        }
    }
    (clauses.join(" AND "), args)
}
pub fn distinct(
    store: &Store,
    column: &str,
    f: &QueryFilter,
    unknown: bool,
) -> Result<Vec<String>> {
    if !["agent_id", "model", "provider", "project_id", "session_id"].contains(&column) {
        return Err("INVALID_DIMENSION".into());
    }
    let (w, a) = predicate(f);
    let mut s = store.db.prepare(&format!(
        "SELECT DISTINCT {column} FROM usage_events WHERE {w} ORDER BY {column}"
    ))?;
    let mut out = vec![];
    for r in s.query_map(params_from_iter(a), |r| r.get::<_, Option<String>>(0))? {
        match r? {
            Some(v) => out.push(v),
            None if unknown => out.push("unknown".into()),
            _ => (),
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}
/// Group metadata in one SQL pass, preserving the existing distinct/null semantics.
fn group_metadata(store: &Store, filter: &QueryFilter) -> Result<Value> {
    let (where_sql, args) = predicate(filter);
    let mut statement = store.db.prepare(&format!(
        "SELECT model,agent_id,project_id,max(timestamp) FROM usage_events WHERE {where_sql} GROUP BY model,agent_id,project_id"
    ))?;
    let mut rows = statement.query(params_from_iter(args))?;
    let mut models = std::collections::BTreeSet::new();
    let mut agents = std::collections::BTreeSet::new();
    let mut projects = std::collections::BTreeSet::new();
    let mut last: Option<f64> = None;
    while let Some(row) = rows.next()? {
        if let Some(value) = row.get::<_, Option<String>>(0)? {
            models.insert(value);
        }
        if let Some(value) = row.get::<_, Option<String>>(1)? {
            agents.insert(value);
        }
        if let Some(value) = row.get::<_, Option<String>>(2)? {
            projects.insert(value);
        }
        if let Some(value) = row.get::<_, Option<f64>>(3)? {
            last = Some(last.map_or(value, |old| old.max(value)));
        }
    }
    Ok(
        json!({"models":models,"agentIDs":agents,"projectIDs":projects,
        "lastActivity":last.map(|t|iso(DateTime::from_timestamp_millis((t*1000.).round() as i64).unwrap()))}),
    )
}
pub fn groups(store: &Store, dim: &str, f: &QueryFilter, now: DateTime<Utc>) -> Result<Vec<Value>> {
    groups_in_snapshot(store, dim, f, now, None)
}
fn groups_in_snapshot(
    store: &Store,
    dim: &str,
    f: &QueryFilter,
    now: DateTime<Utc>,
    complete_summary: Option<&Value>,
) -> Result<Vec<Value>> {
    let col = match dim {
        "agents" => "agent_id",
        "models" => "model",
        "sessions" => "session_id",
        "projects" => "project_id",
        _ => return Err("INVALID_DIMENSION".into()),
    };
    let mut out = vec![];
    let ids = distinct(store, col, f, true)?;
    let singleton = ids.len() == 1;
    for id in ids {
        let mut q = f.clone();
        match dim {
            "agents" => q.agent = Some(id.clone()),
            "models" => q.model = Some(id.clone()),
            "sessions" => q.session = Some(id.clone()),
            _ => q.project = Some(id.clone()),
        };
        let metadata = group_metadata(store, &q)?;
        let name = if dim == "agents" {
            AGENTS
                .iter()
                .find(|x| x.0 == id)
                .map(|x| x.1)
                .unwrap_or(&id)
        } else {
            &id
        };
        out.push(json!({"id":id,"name":name,"lastActivity":metadata["lastActivity"],"models":metadata["models"],"agentIDs":metadata["agentIDs"],"projectIDs":metadata["projectIDs"],"summary":if singleton { if let Some(value)=complete_summary {value.clone()} else {serde_json::to_value(store.summary_sql(&q,now)?)?} } else { serde_json::to_value(store.summary_sql(&q,now)?)? }}));
    }
    out.sort_by(|a, b| {
        b["summary"]["metrics"]["total"]["value"]
            .as_i64()
            .cmp(&a["summary"]["metrics"]["total"]["value"].as_i64())
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
    });
    Ok(out)
}
pub fn timeline(
    store: &Store,
    f: &QueryFilter,
    tz: &str,
    now: DateTime<Utc>,
) -> Result<Vec<Value>> {
    let z = agentbar_core::aggregation::zone(tz)?;
    let (w, a) = predicate(f);
    let (first, last): (Option<f64>, Option<f64>) = store.db.query_row(
        &format!("SELECT min(timestamp),max(timestamp) FROM usage_events WHERE {w}"),
        params_from_iter(a),
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let at =
        |n: f64| DateTime::from_timestamp_millis((n * 1000.).round() as i64).ok_or("INVALID_RANGE");
    let start = f.start.map(at).transpose()?.unwrap_or(
        range_filter("today", at(first.unwrap_or(now.timestamp() as f64))?, tz)?
            .start
            .map(at)
            .transpose()?
            .unwrap(),
    );
    let end = f.end.map(at).transpose()?.unwrap_or(
        range_filter("today", at(last.unwrap_or(now.timestamp() as f64))?, tz)?
            .end
            .map(at)
            .transpose()?
            .unwrap(),
    );
    let days = (end - start).num_seconds() as f64 / 86400.;
    let estimated = if days <= 2. {
        days * 24.
    } else if days <= 62. {
        days
    } else if days <= 3660. {
        days / 28.
    } else {
        days / 365.
    };
    let step = (estimated / 240.).ceil().max(1.) as u32;
    let mut out = vec![];
    let mut date = start;
    while date < end && out.len() < 500 {
        let local = date.with_timezone(&z);
        let next = if days <= 2. {
            date + chrono::Duration::hours(step as i64)
        } else if days <= 62. {
            local
                .checked_add_days(Days::new(step as u64))
                .ok_or("CALENDAR_RANGE")?
                .with_timezone(&Utc)
        } else {
            local
                .checked_add_months(Months::new(if days <= 3660. { step } else { step * 12 }))
                .ok_or("CALENDAR_RANGE")?
                .with_timezone(&Utc)
        };
        let next = next.min(end);
        let mut q = f.clone();
        q.start = Some(date.timestamp_millis() as f64 / 1000.);
        q.end = Some(next.timestamp_millis() as f64 / 1000.);
        out.push(
            json!({"timestamp":iso(date),"end":iso(next),"summary":store.summary_sql(&q,now)?}),
        );
        date = next;
    }
    Ok(out)
}
pub fn query(
    store: &Store,
    path: &str,
    now: DateTime<Utc>,
    default_tz: &str,
    health: &Value,
    collectors: &Value,
) -> Result<Value> {
    // One GET observes one committed WAL snapshot, including all conditional reuse proofs.
    let snapshot = if store.db.is_autocommit() {
        Some(store.db.unchecked_transaction()?)
    } else {
        None
    };
    let result = query_in_snapshot(store, path, now, default_tz, health, collectors);
    drop(snapshot); // read transaction only; never migrations, writes, or checkpoints
    result
}
fn query_in_snapshot(
    store: &Store,
    path: &str,
    now: DateTime<Utc>,
    default_tz: &str,
    health: &Value,
    collectors: &Value,
) -> Result<Value> {
    if path.len() > 8192 {
        return Err("QUERY_TOO_LARGE".into());
    }
    let url = url::Url::parse(&format!("http://owned.invalid/{path}"))?;
    let q = url
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect::<BTreeMap<_, _>>();
    let f = filter(&q)?;
    let tz = q.get("tz").map(String::as_str).unwrap_or(default_tz);
    if ![
        "settings",
        "status",
        "host-health",
        "collectors",
        "filters",
        "token-survey",
    ]
    .contains(&url.path().trim_start_matches('/'))
    {
        agentbar_core::aggregation::zone(tz)?;
    }
    match url.path().trim_start_matches('/') {
        "settings" => settings(store),
        "host-health" => Ok(health.clone()),
        "collectors" => Ok(collectors.clone()),
        "status" => Ok(
            json!({"schemaVersion":7,"databasePath":health["databasePath"],"collecting":health["collector"]=="importing","timeZone":tz,"supportsNativeSettings":false}),
        ),
        "summary" => Ok(serde_json::to_value(store.summary_sql(&f, now)?)?),
        "popup" => {
            let today = range_filter("today", now, tz)?;
            let yesterday = range_filter("yesterday", now, tz)?;
            let mut response = json!({"today":store.summary_sql(&today,now)?,"yesterday":store.summary_sql(&yesterday,now)?,"timeZone":tz,
                "allTime":{"events":store.db.query_row("SELECT count(*) FROM usage_events",[],|row|row.get::<_,i64>(0))?},
                "agentDistribution":groups(store,"agents",&today,now)?,"health":health});
            if let (Some(a), Some(b)) = (
                response["today"]["metrics"]["total"]["value"].as_i64(),
                response["yesterday"]["metrics"]["total"]["value"].as_i64(),
            ) {
                if b > 0 {
                    response["changePercent"] = json!((a as f64 - b as f64) / b as f64 * 100.);
                }
            }
            Ok(response)
        }
        "overview" => {
            let mut base = f.clone();
            base.start = None;
            base.end = None;
            let (where_sql, args) = predicate(&base);
            let bounds: (Option<f64>, Option<f64>) = store.db.query_row(
                &format!(
                    "SELECT min(timestamp),max(timestamp) FROM usage_events WHERE {where_sql}"
                ),
                params_from_iter(args),
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            let covers_all = |scope: &QueryFilter| match bounds {
                (None, None) => true,
                (Some(min), Some(max)) => {
                    scope.start.is_none_or(|start| min >= start)
                        && scope.end.is_none_or(|end| max < end)
                }
                _ => false,
            };
            let full = serde_json::to_value(store.summary_sql(&base, now)?)?;
            let selected = if covers_all(&f) {
                full.clone()
            } else {
                serde_json::to_value(store.summary_sql(&f, now)?)?
            };
            let selected_key = serde_json::to_string(&f)?;
            let mut response = json!({"selected":selected,"timeZone":tz});
            for (r, k) in [
                ("today", "today"),
                ("7", "sevenDays"),
                ("30", "thirtyDays"),
                ("all", "allTime"),
                ("yesterday", "yesterday"),
            ] {
                let mut scope = range_filter(r, now, tz)?;
                scope.agent = f.agent.clone();
                scope.model = f.model.clone();
                scope.project = f.project.clone();
                scope.provider = f.provider.clone();
                scope.session = f.session.clone();
                response[k] = if covers_all(&scope) {
                    full.clone()
                } else if serde_json::to_string(&scope)? == selected_key {
                    response["selected"].clone()
                } else {
                    serde_json::to_value(store.summary_sql(&scope, now)?)?
                };
            }
            let a = response["today"]["metrics"]["total"]["value"].as_i64();
            let b = response["yesterday"]["metrics"]["total"]["value"].as_i64();
            if let (Some(a), Some(b)) = (a, b) {
                if b > 0 {
                    response["changePercent"] = json!((a as f64 - b as f64) / b as f64 * 100.)
                }
            }
            let gf = if url.path() == "/popup" {
                range_filter("today", now, tz)?
            } else {
                f.clone()
            };
            response["agentDistribution"] = json!(groups_in_snapshot(
                store,
                "agents",
                &gf,
                now,
                Some(&response["selected"])
            )?);
            if url.path() == "/overview" {
                response["modelDistribution"] = json!(groups_in_snapshot(
                    store,
                    "models",
                    &f,
                    now,
                    Some(&response["selected"])
                )?);
                response["timeline"] = json!(timeline(store, &f, tz, now)?)
            }
            response["health"] = health.clone();
            Ok(response)
        }
        "models" | "projects" | "sessions" => Ok(json!(groups(
            store,
            url.path().trim_start_matches('/'),
            &f,
            now
        )?)),
        "agents" => {
            let mut out = vec![];
            for (id, name) in AGENTS {
                let mut selected = f.clone();
                selected.agent = Some(id.into());
                let all = QueryFilter {
                    agent: Some(id.into()),
                    ..Default::default()
                };
                let mut today = range_filter("today", now, tz)?;
                today.agent = Some(id.into());
                let c = collectors
                    .as_array()
                    .and_then(|cs| cs.iter().find(|c| c["descriptor"]["agentID"] == id));
                out.push(json!({"id":id,"name":name,"detection":c.map(|c|c["detection"].clone()).unwrap_or(json!({"installed":false,"sourceAvailable":false,"evidence":["UNVERIFIED"]})),"collector":c,"summary":store.summary_sql(&selected,now)?,"today":store.summary_sql(&today,now)?,"allTime":store.summary_sql(&all,now)?,"models":distinct(store,"model",&all,false)?,"projects":distinct(store,"project_id",&all,false)?}));
            }
            Ok(json!(out))
        }
        "filters" => {
            let mut options = json!({});
            for (k, col) in [
                ("agents", "agent_id"),
                ("models", "model"),
                ("projects", "project_id"),
                ("providers", "provider"),
            ] {
                options[k]=json!(distinct(store,col,&QueryFilter::default(),true)?.iter().map(|id|json!({"id":id,"name":if k=="agents"{AGENTS.iter().find(|a|a.0==id).map(|a|a.1).unwrap_or(id)}else{id}})).collect::<Vec<_>>());
            }
            Ok(options)
        }
        "events" => {
            let limit = q
                .get("limit")
                .map(|s| s.parse::<usize>())
                .transpose()?
                .unwrap_or(100)
                .clamp(1, 200);
            let offset = q
                .get("offset")
                .map(|s| s.parse::<usize>())
                .transpose()?
                .unwrap_or(0)
                .min(i32::MAX as usize);
            let (w, mut a) = predicate(&f);
            let total: usize = store.db.query_row(
                &format!("SELECT count(*) FROM usage_events WHERE {w}"),
                params_from_iter(a.clone()),
                |r| r.get(0),
            )?;
            let sql = if let Some(id) = q.get("id") {
                a.push(Sql::Text(id.clone()));
                format!("SELECT event_json FROM usage_events WHERE {w} AND id=?")
            } else {
                a.push(Sql::Integer(limit as i64));
                a.push(Sql::Integer(offset as i64));
                format!("SELECT event_json FROM usage_events WHERE {w} ORDER BY timestamp DESC,id LIMIT ? OFFSET ?")
            };
            let mut s = store.db.prepare(&sql)?;
            let rows = s
                .query_map(params_from_iter(a), |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            let events = rows
                .iter()
                .map(|s| serde_json::from_str::<NormalizedUsageRecord>(s))
                .collect::<std::result::Result<Vec<_>, _>>()?;
            Ok(json!({"events":events,"total":total,"offset":offset,"limit":limit}))
        }
        "token-survey" => crate::survey::load(store, q.get("agent").ok_or("AGENT_REQUIRED")?),
        _ => Err("ENDPOINT_NOT_SUPPORTED".into()),
    }
}

/// Retained history is independent of this reconciliation's incremental counters.
pub fn coverage(store: &Store, agent: &str, status: &str, errors: &[&str]) -> Result<Value> {
    let (count, first, last): (i64, Option<f64>, Option<f64>) = store.db.query_row(
        "SELECT count(*),min(timestamp),max(timestamp) FROM usage_events WHERE agent_id=?",
        [agent],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let stamp = |value: Option<f64>| {
        value
            .and_then(|n| chrono::DateTime::from_timestamp_millis((n * 1000.).round() as i64))
            .map(iso)
    };
    let inspection = agent == "claude-desktop";
    let coverage_status = if status == "disabled" {
        "disabled"
    } else if inspection {
        "source_unverified"
    } else if status == "unavailable" {
        "source_unavailable"
    } else if status == "error" || status == "partial" {
        "partial"
    } else if count == 0 {
        "no_usage_yet"
    } else {
        "observed"
    };
    let scope = if inspection {
        "Claude Desktop chat and Cowork are metadata-inspection only; no Token source is verified"
    } else {
        "Collected local usage records"
    };
    let notes = if inspection {
        vec!["Installation and source discovery do not establish Token support", "Prompts, replies, credits and quotas are not imported"]
    } else {
        vec!["Collector health describes parsing, not complete history", "Deleted and remote history may be absent"]
    };
    Ok(json!({"status":coverage_status,"scope":scope,"records":count,"earliest":stamp(first),"latest":stamp(last),"completeHistoryVerified":false,"notes":notes,"errors":errors}))
}
