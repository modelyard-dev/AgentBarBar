use crate::data;
use agentbar_core::{domain::NormalizedUsageRecord, storage::Store};
use serde_json::{json, Value};
#[test]
fn business_queries_use_real_rows_and_filter_pagination() {
    let mut store = Store::memory().unwrap();
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../Tests/Fixtures/Contracts/normalized-swift.json"
    ))
    .unwrap();
    let list = fixture
        .as_array()
        .or_else(|| fixture["events"].as_array())
        .unwrap();
    let events = list
        .iter()
        .map(|e| serde_json::from_value::<NormalizedUsageRecord>(e.clone()).unwrap())
        .collect::<Vec<_>>();
    store.commit(&events).unwrap();
    let now = agentbar_core::domain::timestamp("2026-10-05T12:00:00.000Z").unwrap();
    let q = |path: &str| {
        data::query(
            &store,
            path,
            now,
            "Asia/Shanghai",
            &json!({"collector":"running"}),
            &json!([]),
        )
        .unwrap()
    };
    let all = q("overview");
    assert_eq!(all["allTime"]["events"], events.len());
    assert!(!all["timeline"].as_array().unwrap().is_empty());
    let popup = q("popup");
    assert_eq!(popup["today"], all["today"]);
    assert_eq!(popup["yesterday"], all["yesterday"]);
    assert_eq!(popup["allTime"]["events"], events.len());
    assert!(popup.get("sevenDays").is_none());
    assert!(popup["allTime"].get("metrics").is_none());
    let page = q("events?limit=2&offset=1");
    assert_eq!(page["events"].as_array().unwrap().len(), 2);
    assert_eq!(page["total"], events.len());
    let codex = q("summary?agent=codex");
    assert_eq!(
        codex["events"],
        events.iter().filter(|e| e.agent_id == "codex").count()
    );
    assert!(q("filters")["agents"].as_array().unwrap().len() >= 3);
    assert!(data::query(&store,"settings",now,"UNVERIFIED_WINDOWS_TIME_ZONE",&json!({}),&json!([])).is_ok());
    assert!(data::query(&store,"overview",now,"UNVERIFIED_WINDOWS_TIME_ZONE",&json!({}),&json!([])).is_err());
    assert_eq!(q("agents").as_array().unwrap().len(), 12);
    assert!(data::query(&store, "../private", now, "UTC", &json!({}), &json!([])).is_err());
}
#[test]
fn settings_are_whitelisted_and_invalid_rejected() {
    let store = Store::memory().unwrap();
    let mut settings = data::defaults();
    settings["language"] = json!("zh-Hans");
    settings["arbitrarySecret"] = json!("not-to-be-saved");
    let saved = data::save_settings(&store, settings).unwrap();
    assert!(saved.get("arbitrarySecret").is_none());
    assert_eq!(data::settings(&store).unwrap()["language"], "zh-Hans");
    let mut invalid = data::defaults();
    invalid["dashboardTheme"] = json!("new-theme");
    assert!(data::save_settings(&store, invalid).is_err());
}

#[test]
fn overview_snapshot_reuse_matches_core_for_date_and_model_subsets() {
    use agentbar_core::{aggregation::{range_filter,QueryFilter},domain::hash};
    let raw:Value=serde_json::from_str(include_str!("../../../Tests/Fixtures/Contracts/normalized-swift.json")).unwrap();
    let list=raw.as_array().or_else(||raw["events"].as_array()).unwrap();
    let prototype:NormalizedUsageRecord=serde_json::from_value(list.iter().find(|e|e["agentID"]=="codex").unwrap().clone()).unwrap();
    let mut store=Store::memory().unwrap();
    let dates=["2026-10-05T04:00:00.000Z","2026-10-04T04:00:00.000Z","2026-09-29T04:00:00.000Z","2026-09-28T04:00:00.000Z","2026-09-06T04:00:00.000Z","2026-09-05T04:00:00.000Z"];
    let mut events=dates.iter().enumerate().map(|(i,date)|{
        let mut event=prototype.clone();event.source_event_id=format!("codex:snapshot-test:{i}");event.id=hash(&event.source_event_id);event.fingerprint=event.id.clone();event.timestamp=(*date).into();
        event.raw_model_name=if i==0 {None}else if i==1 {Some("unknown".into())}else {Some("model-a".into())};event.model=event.raw_model_name.clone();event
    }).collect::<Vec<_>>();
    let other:NormalizedUsageRecord=serde_json::from_value(list.iter().find(|e|e["agentID"]=="claude-code").unwrap().clone()).unwrap();
    for (i,date) in dates.iter().take(2).enumerate(){let mut event=other.clone();event.source_event_id=format!("claude-code:snapshot-test:{i}");event.id=hash(&event.source_event_id);event.fingerprint=event.id.clone();event.timestamp=(*date).into();event.raw_model_name=Some("model-a".into());event.model=event.raw_model_name.clone();events.push(event);}
    store.commit(&events).unwrap();
    let now=agentbar_core::domain::timestamp("2026-10-05T12:00:00.000Z").unwrap();
    for agent in [None,Some("codex"),Some("claude-code"),Some("absent-agent")] {
    for model in [None,Some("unknown"),Some("model-a")] {
        for range in ["today","7","30","all","yesterday"] {
            let mut filter=range_filter(range,now,"Asia/Shanghai").unwrap();filter.model=model.map(str::to_owned);filter.agent=agent.map(str::to_owned);
            let mut path=String::from("overview?tz=Asia/Shanghai");
            for (key,number) in [("start",filter.start),("end",filter.end)] {if let Some(number)=number {path.push_str(&format!("&{key}={}",agentbar_core::domain::iso(chrono::DateTime::from_timestamp_millis((number*1000.) as i64).unwrap())));}}
            if let Some(agent)=agent {path.push_str(&format!("&agent={agent}"));}
            if let Some(model)=model {path.push_str(&format!("&model={model}"));}
            let actual=data::query(&store,&path,now,"Asia/Shanghai",&json!({}),&json!([])).unwrap();
            assert!(store.db.is_autocommit());
            assert_eq!(actual["selected"],serde_json::to_value(store.summary_sql(&filter,now).unwrap()).unwrap());
            for (r,key) in [("today","today"),("7","sevenDays"),("30","thirtyDays"),("all","allTime"),("yesterday","yesterday")] {
                let mut scope=range_filter(r,now,"Asia/Shanghai").unwrap();scope.model=filter.model.clone();scope.agent=filter.agent.clone();
                assert_eq!(actual[key],serde_json::to_value(store.summary_sql(&scope,now).unwrap()).unwrap());
            }
            for (dimension,key,column) in [("agents","agentDistribution","agent"),("models","modelDistribution","model")] {
                for row in actual[key].as_array().unwrap() {
                    let mut scope=filter.clone();if column=="agent" {scope.agent=Some(row["id"].as_str().unwrap().into());}else {scope.model=Some(row["id"].as_str().unwrap().into());}
                    assert_eq!(row["summary"],serde_json::to_value(store.summary_sql(&scope,now).unwrap()).unwrap(),"{dimension}");
                    // Compare to the original separate metadata queries, including NULL/literal unknown.
                    for (key,col) in [("models","model"),("agentIDs","agent_id"),("projectIDs","project_id")] {
                        assert_eq!(row[key],json!(data::distinct(&store,col,&scope,false).unwrap()),"{dimension} {key}");
                    }
                    let (where_sql,args)=data::predicate(&scope);
                    let last:Option<f64>=store.db.query_row(&format!("SELECT max(timestamp) FROM usage_events WHERE {where_sql}"),rusqlite::params_from_iter(args),|r|r.get(0)).unwrap();
                    assert_eq!(row["lastActivity"],json!(last.map(|t|agentbar_core::domain::iso(chrono::DateTime::from_timestamp_millis((t*1000.).round() as i64).unwrap()))));
                }
            }
        }
    }
    }
    assert_eq!(store.summary_sql(&QueryFilter::default(),now).unwrap().events,8);
}

#[test]
fn settings_enable_and_override_every_registered_collector() {
    let store=Store::memory().unwrap();
    let temp=tempfile::tempdir().unwrap();
    let root=temp.path().canonicalize().unwrap().join("anonymous-source");
    std::fs::create_dir(&root).unwrap();
    for (agent,_) in data::AGENTS {
        let mut prefs=data::defaults();
        prefs["disabledCollectors"]=json!([agent]);
        prefs["sourceOverrides"]=json!({agent:[root.to_string_lossy()]});
        let saved=data::save_settings(&store,prefs).unwrap();
        assert_eq!(saved["disabledCollectors"],json!([agent]));
    }
    assert!(data::supported_agent("claude-desktop"));
    assert!(!data::AGENTS.iter().any(|(id,_)| *id=="claude-desktop"));
    let mut inspection=data::defaults();
    inspection["disabledCollectors"]=json!(["claude-desktop"]);
    inspection["sourceOverrides"]=json!({"claude-desktop":[root.to_string_lossy()]});
    let saved=data::save_settings(&store,inspection).unwrap();
    assert_eq!(saved["disabledCollectors"],json!(["claude-desktop"]));
    assert_eq!(data::capabilities("claude-desktop")["total"],"unsupported");
}

#[test]
fn new_collector_capabilities_keep_unavailable_attribution_explicit() {
    let qwen=data::capabilities("qwen");
    assert_eq!(qwen["input"],"conditional");
    assert_eq!(qwen["cacheWrite"],"unsupported");
    assert_eq!(qwen["project"],"unsupported");
    let cline=data::capabilities("cline");
    assert_eq!(cline["model"],"unsupported");
    assert_eq!(cline["project"],"unsupported");
    assert_eq!(cline["total"],"derived");
    assert_eq!(cline["reasoning"],"unsupported");
}
