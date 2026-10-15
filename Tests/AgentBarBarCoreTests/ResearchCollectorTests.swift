import XCTest
@testable import AgentBarBarCore

final class ResearchCollectorTests: XCTestCase {
    private func root() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarBarResearch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:url)}
        return url
    }
    private func fixture(_ name:String) throws -> Data {
        try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:nil,subdirectory:"Fixtures")!)
    }
    func testQwenLedgerDedupRestartAndSourceIsReadOnly() async throws {
        let home=try root(),directory=home.appendingPathComponent(".qwen/usage")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original=try fixture("qwen-ledger-v1.jsonl"),path=directory.appendingPathComponent("token-usage-2026-10.jsonl")
        try original.write(to:path)
        // Arbitrary JSONL/chat records in an override must never be added.
        try Data("BROKEN\n".utf8).write(to:directory.appendingPathComponent("chat.jsonl"))
        let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let collector=QwenCollector.make(roots:[directory.path],home:home.path)
        let first=try await collector.collect(store:store)
        XCTAssertEqual(first.health.imported,2);XCTAssertTrue(first.health.errors.isEmpty)
        let idle=try await QwenCollector.make(roots:[directory.path],home:home.path).collect(store:store)
        XCTAssertEqual(idle.health.bytesRead,0)
        try original.write(to:directory.appendingPathComponent("token-usage-2026-09.jsonl"))
        _=try await collector.collect(store:store)
        let summary=try await store.summary()
        XCTAssertEqual(summary.events,2);XCTAssertEqual(summary.metrics["total"]?.value,125)
        XCTAssertEqual(summary.metrics["total"]?.state,.partial)
        XCTAssertEqual(summary.metrics["input"]?.value,100);XCTAssertEqual(summary.metrics["output"]?.value,25)
        let events=try await store.events()
        XCTAssertNil(events.events.first?.provider)
        XCTAssertTrue(events.events.contains{$0.sourceMetadata["localDate"]=="2026-10-05"})
        XCTAssertEqual(try Data(contentsOf:path),original)
    }
    func testQwenUnknownVersionInvalidNumbersMissingCountersAndPrivacy() throws {
        let parser=QwenLedgerParserV1(),context=ParseContext(agentID:"qwen",agentName:"Qwen Code",collectorID:"qwen-local",path:"fixture")
        var state=ParserState()
        var row=try JSONSerialization.jsonObject(with:Data(fixture("qwen-ledger-v1.jsonl").split(separator:10)[0])) as! [String:Any]
        row["prompt"]="SECRET_CANARY";row["source"]="SECRET_CANARY";row["apiKey"]="SECRET_CANARY"
        let event=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        XCTAssertFalse(try Utilities.json(event).contains("SECRET_CANARY"))
        row["schemaVersion"]=2
        XCTAssertThrowsError(try parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        row["schemaVersion"]=1;row["inputTokens"]=true
        XCTAssertThrowsError(try parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        row.removeValue(forKey:"inputTokens");row.removeValue(forKey:"thoughtsTokens")
        let missing=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        XCTAssertNil(missing.metrics.input.value);XCTAssertNil(missing.metrics.output.value)
        XCTAssertEqual(missing.metrics.reasoning.state,.notAvailable)
    }
    func testGeminiStreamMigrationRewindCheckpointPartialTailAndCorrection() async throws {
        let home=try root(),directory=home.appendingPathComponent(".gemini/tmp/project/chats")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original=try fixture("gemini-session-v2.jsonl"),path=directory.appendingPathComponent("session-fixture.jsonl")
        try original.write(to:path)
        try fixture("gemini-session.json").write(to:directory.appendingPathComponent("session-fixture.json"))
        let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let collector=GeminiCollector(roots:[home.appendingPathComponent(".gemini/tmp").path],home:home.path)
        let first=try await collector.collect(store:store)
        XCTAssertEqual(first.health.files,1);XCTAssertEqual(first.health.imported,2)
        XCTAssertTrue(first.health.errors.isEmpty)
        var summary=try await store.summary()
        XCTAssertEqual(summary.metrics["total"]?.value,1420)
        let events=try await store.events()
        let incomplete=try XCTUnwrap(events.events.first{$0.sourceEventID.hasSuffix("anonymous-gemini-2")})
        XCTAssertNil(incomplete.metrics.output.value) // no fabricated thoughts
        XCTAssertEqual(incomplete.sourceMetadata["rewind_records"],"1")
        XCTAssertEqual(incomplete.sourceLine,6)
        XCTAssertNil(incomplete.sourceMetadata["json_pointer"])
        let recorded=original.dropFirst(Int(incomplete.sourceOffset)).split(separator:10)[0]
        let sourceRow=try JSONSerialization.jsonObject(with:Data(recorded)) as! [String:Any]
        XCTAssertEqual(sourceRow["id"] as? String,"anonymous-gemini-2")
        let update=Data(#"{"id":"anonymous-gemini-1","type":"gemini","timestamp":"2026-10-04T12:00:01.000Z","tokens":{"input":100,"output":10,"thoughts":5,"cached":80,"total":115},"content":"SECRET_CANARY"}"#.utf8)
        try (original+update).write(to:path)
        _=try await collector.collect(store:store)
        summary=try await store.summary();XCTAssertEqual(summary.metrics["total"]?.value,1420)
        try (original+update+Data([10])).write(to:path)
        _=try await GeminiCollector(roots:collector.descriptor.sourceRoots,home:home.path).collect(store:store)
        summary=try await store.summary();XCTAssertEqual(summary.events,2);XCTAssertEqual(summary.metrics["total"]?.value,385)
        let retained=try await store.events()
        XCTAssertFalse(try Utilities.json(retained).contains("SECRET_CANARY"))
        let oldCopy=directory.appendingPathComponent("session-obsolete.json")
        try fixture("gemini-session.json").write(to:oldCopy)
        let copyRun=try await collector.collectChanges(store:store,paths:[oldCopy.path])
        XCTAssertTrue(copyRun.health.errors.isEmpty,copyRun.health.errors.description)
        XCTAssertEqual(copyRun.health.files,1)
        summary=try await store.summary();XCTAssertEqual(summary.metrics["total"]?.value,385)
        let idle=try await collector.collect(store:store);XCTAssertEqual(idle.health.bytesRead,0)
    }
    func testGeminiMalformedStreamDoesNotCommitPartialFile() async throws {
        let home=try root(),path=home.appendingPathComponent("session-test.jsonl")
        let original=try fixture("gemini-session-v2.jsonl")
        try (original+Data("BROKEN\n".utf8)).write(to:path)
        let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let collector=GeminiCollector(roots:[path.path],home:home.path)
        let result=try await collector.collect(store:store)
        XCTAssertEqual(result.health.status,"partial")
        let summary=try await store.summary();XCTAssertEqual(summary.events,0)
        XCTAssertEqual(try Data(contentsOf:path),original+Data("BROKEN\n".utf8))
    }
    func testQwenOverrideAndDisableSwitch() async throws {
        let home=try root(),store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        var settings=AppSettings();settings.sourceOverrides["qwen-local"]=[home.appendingPathComponent("ledger").path]
        settings.disabledCollectors=["qwen-local"]
        let engine=CollectorEngine(store:store,home:home.path)
        try await engine.configure(settings)
        let descriptors=try await store.collectors()
        let qwen=try XCTUnwrap(descriptors.first{$0.descriptor.id=="qwen-local"})
        XCTAssertEqual(qwen.health.status,"disabled");XCTAssertEqual(qwen.descriptor.sourceRoots,settings.sourceOverrides["qwen-local"])
    }
    func testClineLegacyRequestPairingMissingCacheAggregatesAndRewrite() async throws {
        let home=try root(),task=home.appendingPathComponent("tasks/anonymous-task")
        try FileManager.default.createDirectory(at:task,withIntermediateDirectories:true)
        let path=task.appendingPathComponent("ui_messages.json")
        var rows=try JSONSerialization.jsonObject(with:fixture("cline-task-ui-v1.json")) as! [[String:Any]]
        rows[0]["text"]="{\"tokensIn\":100,\"request\":\"SECRET_CANARY\"}"
        rows[3]["text"]="SECRET_CANARY"
        rows.append(["type":"say","say":"text","ts":1791244800004,"text":"SECRET_CANARY"])
        let original=try JSONSerialization.data(withJSONObject:rows);try original.write(to:path)
        let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let collector=ClineCollector(roots:[home.appendingPathComponent("tasks").path],home:home.path)
        let first=try await collector.collect(store:store)
        XCTAssertEqual(first.health.imported,2);XCTAssertEqual(first.health.status,"partial")
        var summary=try await store.summary()
        XCTAssertEqual(summary.metrics["total"]?.value,180)
        XCTAssertEqual(summary.metrics["input"]?.value,160)
        XCTAssertEqual(summary.metrics["output"]?.value,22)
        XCTAssertEqual(summary.metrics["total"]?.state,.partial)
        let events=try await store.events()
        XCTAssertFalse(try Utilities.json(events).contains("SECRET_CANARY"))
        XCTAssertTrue(events.events.allSatisfy{$0.model==nil && $0.project==nil})
        XCTAssertEqual(try Data(contentsOf:path),original)
        let idle=try await collector.collect(store:store)
        XCTAssertEqual(idle.health.bytesRead,0);XCTAssertEqual(idle.health.status,"partial")
        rows[1]["text"]="{\"tokensOut\":10,\"cacheReads\":5,\"cacheWrites\":1}"
        try JSONSerialization.data(withJSONObject:rows).write(to:path)
        _=try await collector.collect(store:store)
        summary=try await store.summary();XCTAssertEqual(summary.events,2);XCTAssertEqual(summary.metrics["total"]?.value,116)
    }

}
