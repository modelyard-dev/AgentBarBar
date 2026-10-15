import XCTest
@testable import AgentBarBarCore

final class OptimizationTests:XCTestCase {
    func temporary() throws -> URL {let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root}
    func parse(_ rows:[String],parser:UsageParser) throws -> [UsageEvent] {
        var state=ParserState();var result:[UsageEvent]=[]
        for (i,line) in rows.enumerated() {if let e=try parser.parse(Data(line.utf8),state:&state,context:ParseContext(agentID:"codex",agentName:"Codex",collectorID:"codex-local",path:"/anonymous/rollout",line:i+1)){result.append(e)}}
        return result
    }
    func testCodexLogicalOwnerRootSessionAndResponsePairIdentity() throws {
        let rows=[#"{"type":"session_meta","timestamp":"2026-10-05T00:00:00Z","payload":{"id":"child","session_id":"root","forked_from_id":"parent","forked_from_ordinal_exclusive":10}}"#,
          #"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:01Z","ordinal":9,"payload":{"thread_id":"parent","session_id":"root","response_id":"shared","usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}"#,
          #"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:02Z","ordinal":10,"payload":{"thread_id":"child","session_id":"root","response_id":"shared","usage":{"input_tokens":18,"output_tokens":2,"total_tokens":20}}}"#]
        let events=try parse(rows,parser:CodexParserV1())
        XCTAssertEqual(events.count,2);XCTAssertNotEqual(events[0].sourceEventID,events[1].sourceEventID)
        XCTAssertEqual(events[0].sessionID,"parent");XCTAssertEqual(events[1].sessionID,"child")
        XCTAssertEqual(events[1].sourceMetadata["root_session_id"],"root")
        var owned=rows;owned[1]=owned[1].replacingOccurrences(of:"\"thread_id\":\"parent\"",with:"\"thread_id\":\"child\"")
        XCTAssertEqual(try parse(owned,parser:CodexParserV1()).count,1)
    }
    func testCopiedOwnerNeverInheritsCurrentThreadsModel() throws {
        let header=#"{"type":"session_meta","payload":{"id":"child","model_provider":"child-provider","cwd":"/anonymous/child"}}"#
        let current=#"{"type":"turn_context","payload":{"model":"child-model"}}"#
        let request=#"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:01Z","payload":{"thread_id":"parent","response_id":"parent-request","usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}"#
        let unknown=try parse([header,current,request],parser:CodexParserV1())[0]
        XCTAssertNil(unknown.rawModelName);XCTAssertNil(unknown.provider);XCTAssertNil(unknown.workingDirectory)
        let settings=#"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"parent","thread_settings":{"model":"parent-model","model_provider_id":"parent-provider","cwd":"/anonymous/parent"}}}"#
        let known=try parse([header,current,settings,request],parser:CodexParserV1())[0]
        XCTAssertEqual(known.rawModelName,"parent-model");XCTAssertEqual(known.provider,"parent-provider")
    }
    func testPiToolSummaryAndRawResponseModelNotCurrentAlias() throws {
        let data=try String(contentsOf:Bundle.module.url(forResource:"pi-tool-usage",withExtension:"jsonl",subdirectory:"Fixtures")!,encoding:.utf8)
        let events=try parse(data.split(separator:"\n").map(String.init),parser:PiParserV1())
        XCTAssertEqual(events.count,2);XCTAssertEqual(events[0].metrics.total.value,10)
        XCTAssertNil(events[0].rawModelName);XCTAssertEqual(events[0].sourceMetadata["usage_category"],"tool_summary")
        XCTAssertEqual(events[1].rawModelName,"raw-response-model");XCTAssertEqual(events[1].metrics.output.value,3);XCTAssertEqual(events[1].metrics.reasoning.value,1)
    }
    func testStagingKeepsOldSnapshotUntilAtomicSwitchAndArchivesMetadata() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let old=try parse([#"{"type":"session_meta","payload":{"id":"session"}}"#,#"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:01Z","payload":{"response_id":"old","usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}"#],parser:CodexParserV1())[0]
        _=try await store.commit(events:[old])
        var newer=old;newer.sourceEventID="codex:new";newer.id=Utilities.hash(newer.sourceEventID);newer.fingerprint=Utilities.hash(newer.sourceEventID);newer.metrics.total=Metric(20)
        let run=try await store.beginRun(collectorID:"codex-local");let cursor=SourceCursor(path:"/anonymous/rollout",identity:"fixture",parserVersion:"next")
        _=try await store.stageReplacement(run:run,events:[newer,newer],cursor:cursor)
        var sum=try await store.summary();XCTAssertEqual(sum.events,1);XCTAssertEqual(sum.metrics["total"]?.value,10)
        try await store.finishReplacement(run:run,agentID:"codex",collectorID:"codex-local",parserVersion:"next")
        sum=try await store.summary();XCTAssertEqual(sum.events,1);XCTAssertEqual(sum.metrics["total"]?.value,20)
        let adoption=try await store.setting("parser-adoption:codex",as:String.self);XCTAssertEqual(adoption,"next")
        let restoredCursor=try await store.cursor(path:cursor.path);XCTAssertEqual(restoredCursor?.parserVersion,"next")
    }
    func testParserUpgradeFailureRetainsExistingUsage() async throws {
        let root=try temporary();let sources=root.appendingPathComponent(".codex/sessions");try FileManager.default.createDirectory(at:sources,withIntermediateDirectories:true)
        let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        var old=try parse([#"{"type":"session_meta","payload":{"id":"session"}}"#,#"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:01Z","payload":{"response_id":"old","usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}"#],parser:CodexParserV1())[0];old.parserVersion="old-parser"
        _=try await store.commit(events:[old]);try Data("{\"type\":\"token_usage_record\",broken}\n".utf8).write(to:sources.appendingPathComponent("rollout-bad.jsonl"))
        let engine=CollectorEngine(store:store,home:root.path);try await engine.configure(AppSettings());let result=await engine.synchronize()
        XCTAssertTrue(result.first?.health.errors.contains("Parser upgrade paused; previous usage remains active")==true)
        let sum=try await store.summary();XCTAssertEqual(sum.metrics["total"]?.value,10)
        let adoption=try await store.setting("parser-adoption:codex",as:String.self);XCTAssertNil(adoption)
    }
    func testMissingSourceHistorySurvivesParserReplacement() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let old=try parse([#"{"type":"session_meta","payload":{"id":"session"}}"#,#"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:01Z","payload":{"response_id":"historical","usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}"#],parser:CodexParserV1())[0]
        _=try await store.commit(events:[old])
        let run=try await store.beginRun(collectorID:"codex-local")
        try await store.preserveMissingHistory(run:run,agentID:"codex")
        try await store.finishReplacement(run:run,agentID:"codex",collectorID:"codex-local",parserVersion:"next")
        let sum=try await store.summary();XCTAssertEqual(sum.events,1);XCTAssertEqual(sum.metrics["total"]?.value,10)
        let page=try await store.events();XCTAssertTrue(page.events.first?.sourceMetadata["coverage_notes"]?.contains("no longer present")==true)
    }
    func testInspectionFolderOverrideIsActuallyRespected() async throws {
        let root=try temporary();let custom=root.appendingPathComponent("explicit-source");try FileManager.default.createDirectory(at:custom,withIntermediateDirectories:true)
        let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        var settings=AppSettings();settings.sourceOverrides["doubao-inspection"]=[custom.path]
        let engine=CollectorEngine(store:store,home:root.path);try await engine.configure(settings)
        let collectors=try await store.collectors();XCTAssertEqual(collectors.first{$0.descriptor.id=="doubao-inspection"}?.descriptor.sourceRoots,[custom.path])
    }
    func testRestoredLegacyRequestDoesNotDoubleCount() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let event=try parse([#"{"type":"session_meta","payload":{"id":"session"}}"#,#"{"type":"token_usage_record","timestamp":"2026-10-05T00:00:01Z","payload":{"response_id":"restored","usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}"#],parser:CodexParserV1())[0]
        var old=event;old.sourceEventID="codex:response:restored";old.id=Utilities.hash(old.sourceEventID);old.fingerprint=old.id;old.sourceMetadata.removeValue(forKey:"response_id");old.sourceMetadata["coverage_notes"]="Previously collected source is no longer present; retained metadata is not reverified"
        _=try await store.commit(events:[old]);_=try await store.commit(events:[event])
        let sum=try await store.summary();XCTAssertEqual(sum.events,1);XCTAssertEqual(sum.metrics["total"]?.value,10)
    }
    func testHistoricalCacheIsSeparateNullableAndExcludesPrivateFields() throws {
        let root=try temporary();let path=root.appendingPathComponent("stats-cache.json")
        try Data(#"{"version":1,"lastComputedDate":"2026-05-28","totalSessions":78,"dailyModelTokens":[{"date":"2026-02-24"},{"date":"2026-05-26"}],"modelUsage":{"raw-model":{"inputTokens":12,"outputTokens":0}},"longestSession":{"sessionId":"ANONYMOUS_PRIVATE_CANARY"}}"#.utf8).write(to:path)
        let history=try ClaudeHistoricalUsageReader.read(path)
        XCTAssertEqual(history.reportedSessions,78);XCTAssertEqual(history.models.first?.output.value,0)
        XCTAssertNil(history.models.first?.cacheRead.value);XCTAssertEqual(history.models.first?.cacheRead.state,.unknown)
        XCTAssertFalse(try Utilities.json(history).contains("ANONYMOUS_PRIVATE_CANARY"))
        let descriptor=CollectorDescriptor(id:"claude-local",agentID:"claude-code",name:"Claude",version:"1",parserVersion:"1",supportedAgentVersions:[],capabilities:[:],sourceRoots:[],sourceDescription:"fixture")
        let coverage=SourceCoverage.make(descriptor:descriptor,health:CollectorHealth(),earliest:nil,latest:nil,records:0)
        XCTAssertFalse(coverage.completeHistoryVerified);XCTAssertEqual(coverage.status,"retained_records")
    }
    func testLocallyVerifiedClaudeCacheSchema3AndUnknownVersionRejection() throws {
        let root=try temporary();let project=root.appendingPathComponent(".claude/projects");try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let path=project.deletingLastPathComponent().appendingPathComponent("stats-cache.json")
        let fixture=try Data(contentsOf:Bundle.module.url(forResource:"claude-stats-v3",withExtension:"json",subdirectory:"Fixtures")!);try fixture.write(to:path)
        let descriptor=CollectorDescriptor(id:"claude-local",agentID:"claude-code",name:"Claude",version:"1",parserVersion:"1",supportedAgentVersions:[],capabilities:[:],sourceRoots:[project.path],sourceDescription:"fixture")
        let coverage=SourceCoverage.make(descriptor:descriptor,health:CollectorHealth(),earliest:"2026-07-01T00:00:00Z",latest:"2026-08-01T00:00:00Z",records:6)
        XCTAssertEqual(coverage.status,"historical_gap");XCTAssertEqual(coverage.historical?.reportedSessions,78);XCTAssertTrue(coverage.errors.isEmpty)
        try Data(String(decoding:fixture,as:UTF8.self).replacingOccurrences(of:#""version":3"#,with:#""version":99"#).utf8).write(to:path)
        XCTAssertThrowsError(try ClaudeHistoricalUsageReader.read(path))
    }
    func testTraceEvidenceIsMetadataOnlyAndNeverMerged() throws {
        let root=try temporary();let folder=root.appendingPathComponent("pid");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data(#"{"trace":{"traceId":"anonymous","sessionId":"session","totalTokens":100,"modelInfo":{"models":["raw-model"],"callCount":2}},"spans":[{"toolOutput":"ANONYMOUS_PRIVATE_CANARY"}]}"#.utf8).write(to:folder.appendingPathComponent("trace_fixture.json"))
        let evidence=try WorkBuddyTraceEvidence.read(root)
        XCTAssertEqual(evidence.samples.first?.totalTokens,100);XCTAssertEqual(evidence.samples.first?.callCount,2)
        XCTAssertFalse(evidence.mergedIntoTotals);XCTAssertFalse(try Utilities.json(evidence).contains("ANONYMOUS_PRIVATE_CANARY"))
    }
}
