import XCTest
import CSQLite
@testable import AgentBarBarCore

final class CoreTests:XCTestCase {
    func fixture(_ name:String) throws -> Data {
        try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:nil,subdirectory:"Fixtures")!)
    }
    func parse(_ name:String,_ parser:UsageParser,agent:String="codex") throws -> [UsageEvent] {
        var state=ParserState();var output:[UsageEvent]=[];var offset:UInt64=0
        for (i,line) in try fixture(name).split(separator:10).enumerated() {
            let context=ParseContext(agentID:agent,agentName:agent,collectorID:agent+"-local",path:"/anonymous/"+name,line:i+1,offset:offset)
            if let e=try parser.parse(Data(line),state:&state,context:context) {output.append(e)}
            offset += UInt64(line.count+1)
        };return output
    }
    func temporary() throws -> URL {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarBarTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:path)};return path
    }
    func store() throws -> EventStore {try EventStore(path:temporary().appendingPathComponent("usage.sqlite").path)}
    func testCodexRequestAndCumulativeNotDoubleCounted() throws {
        let events=try parse("codex-request.jsonl",CodexParserV1())
        XCTAssertEqual(events.count,2)
        XCTAssertEqual(events.compactMap{$0.metrics.total.value}.reduce(0,+),81465)
        XCTAssertEqual(events[1].metrics.input.value,44486)
        XCTAssertEqual(events[1].metrics.reasoning.value,252)
        XCTAssertEqual(events[1].rawModelName,"gpt-6.1-sol")
        XCTAssertEqual(events[1].project?.detectionMethod,"explicit_session_cwd")
        XCTAssertEqual(events[0].sourceMetadata["counting_method"],"request_usage")
    }
    func testCodexLegacyRepeatedSnapshotsAndDeltas() throws {
        let e=try parse("codex-legacy.jsonl",CodexParserV1())
        XCTAssertEqual(e.count,2);XCTAssertEqual(e[1].metrics.total.value,45263)
        XCTAssertEqual(e[1].metrics.cacheRead.value,35712)
        XCTAssertEqual(e[1].metrics.reasoning.value,252)
    }
    func testCodexForkInheritedHistoryAndDifferentCounterScope() throws {
        var rows=try fixture("codex-request.jsonl").split(separator:10).map{try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any]}
        var metadata=rows[0]["payload"] as! [String:Any];metadata["forked_from_id"]="parent-session";rows[0]["payload"]=metadata
        rows[2]["timestamp"]=rows[0]["timestamp"];rows[3]["timestamp"]=rows[0]["timestamp"]
        // First request and counter are copied context. Only the second is a new request.
        var state=ParserState();let parser=CodexParserV1();let ctx=ParseContext(agentID:"codex",agentName:"Codex",collectorID:"codex-local",path:"fixture")
        var events:[UsageEvent]=[]
        for row in rows {if let e=try parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:ctx){events.append(e)}}
        XCTAssertEqual(events.count,1);XCTAssertEqual(events[0].metrics.total.value,45263)
        var stale=rows[3];stale["timestamp"]="2026-10-04T09:00:00Z"
        XCTAssertNil(try parser.parse(JSONSerialization.data(withJSONObject:stale),state:&state,context:ctx))
    }
    func testCodexStaleLegacySnapshotKeepsHighWaterMark() throws {
        let rows=try fixture("codex-legacy.jsonl").split(separator:10)
        var state=ParserState();let parser=CodexParserV1();let ctx=ParseContext(agentID:"codex",agentName:"Codex",collectorID:"codex-local",path:"fixture")
        for row in rows {_=try parser.parse(Data(row),state:&state,context:ctx)}
        XCTAssertNil(try parser.parse(Data(rows[2]),state:&state,context:ctx))
        XCTAssertEqual(state.counters?["total_tokens"],81465);XCTAssertFalse(state.warnings.isEmpty)
    }
    func testCodexReorderedJSONKeysPreserveMetadataAndModel() throws {
        let rows=try fixture("codex-request.jsonl").split(separator:10)
        let parser=CodexParserV1();var state=ParserState();let ctx=ParseContext(agentID:"codex",agentName:"Codex",collectorID:"codex-local",path:"fixture")
        var header=try JSONSerialization.jsonObject(with:Data(rows[0])) as! [String:Any]
        var payload=header["payload"] as! [String:Any];payload["base_instructions"]=String(repeating:"excluded-content",count:1000);header["payload"]=payload
        _=try parser.parse(JSONSerialization.data(withJSONObject:header,options:.sortedKeys),state:&state,context:ctx)
        _=try parser.parse(Data(rows[1]),state:&state,context:ctx)
        let e=try XCTUnwrap(parser.parse(Data(rows[2]),state:&state,context:ctx))
        XCTAssertEqual(e.sessionID,"anonymous-codex-session");XCTAssertEqual(e.rawModelName,"gpt-6.1-sol")
        XCTAssertFalse(try Utilities.json(e).contains("excluded-content"))
    }
    func testCodexPartialBaselineDoesNotInventHistoricalAttribution() throws {
        var lines=try fixture("codex-legacy.jsonl").split(separator:10).map{try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any]}
        var obj=lines[2];var p=obj["payload"] as! [String:Any];var info=p["info"] as! [String:Any]
        info["last_token_usage"]=["input_tokens":100,"output_tokens":5,"total_tokens":105]
        p["info"]=info;obj["payload"]=p;lines[2]=obj
        var state=ParserState();let parser=CodexParserV1();let ctx=ParseContext(agentID:"codex",agentName:"Codex",collectorID:"codex-local",path:"fixture")
        for x in lines.prefix(2) {_=try parser.parse(JSONSerialization.data(withJSONObject:x),state:&state,context:ctx)}
        let e=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:obj),state:&state,context:ctx))
        XCTAssertEqual(e.metrics.total.value,105);XCTAssertEqual(e.quality,"partial");XCTAssertFalse(state.warnings.isEmpty)
    }
    func testClaudeNormalizationAndProviderUncertainty() throws {
        let e=try XCTUnwrap(parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code").first)
        XCTAssertEqual(e.metrics.total.value,28138);XCTAssertEqual(e.metrics.reasoning.value,0)
        XCTAssertNil(e.provider);XCTAssertEqual(e.rawModelName,"deepseek-v4-flash");XCTAssertNil(e.cost)
        var obj=try JSONSerialization.jsonObject(with:fixture("claude.jsonl")) as! [String:Any]
        var msg=obj["message"] as! [String:Any];var usage=msg["usage"] as! [String:Any]
        usage["cache_read_input_tokens"]=100;usage["cache_creation_input_tokens"]=20
        msg["usage"]=usage;obj["message"]=msg
        var state=ParserState();let m=try XCTUnwrap(ClaudeParserV1().parse(JSONSerialization.data(withJSONObject:obj),state:&state,context:ParseContext(agentID:"claude-code",agentName:"Claude Code",collectorID:"claude-local",path:"fixture")))
        XCTAssertEqual(m.metrics.input.value,28192);XCTAssertEqual(m.metrics.total.value,28258)
    }
    func testClaudeDesktopCodeEntrypointIsRetainedAsMetadata() throws {
        let events=try parse("claude-entrypoint-v1.jsonl",ClaudeParserV1(),agent:"claude-code")
        let event=try XCTUnwrap(events.first)
        XCTAssertEqual(events.count,1)
        XCTAssertEqual(event.sourceMetadata["entrypoint"],"claude-desktop")
        XCTAssertEqual(event.metrics.total.value,154)
        XCTAssertFalse(try Utilities.json(event).contains("prompt"))
    }
    func testPiNormalizationMissingReasoningAndErrorZeros() throws {
        let e=try XCTUnwrap(parse("pi.jsonl",PiParserV1(),agent:"pi").first)
        XCTAssertEqual(e.metrics.input.value,17153);XCTAssertEqual(e.metrics.total.value,17290)
        XCTAssertEqual(e.provider,"scnet");XCTAssertEqual(e.metrics.reasoning.value,0);XCTAssertNil(e.cost)
        let rows=try fixture("pi.jsonl").split(separator:10);let parser=PiParserV1();var state=ParserState()
        let ctx=ParseContext(agentID:"pi",agentName:"Pi",collectorID:"pi-local",path:"fixture")
        _=try parser.parse(Data(rows[0]),state:&state,context:ctx)
        var x=try JSONSerialization.jsonObject(with:Data(rows[1])) as! [String:Any]
        var msg=x["message"] as! [String:Any];msg["stopReason"]="error"
        msg["usage"]=["input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0];x["message"]=msg
        let errorEvent=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:x),state:&state,context:ctx))
        XCTAssertNil(errorEvent.metrics.total.value);XCTAssertEqual(errorEvent.metrics.total.state,.notAvailable)
        XCTAssertEqual(errorEvent.metrics.cachedOutput.state,.unsupported)
        x["version"]=4;x["type"]="session"
        XCTAssertThrowsError(try parser.parse(JSONSerialization.data(withJSONObject:x),state:&state,context:ctx))
    }
    func testInvalidCountersRejectedAndRawContentNotPersisted() throws {
        for value in [NSNumber(value:-1),NSNumber(value:true),NSNumber(value:1.5)] {
            XCTAssertThrowsError(try Utilities.token(["tokens":value],"tokens"))
        }
        XCTAssertEqual(try Utilities.token(["tokens":0],"tokens"),0)
        XCTAssertNil(try Utilities.token([:],"tokens"))
        var x=try JSONSerialization.jsonObject(with:fixture("claude.jsonl")) as! [String:Any]
        var m=x["message"] as! [String:Any];m["content"]="SECRET_PROMPT_CANARY";x["message"]=m
        var state=ParserState();let e=try ClaudeParserV1().parse(JSONSerialization.data(withJSONObject:x),state:&state,context:ParseContext(agentID:"claude-code",agentName:"Claude",collectorID:"claude-local",path:"fixture"))
        XCTAssertFalse(try Utilities.json(e).contains("SECRET_PROMPT_CANARY"))
    }
    func testDeduplicationReplayConcurrentAndStreamingUpsert() async throws {
        let db=try store();let events=try parse("codex-request.jsonl",CodexParserV1())
        async let a=db.commit(events:events);async let b=db.commit(events:events)
        let results=try await [a,b];XCTAssertEqual(results.reduce(0){$0+$1.inserted},2)
        var s=try await db.summary();XCTAssertEqual(s.metrics["total"]?.value,81465)
        var e=try XCTUnwrap(parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code").first)
        _=try await db.commit(events:[e]);e.metrics.output=Metric(100);e.metrics.total=Metric(28172)
        let update=try await db.commit(events:[e]);XCTAssertEqual(update.updated,1)
        let replay=try await db.commit(events:parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code"));XCTAssertEqual(replay.duplicates,1)
        s=try await db.summary(QueryFilter(agent:"claude-code"));XCTAssertEqual(s.events,1);XCTAssertEqual(s.metrics.totalValue,28172)
    }
    func testAggregationFiltersCoverageAndHalfOpenDates() async throws {
        let db=try store();var events=try parse("codex-request.jsonl",CodexParserV1())
        events[1].metrics.reasoning=Metric(state:.notAvailable)
        _=try await db.commit(events:events)
        let all=try await db.summary();XCTAssertEqual(all.metrics["reasoning"]?.value,0);XCTAssertEqual(all.metrics["reasoning"]?.state,.partial)
        let cut=Utilities.date(events[1].timestamp)!.timeIntervalSince1970
        let earlier=try await db.summary(QueryFilter(end:cut));XCTAssertEqual(earlier.events,1)
        let later=try await db.summary(QueryFilter(start:cut,agent:"codex",model:"gpt-6.1-sol",project:events[1].project?.id,provider:"openai",session:"anonymous-codex-session"))
        XCTAssertEqual(later.events,1);XCTAssertEqual(later.metrics["total"]?.value,45263)
        let other=try await db.summary(QueryFilter(model:"not-a-model"));XCTAssertNil(other.metrics["total"]?.value)
        let groups=try await db.groups("models",filter:QueryFilter());XCTAssertEqual(groups[0].name,"gpt-6.1-sol")
    }
    func testKnownAndUnknownFiltersPreserveNullBucketsAndLastActivity() async throws {
        let db=try store();var events=try parse("codex-request.jsonl",CodexParserV1())
        events[0].rawModelName=nil;events[0].provider=nil
        _=try await db.commit(events:events)
        let unknown=try await db.events(QueryFilter(agent:"codex",model:"unknown",provider:"unknown"))
        XCTAssertEqual(unknown.events.map(\.id),[events[0].id])
        let known=try await db.summary(QueryFilter(agent:"codex",model:events[1].rawModelName))
        XCTAssertEqual(known.events,1)
        let agents=try await db.agents(QueryFilter(agent:"codex"))
        XCTAssertEqual(agents.first?.lastSeen,events[1].timestamp)
        let absent=try await db.agents(QueryFilter(agent:"not-installed"));XCTAssertTrue(absent.isEmpty)
        let groups=try await db.groups("models",filter:QueryFilter(agent:"codex"))
        XCTAssertEqual(groups.first{$0.id=="unknown"}?.summary.events,1)
    }
    func testCursorAndEventsTransactionRollback() async throws {
        let db=try store();let e=try XCTUnwrap(parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code").first)
        var invalid=e;invalid.sourceEventID="different-identity";invalid.fingerprint="different-fingerprint"
        let cursor=SourceCursor(path:"test-file",identity:"file-inode",parserVersion:"v1")
        do {_=try await db.commit(events:[e,invalid],cursor:cursor,collectorID:"test");XCTFail("Expected ID conflict")}catch{}
        let sum=try await db.summary();let saved=try await db.cursor(path:"test-file")
        XCTAssertEqual(sum.events,0);XCTAssertNil(saved)
    }
    func testDatabaseMigrationAndFutureSchema() async throws {
        let root=try temporary();let path=root.appendingPathComponent("usage.sqlite").path
        let db=try EventStore(path:path);let v=try await db.migrationVersion();XCTAssertEqual(v,7)
        var raw:OpaquePointer?;XCTAssertEqual(sqlite3_open(path,&raw),SQLITE_OK)
        let drops=TokenMetrics.names.map{"ALTER TABLE usage_events DROP COLUMN \($0)_state;"}.joined()
        XCTAssertEqual(sqlite3_exec(raw,"DROP TABLE usage_staging; DROP TABLE cursor_staging; DROP TABLE superseded_usage_events; DROP INDEX usage_aggregation; DROP INDEX usage_provider; DROP INDEX cursor_collector; DROP INDEX run_collector; DROP INDEX usage_session_direct; \(drops) DELETE FROM schema_migrations WHERE version>=2; PRAGMA user_version=1;",nil,nil,nil),SQLITE_OK);sqlite3_close(raw)
        let migrated=try EventStore(path:path);let v2=try await migrated.migrationVersion();XCTAssertEqual(v2,7)
        XCTAssertEqual(sqlite3_open(path,&raw),SQLITE_OK);sqlite3_exec(raw,"PRAGMA user_version=99",nil,nil,nil);sqlite3_close(raw)
        XCTAssertThrowsError(try EventStore(path:path))
    }
    func testIncrementalAppendRestartPartialLineAndRewrite() async throws {
        let home=try temporary();let root=home.appendingPathComponent(".codex/sessions");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("rollout-fixture.jsonl");let rows=try fixture("codex-request.jsonl").split(separator:10)
        let initial=rows.prefix(4).reduce(into:Data()){d,line in d.append(contentsOf:line);d.append(10)};try initial.write(to:source)
        let db=try EventStore(path:home.appendingPathComponent("data/usage.sqlite").path)
        let engine=CollectorEngine(store:db,home:home.path);try await engine.configure(AppSettings())
        let first=await engine.synchronize();XCTAssertEqual(first[0].health.imported,1)
        let second=await engine.synchronize();XCTAssertEqual(second[0].health.bytesRead,0)
        let handle=try FileHandle(forWritingTo:source);try handle.seekToEnd();try handle.write(contentsOf:Data(rows[4]));try handle.close()
        _=await engine.synchronize();var sum=try await db.summary();XCTAssertEqual(sum.events,1)
        let append=try FileHandle(forWritingTo:source);try append.seekToEnd();try append.write(contentsOf:Data([10]));try append.close()
        _=await engine.synchronize();sum=try await db.summary();XCTAssertEqual(sum.events,2)
        let restarted=CollectorEngine(store:try EventStore(path:home.appendingPathComponent("data/usage.sqlite").path),home:home.path)
        try await restarted.configure(AppSettings());let replay=await restarted.synchronize();XCTAssertEqual(replay[0].health.bytesRead,0)
        try fixture("codex-request.jsonl").write(to:source,options:.atomic)
        _=await restarted.synchronize();sum=try await db.summary();XCTAssertEqual(sum.events,2);XCTAssertEqual(sum.metrics["total"]?.value,81465)
    }
    func testChangedPathCollectionDoesNotScanUnrelatedHistory() async throws {
        let home=try temporary();let root=home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let changed=root.appendingPathComponent("rollout-changed.jsonl")
        let other=root.appendingPathComponent("rollout-unrelated.jsonl")
        try fixture("codex-request.jsonl").write(to:changed)
        try Data("{\"type\":\"token_usage_record\",BROKEN}\n".utf8).write(to:other)
        let db=try EventStore(path:home.appendingPathComponent("data/usage.sqlite").path);let engine=CollectorEngine(store:db,home:home.path)
        try await engine.configure(AppSettings());let limited=await engine.synchronize(changedPaths:[changed.path])
        XCTAssertEqual(limited.count,1);XCTAssertEqual(limited[0].health.files,1);XCTAssertTrue(limited[0].health.errors.isEmpty)
        let full=await engine.synchronize();XCTAssertEqual(full[0].health.status,"partial")
        let total=try await db.summary();XCTAssertEqual(total.events,2)
    }
    func testCollectorErrorsIsolatedAndVisible() async throws {
        let home=try temporary();let root=home.appendingPathComponent(".codex/sessions");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("{\"type\":\"token_usage_record\",BROKEN}\n".utf8).write(to:root.appendingPathComponent("rollout-bad.jsonl"))
        try fixture("codex-request.jsonl").write(to:root.appendingPathComponent("rollout-good.jsonl"))
        let db=try EventStore(path:home.appendingPathComponent("data/usage.sqlite").path);let engine=CollectorEngine(store:db,home:home.path)
        try await engine.configure(AppSettings());let runs=await engine.synchronize()
        XCTAssertEqual(runs[0].health.status,"partial");XCTAssertFalse(runs[0].health.errors.isEmpty)
        let sum=try await db.summary();XCTAssertEqual(sum.events,2);XCTAssertEqual(Set(runs.map(\.collectorID)),Set(["codex-local","claude-local","pi-local","kimi-local","opencode-local","workbuddy-local","dsh-local","gemini-local","qwen-local","cline-local","antigravity-local","antigravity-ide-local"]))
        let second=await engine.synchronize();XCTAssertEqual(second[0].health.bytesRead,0);XCTAssertEqual(second[0].health.status,"partial");XCTAssertFalse(second[0].health.errors.isEmpty)
    }
    func testStreamingRevisionAtMidnightMovesDateAndKeepsOneRequest() async throws {
        let db=try store();var e=try XCTUnwrap(parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code").first)
        e.timestamp="2026-10-03T23:59:59.000Z";_=try await db.commit(events:[e])
        e.timestamp="2026-10-04T00:00:01.000Z";e.metrics.total=Metric(30000);_=try await db.commit(events:[e])
        let boundary=Utilities.date("2026-10-04T00:00:00Z")!.timeIntervalSince1970
        let before=try await db.summary(QueryFilter(end:boundary));let after=try await db.events(QueryFilter(start:boundary))
        XCTAssertEqual(before.events,0);XCTAssertEqual(after.total,1);XCTAssertEqual(after.events[0].timestamp,e.timestamp)
    }
    func testMixedCurrenciesAreNotAddedTogether() async throws {
        let db=try store();var e=try XCTUnwrap(parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code").first)
        e.cost=1;e.currency="USD";e.costState = .known
        var second=e;second.id="another";second.sourceEventID="another";second.fingerprint="another";second.cost=2;second.currency="EUR"
        _=try await db.commit(events:[e,second]);let total=try await db.summary()
        XCTAssertNil(total.cost);XCTAssertNil(total.currency);XCTAssertEqual(total.costKnownEvents,0)
    }
    func testAggregationPreservesUnsupportedUnknownAndKnownZero() async throws {
        let db=try store();var e=try XCTUnwrap(parse("claude.jsonl",ClaudeParserV1(),agent:"claude-code").first)
        e.metrics.input=Metric(state:.unsupported);e.metrics.reasoning=Metric(state:.unknown);e.metrics.cacheWrite=Metric(0)
        _=try await db.commit(events:[e]);let s=try await db.summary()
        XCTAssertEqual(s.metrics["input"]?.state,.unsupported);XCTAssertNil(s.metrics["input"]?.value)
        XCTAssertEqual(s.metrics["reasoning"]?.state,.unknown);XCTAssertEqual(s.metrics["cacheWrite"]?.value,0)
    }
    func testCustomTotalOnlyMappingAndNoArbitraryPathInference() throws {
        let custom=CustomAgent(id:"example",name:"Example",logDirectory:"/example/logs",mapping:["id":"request.id","timestamp":"created_at","model":"model_name","total":"usage.tokens"])
        try custom.validate();var state=ParserState()
        let data=Data(#"{"request":{"id":"r1"},"created_at":"2026-10-04T00:00:00Z","model_name":"local/raw-v1","usage":{"tokens":0},"tool_path":"/example/fake-project"}"#.utf8)
        let e=try XCTUnwrap(CustomJSONLParserV1(custom).parse(data,state:&state,context:ParseContext(agentID:"custom-example",agentName:"Example",collectorID:"custom-example",path:"fixture")))
        XCTAssertEqual(e.metrics.total.value,0);XCTAssertEqual(e.metrics.input.state,.unsupported);XCTAssertNil(e.project)
        XCTAssertThrowsError(try AppSettings.validateRoot(FileManager.default.homeDirectoryForCurrentUser.path))
    }
    func testDaylightSavingTimelineUsesCalendarBoundaries() async throws {
        let db=try store();let start=Utilities.date("2026-11-01T04:00:00Z")!.timeIntervalSince1970
        let end=Utilities.date("2026-11-02T05:00:00Z")!.timeIntervalSince1970
        let timeline=try await db.timeline(QueryFilter(start:start,end:end,timeZone:"America/New_York"))
        XCTAssertEqual(timeline.count,25)
    }
    func testLocalAPIAuthenticationFilteringAndOriginProtection() async throws {
        let root=try temporary();try Data("<html>AgentBarBar</html>".utf8).write(to:root.appendingPathComponent("index.html"))
        let db=try store();_=try await db.commit(events:parse("codex-request.jsonl",CodexParserV1()))
        let engine=CollectorEngine(store:db,home:root.path);try await engine.configure(AppSettings())
        let server=LocalAPIServer(store:db,engine:engine,dashboard:root);_=try await server.start();defer{server.stop()}
        let configuration=URLSessionConfiguration.ephemeral;configuration.httpShouldSetCookies=false
        let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
        func request(_ path:String,auth:Bool=true,origin:String?=nil,method:String="GET",host:String?=nil,body:Data?=nil) async throws -> (Data,Int) {
            var r=URLRequest(url:URL(string:server.baseURL+path)!);r.httpMethod=method;r.httpBody=body
            if auth {r.setValue("Bearer "+server.credential,forHTTPHeaderField:"Authorization")}
            if let origin {r.setValue(origin,forHTTPHeaderField:"Origin")};if let host {r.setValue(host,forHTTPHeaderField:"Host")}
            let (data,response)=try await session.data(for:r);return(data,(response as! HTTPURLResponse).statusCode)
        }
        let surveyBody=Data(#"{"agentID":"codex"}"#.utf8)
        let surveyUnauth=try await request("/api/token-survey",auth:false,method:"POST",body:surveyBody);XCTAssertEqual(surveyUnauth.1,401)
        let surveyCross=try await request("/api/token-survey",origin:"https://example.com",method:"POST",body:surveyBody);XCTAssertEqual(surveyCross.1,403)
        let survey=try await request("/api/token-survey",method:"POST",body:surveyBody);XCTAssertEqual(survey.1,200)
        XCTAssertEqual(try JSONDecoder().decode(TokenSourceSurvey.self,from:survey.0).agentID,"codex")
        let savedSurvey=try await request("/api/token-survey?agent=codex");XCTAssertEqual(savedSurvey.1,200)
        let unauth=try await request("/api/summary",auth:false);XCTAssertEqual(unauth.1,401)
        let ok=try await request("/api/summary?agent=codex");XCTAssertEqual(ok.1,200)
        let sum=try JSONDecoder().decode(UsageSummary.self,from:ok.0);XCTAssertEqual(sum.metrics["total"]?.value,81465)
        let filtered=try await request("/api/summary?model=unknown-model");XCTAssertEqual(try JSONDecoder().decode(UsageSummary.self,from:filtered.0).events,0)
        let cross=try await request("/api/sync",origin:"https://example.com",method:"POST");XCTAssertEqual(cross.1,403)
        let invalid=try await request("/api/summary?start=invalid");XCTAssertEqual(invalid.1,400)
        let host=try await request("/api/summary",host:"attacker.example");XCTAssertEqual(host.1,403)
        let html=try await request("/",auth:false);XCTAssertEqual(html.1,200)
        let trace=try await request("/api/events?limit=1");XCTAssertEqual(try JSONDecoder().decode(EventPage.self,from:trace.0).events.count,1)
    }
}

private extension Dictionary where Key==String,Value==MetricAggregate {
    var totalValue:Int64? {self["total"]?.value}
}
