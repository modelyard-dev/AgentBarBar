import XCTest
@testable import AgentBarBarCore

final class DesktopCollectorTests:XCTestCase {
    private func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarBarDesktop-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private func fixture(_ name:String) throws -> Data {
        try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:nil,subdirectory:"Fixtures")!)
    }
    private func dsh(_ root:URL) -> ZstdJSONLCollector {
        let p=DeepSeekParserV1()
        let d=CollectorDescriptor(id:"dsh-local",agentID:"deepseek-harness",name:"DeepSeek Harness",version:"1.0.0",parserVersion:p.version,supportedAgentVersions:["fixture"],capabilities:[:],sourceRoots:[root.path],sourceDescription:"fixture")
        return ZstdJSONLCollector(descriptor:d,parser:p,rule:.init(id:"deepseek-harness",name:"DeepSeek Harness"),home:root.path)
    }
    func testWorkBuddyCountsRequestsAcrossToolAndMessageRecordsWithoutAddingCacheTwice() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let parser=WorkBuddyParserV1();var state=ParserState();var events:[UsageEvent]=[]
        for line in try fixture("workbuddy.jsonl").split(separator:10) {
            if let event=try parser.parse(Data(line),state:&state,context:.init(agentID:"workbuddy",agentName:"WorkBuddy",collectorID:"workbuddy-local",path:"fixture")){events.append(event)}
        }
        let committed=try await store.commit(events:events);XCTAssertEqual(committed.inserted,2);XCTAssertEqual(committed.duplicates,1)
        let sum=try await store.summary();XCTAssertEqual(sum.metrics["total"]?.value,1320);XCTAssertEqual(sum.metrics["input"]?.value,1200)
        XCTAssertEqual(events[0].metrics.reasoning.value,25);XCTAssertEqual(events[0].metrics.cacheWrite.state,.unsupported)
        XCTAssertNil(events[2].rawModelName);XCTAssertNil(events[2].metrics.cacheRead.value);XCTAssertNil(events[2].provider)
        XCTAssertEqual(events[0].sourceEventID,"workbuddy:message:anonymous-request-1")
        XCTAssertEqual(events[0].timestamp,"2026-10-03T21:00:01.000Z")
    }
    func testWorkBuddyRejectsMissingIdentityAndDoesNotPersistConversationOrCredits() throws {
        let parser=WorkBuddyParserV1();var state=ParserState()
        var row=try JSONSerialization.jsonObject(with:fixture("workbuddy.jsonl").split(separator:10)[0]) as! [String:Any]
        let context=ParseContext(agentID:"workbuddy",agentName:"WorkBuddy",collectorID:"workbuddy-local",path:"fixture")
        row["arguments"]="SECRET_CANARY";var pd=row["providerData"] as! [String:Any];pd["credit"]=123;pd["reasoning"]="SECRET_CANARY";row["providerData"]=pd
        let e=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        XCTAssertFalse(try Utilities.json(e).contains("SECRET_CANARY"));XCTAssertNil(e.cost)
        var raw=pd["rawUsage"] as! [String:Any];raw["completion_tokens_details"]=["reasoning_tokens":121];pd["rawUsage"]=raw;row["providerData"]=pd
        let inconsistent=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        XCTAssertEqual(inconsistent.metrics.reasoning.state,.unknown);XCTAssertNil(inconsistent.metrics.reasoning.value)
        XCTAssertEqual(inconsistent.sourceMetadata["reported_reasoning_tokens"],"121")
        pd.removeValue(forKey:"messageId");row["providerData"]=pd
        XCTAssertThrowsError(try parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
    }
    func testZstdIncrementalFramesPartialAppendRestartCopiesAndReadOnlySources() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let path=root.appendingPathComponent("session.v4.jsonl.zstd")
        let header=try fixture("dsh-frame-0.zstd"),one=try fixture("dsh-frame-1.zstd"),two=try fixture("dsh-frame-2.zstd")
        try (header+one).write(to:path);let collector=dsh(root)
        let first=try await collector.collect(store:store);XCTAssertEqual(first.health.imported,1);XCTAssertTrue(first.health.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf:path),header+one)
        let partial=header+one+two.prefix(two.count/2);try partial.write(to:path)
        let waiting=try await collector.collect(store:store);XCTAssertEqual(waiting.health.imported,0);XCTAssertTrue(waiting.health.errors.isEmpty)
        let imported=try await store.events();let sourcePath=try XCTUnwrap(imported.events.first?.sourcePath)
        let checkpoint=try await store.cursor(path:sourcePath);XCTAssertEqual(checkpoint?.offset,UInt64(header.count+one.count))
        let complete=header+one+two;try complete.write(to:path)
        let resumed=try await dsh(root).collect(store:store);XCTAssertEqual(resumed.health.imported,1);XCTAssertEqual(resumed.health.bytesRead,UInt64(two.count))
        let idle=try await dsh(root).collect(store:store);XCTAssertEqual(idle.health.bytesRead,0);XCTAssertEqual(idle.health.imported,0)
        try complete.write(to:root.appendingPathComponent("copied.jsonl.zstd"))
        let copy=try await collector.collect(store:store);XCTAssertEqual(copy.health.imported,0);XCTAssertEqual(copy.health.duplicates,2)
        let sum=try await store.summary();XCTAssertEqual(sum.events,2);XCTAssertEqual(sum.metrics["total"]?.value,1150)
        let events=try await store.events();let e=try XCTUnwrap(events.events.first)
        XCTAssertEqual(e.metrics.input.value,900);XCTAssertEqual(e.rawModelName,"provider/raw-model");XCTAssertEqual(e.metrics.reasoning.state,.unsupported)
        XCTAssertEqual(e.sourceMetadata["compression"],"zstd");XCTAssertEqual(e.sourceType,"local_zstd_jsonl")
    }
    func testZstdCorruptionIsVisibleAndDoesNotPreventOtherFiles() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        try Data("CORRUPT_FRAME_HEADER".utf8).write(to:root.appendingPathComponent("bad.jsonl.zstd"))
        try (fixture("dsh-frame-0.zstd")+fixture("dsh-frame-1.zstd")).write(to:root.appendingPathComponent("good.jsonl.zstd"))
        let result=try await dsh(root).collect(store:store);XCTAssertEqual(result.health.imported,1);XCTAssertEqual(result.health.status,"partial");XCTAssertFalse(result.health.errors.isEmpty)
        let repeatRun=try await dsh(root).collect(store:store);XCTAssertEqual(repeatRun.health.bytesRead,0);XCTAssertEqual(repeatRun.health.status,"partial")
    }
    func testDeepSeekVersionedEnvelopeAndMetadataWhitelist() throws {
        let parser=DeepSeekParserV1();var state=ParserState();let context=ParseContext(agentID:"deepseek-harness",agentName:"DeepSeek Harness",collectorID:"dsh-local",path:"fixture")
        let lines=try fixture("dsh-session.jsonl").split(separator:10)
        _=try parser.parse(Data(lines[0]),state:&state,context:context)
        var row=try JSONSerialization.jsonObject(with:Data(lines[1])) as! [String:Any]
        var payload=row["data"] as! [String:Any];var message=payload["message"] as! [String:Any]
        message["content"]="SECRET_CANARY";var source=message["source"] as! [String:Any]
        source["apiKey"]="SECRET_CANARY";message["source"]=source;payload["message"]=message;row["data"]=payload
        let event=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        XCTAssertFalse(try Utilities.json(event).contains("SECRET_CANARY"));XCTAssertNil(event.cost)
        XCTAssertEqual(event.sourceEventID,"deepseek-harness:response:anonymous-provider:anonymous-dsh-request-1")
        var header=try JSONSerialization.jsonObject(with:Data(lines[0])) as! [String:Any]
        header["version"]=3;_=try parser.parse(JSONSerialization.data(withJSONObject:header),state:&state,context:context)
        header["version"]=5;XCTAssertThrowsError(try parser.parse(JSONSerialization.data(withJSONObject:header),state:&state,context:context))
    }
    func testDeepSeekLegacyMissingCacheRemainsUnknownAndExplicitComponentsAreDerived() throws {
        let parser=DeepSeekParserV1();var state=ParserState();var events:[UsageEvent]=[]
        let context=ParseContext(agentID:"deepseek-harness",agentName:"DeepSeek Harness",collectorID:"dsh-local",path:"fixture")
        for line in try fixture("dsh-legacy.jsonl").split(separator:10) {
            if let event=try parser.parse(Data(line),state:&state,context:context){events.append(event)}
        }
        XCTAssertEqual(events.count,2);XCTAssertNil(events[0].metrics.input.value);XCTAssertEqual(events[0].metrics.total.state,.unknown)
        XCTAssertEqual(events[0].metrics.output.value,20);XCTAssertEqual(events[1].metrics.input.value,900);XCTAssertEqual(events[1].metrics.total.value,930)
        XCTAssertEqual(events[1].quality,"partial");XCTAssertFalse(events[1].isEstimated)
        XCTAssertTrue(state.warnings.contains{$0.contains("Unknown")})
        var header=try JSONSerialization.jsonObject(with:Data(fixture("dsh-legacy.jsonl").split(separator:10)[0])) as! [String:Any]
        header["version"]=3;_=try parser.parse(JSONSerialization.data(withJSONObject:header),state:&state,context:context)
        let legacyRows=try fixture("dsh-legacy.jsonl").split(separator:10)
        let mixed=try XCTUnwrap(parser.parse(Data(legacyRows[1]),state:&state,context:context))
        XCTAssertEqual(mixed.metrics.total.state,.unknown)
    }
}
