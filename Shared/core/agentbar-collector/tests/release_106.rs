use agentbar_collector::{cli::open_owned, ingest::{self, Options}, locator::{NativeLocator,Profile,SourceLocator}};
use agentbar_core::{aggregation::{summarize,QueryFilter},domain::{timestamp,MetricState},storage::Store};
use std::{path::{Path,PathBuf},sync::atomic::AtomicBool};
struct Fixture { _temp: tempfile::TempDir, home:PathBuf, db:PathBuf }
impl Fixture {
    fn new()->Self {let temp=tempfile::tempdir().unwrap();let base=temp.path().canonicalize().unwrap();let home=base.join("home");std::fs::create_dir_all(&home).unwrap();Self{_temp:temp,home,db:base.join("owned/usage.sqlite")}}
    fn profile(&self)->Profile {Profile{home:self.home.clone(),appdata:Some(self.home.join("AppData/Roaming")),localappdata:None,codex_home:None,claude_config:None}}
    fn write(&self,path:&str,bytes:&[u8])->PathBuf {let p=self.home.join(path);std::fs::create_dir_all(p.parent().unwrap()).unwrap();std::fs::write(&p,bytes).unwrap();p}
    fn collect(&self,store:&mut Store,agent:&str)->Vec<ingest::SourceResult> {
        let mut locator=NativeLocator::new(self.profile());locator.probe=false;
        let cancel=AtomicBool::new(false);let discovery=locator.discover(agent,&[],&cancel).unwrap();
        discovery.sources.iter().map(|s|ingest::collect_source(store,s,&Options::default(),&cancel,&Default::default()).unwrap()).collect()
    }
}
fn fixture(name:&str)->Vec<u8> {std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Tests/AgentBarBarCoreTests/Fixtures").join(name)).unwrap()}
#[test]
fn qwen_swift_contract_restart_dedup_partial_and_readonly() {
    let f=Fixture::new();let original=fixture("qwen-ledger-v1.jsonl");
    let path=f.write(".qwen/usage/token-usage-2026-10.jsonl",&original);
    f.write(".qwen/usage/chat.jsonl",b"BROKEN\n");
    let mut store=open_owned(&f.db,&[]).unwrap();
    assert_eq!(f.collect(&mut store,"qwen")[0].metrics.records_inserted,2);
    drop(store);let mut store=open_owned(&f.db,&[]).unwrap();
    assert_eq!(f.collect(&mut store,"qwen")[0].metrics.bytes_read,0);
    f.write(".qwen/usage/token-usage-2026-09.jsonl",&original);f.collect(&mut store,"qwen");
    let summary=store.summary_sql(&QueryFilter::default(),chrono::Utc::now()).unwrap();
    assert_eq!(summary.events,2);assert_eq!(summary.metrics["total"].value,Some(125));
    assert_eq!(summary.metrics["input"].value,Some(100));assert_eq!(summary.metrics["output"].value,Some(25));
    assert_eq!(summary.metrics["total"].state,MetricState::Partial);
    let rows=store.events().unwrap();assert!(rows.iter().all(|e|e.provider.is_none()&&e.project.is_none()));
    assert_eq!(summarize(&rows,&QueryFilter::default(),chrono::Utc::now()).unwrap().metrics,summary.metrics);
    assert_eq!(std::fs::read(path).unwrap(),original);
}
#[test]
fn gemini_stream_matches_swift_migration_rewind_tail_correction_and_provenance() {
    let f=Fixture::new();let original=fixture("gemini-session-v2.jsonl");
    let path=f.write(".gemini/tmp/project/chats/session-fixture.jsonl",&original);
    f.write(".gemini/tmp/project/chats/session-fixture.json",&fixture("gemini-session.json"));
    let mut store=open_owned(&f.db,&[]).unwrap();let first=f.collect(&mut store,"gemini");assert_eq!(first.len(),1);
    assert_eq!(first[0].metrics.records_inserted,2);
    let rows=store.events().unwrap();let incomplete=rows.iter().find(|e|e.source_event_id.ends_with("anonymous-gemini-2")).unwrap();
    assert_eq!(incomplete.metrics["output"].value,None);assert_eq!(incomplete.source_line,6);
    assert!(!incomplete.source_metadata.contains_key("json_pointer"));
    let row:serde_json::Value=serde_json::from_slice(original[incomplete.source_offset as usize..].split(|b|*b==10).next().unwrap()).unwrap();
    assert_eq!(row["id"],"anonymous-gemini-2");
    assert_eq!(incomplete.source_metadata["rewind_records"],"1");
    let update=br#"{"id":"anonymous-gemini-1","type":"gemini","timestamp":"2026-10-04T12:00:01.000Z","tokens":{"input":100,"output":10,"thoughts":5,"cached":80,"total":115}}"#;
    let mut bytes=original.clone();bytes.extend(update);std::fs::write(&path,&bytes).unwrap();f.collect(&mut store,"gemini");
    assert_eq!(store.summary_sql(&QueryFilter::default(),chrono::Utc::now()).unwrap().metrics["total"].value,Some(1420));
    bytes.push(10);std::fs::write(&path,&bytes).unwrap();drop(store);let mut store=open_owned(&f.db,&[]).unwrap();f.collect(&mut store,"gemini");
    assert_eq!(store.summary_sql(&QueryFilter::default(),chrono::Utc::now()).unwrap().metrics["total"].value,Some(385));
    f.write(".gemini/tmp/project/chats/session-obsolete.json",&fixture("gemini-session.json"));f.collect(&mut store,"gemini");
    assert_eq!(store.summary_sql(&QueryFilter::default(),chrono::Utc::now()).unwrap().metrics["total"].value,Some(385));
    assert!(f.collect(&mut store,"gemini").iter().all(|r|r.metrics.bytes_read==0));assert_eq!(std::fs::read(path).unwrap(),bytes);
}
#[test]
fn gemini_malformed_completed_line_commits_nothing() {
    let f=Fixture::new();let mut bytes=fixture("gemini-session-v2.jsonl");bytes.extend(b"BROKEN\n");
    f.write(".gemini/tmp/p/chats/session-bad.jsonl",&bytes);let mut store=open_owned(&f.db,&[]).unwrap();
    let cancel=AtomicBool::new(false);let mut locator=NativeLocator::new(f.profile());locator.probe=false;
    let d=locator.discover("gemini",&[],&cancel).unwrap();
    assert!(ingest::collect_source(&mut store,&d.sources[0],&Options::default(),&cancel,&Default::default()).is_err());
    assert!(store.events().unwrap().is_empty());assert!(ingest::load(&store,&d.sources[0].source_id).unwrap().is_none());
}
#[test]
fn gemini_current_legacy_contract_and_nested_checkpoint_locations() {
    let f=Fixture::new();f.write(".gemini/tmp/p/chats/session-legacy.json",&fixture("gemini-session.json"));
    let mut store=open_owned(&f.db,&[]).unwrap();f.collect(&mut store,"gemini");
    let rows=store.events().unwrap();let first=rows.iter().find(|e|e.source_event_id.ends_with("anonymous-gemini-1")).unwrap();
    assert_eq!(first.parser_version,"gemini-session-json-v1.1.0");assert_eq!(first.metrics["input"].value,Some(1000));assert_eq!(first.metrics["output"].value,Some(150));assert_eq!(first.quality,"partial");
    let second=rows.iter().find(|e|e.source_event_id.ends_with("anonymous-gemini-2")).unwrap();assert_eq!(second.metrics["output"].value,Some(70));assert_eq!(second.metrics["output"].state,MetricState::Partial);
    let session:serde_json::Value=serde_json::from_slice(&fixture("gemini-session.json")).unwrap();
    let set=serde_json::json!({"$set":{"sessionId":"anonymous-gemini-session","messages":session["messages"]}});
    let mut stream=serde_json::to_vec(&set).unwrap();stream.push(10);
    // A subsequent content-only checkpoint does not erase previously observed counters.
    stream.extend(b"{\"$set\":{\"messages\":[{\"id\":\"anonymous-gemini-1\",\"type\":\"gemini\"}]}}\n");
    f.write(".gemini/tmp/p/chats/session-checkpoint.jsonl",&stream);f.collect(&mut store,"gemini");
    let rows=store.events().unwrap();let first=rows.iter().find(|e|e.source_event_id.ends_with("anonymous-gemini-1")).unwrap();
    assert_eq!(first.source_line,1);assert_eq!(first.source_offset,0);assert_eq!(first.source_metadata["json_pointer"],"$set/messages/0");assert_eq!(first.metrics["total"].value,Some(1150));
}
#[test]
fn cline_finish_null_replaces_prior_counter_and_does_not_steal_next_finish() {
    let rows=serde_json::json!([
        {"type":"say","say":"api_req_started","ts":1791244800000i64,"text":"{\"tokensIn\":100,\"tokensOut\":20,\"cacheReads\":5,\"cacheWrites\":1}"},
        {"type":"say","say":"api_req_finished","text":"{\"tokensOut\":null}"},
        {"type":"say","say":"api_req_started","ts":1791244800002i64,"text":"{\"tokensIn\":10}"},
        {"type":"say","say":"api_req_started","ts":1791244800003i64,"text":"{\"tokensIn\":30}"},
        {"type":"say","say":"api_req_finished","text":"{\"tokensOut\":2,\"cacheReads\":0,\"cacheWrites\":0}"}
    ]);
    let events=agentbar_core::release_106::cline(&serde_json::to_vec(&rows).unwrap(),"anonymous-task",&agentbar_core::parser::ParseContext::fixture("cline","fixture")).unwrap().0;
    assert_eq!(events.len(),3);assert_eq!(events[0].metrics["output"].value,None);assert_eq!(events[0].metrics["total"].value,None);assert_eq!(events[1].metrics["total"].value,None);assert_eq!(events[2].metrics["total"].value,Some(32));
}
#[test]
fn cline_swift_contract_pairing_missing_cache_exclusions_and_downward_rewrite() {
    let f=Fixture::new();let original=fixture("cline-task-ui-v1.json");
    let path=f.write("AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/anonymous-task/ui_messages.json",&original);
    let mut store=open_owned(&f.db,&[]).unwrap();let first=f.collect(&mut store,"cline");assert_eq!(first[0].metrics.records_inserted,2);
    let summary=store.summary_sql(&QueryFilter::default(),chrono::Utc::now()).unwrap();
    assert_eq!(summary.metrics["input"].value,Some(160));assert_eq!(summary.metrics["output"].value,Some(22));assert_eq!(summary.metrics["total"].value,Some(180));assert_eq!(summary.metrics["total"].state,MetricState::Partial);
    assert!(!first[0].diagnostics.is_empty());assert_eq!(f.collect(&mut store,"cline")[0].metrics.bytes_read,0);
    let mut rows:serde_json::Value=serde_json::from_slice(&original).unwrap();rows[1]["text"]=serde_json::json!("{\"tokensOut\":10,\"cacheReads\":5,\"cacheWrites\":1}");
    std::fs::write(&path,serde_json::to_vec(&rows).unwrap()).unwrap();f.collect(&mut store,"cline");
    assert_eq!(store.summary_sql(&QueryFilter::default(),chrono::Utc::now()).unwrap().metrics["total"].value,Some(116));
    assert!(store.events().unwrap().iter().all(|e|e.raw_model_name.is_none()&&e.provider.is_none()&&e.project.is_none()));
}
#[test]
fn versioned_qwen_rejects_bad_counters_and_retains_no_payload() {
    use agentbar_core::parser::{adapter,ParseContext,ParserState,UsageAdapter};
    let first=fixture("qwen-ledger-v1.jsonl");let mut row:serde_json::Value=serde_json::from_slice(first.split(|b|*b==10).next().unwrap()).unwrap();
    let parser=adapter("qwen").unwrap();let context=ParseContext::fixture("qwen","fixture");let mut state=ParserState::default();
    row["source"]=serde_json::json!("anonymous-subagent");
    let e=parser.parse(&serde_json::to_vec(&row).unwrap(),&mut state,&context).unwrap().unwrap();assert_eq!(e.source_metadata["agent_scope"],"subagent");
    row["schemaVersion"]=serde_json::json!(2);assert!(parser.parse(&serde_json::to_vec(&row).unwrap(),&mut state,&context).is_err());
    row["schemaVersion"]=serde_json::json!(1);row["inputTokens"]=serde_json::json!(true);assert!(parser.parse(&serde_json::to_vec(&row).unwrap(),&mut state,&context).is_err());
    row.as_object_mut().unwrap().remove("inputTokens");row.as_object_mut().unwrap().remove("thoughtsTokens");
    let e=parser.parse(&serde_json::to_vec(&row).unwrap(),&mut state,&context).unwrap().unwrap();assert_eq!(e.metrics["input"].value,None);assert_eq!(e.metrics["output"].value,None);
    e.validate().unwrap();timestamp(&e.timestamp).unwrap();
}
