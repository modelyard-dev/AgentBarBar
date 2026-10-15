import XCTest
import CSQLite
@testable import AgentBarBarCore

final class CoverageAndCacheTests:XCTestCase {
    private func root() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarBarCoverage-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    func testGeminiSessionCountersSnapshotRestartAndMetadataOnly() async throws {
        let home=try root(),directory=home.appendingPathComponent(".gemini/tmp/project/chats")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original=try Data(contentsOf:Bundle.module.url(forResource:"gemini-session",withExtension:"json",subdirectory:"Fixtures")!)
        let path=directory.appendingPathComponent("session-fixture.json");try original.write(to:path)
        try Data("/anonymous/GeminiProject".utf8).write(to:directory.deletingLastPathComponent().appendingPathComponent(".project_root"))
        let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let collector=GeminiCollector(roots:[home.appendingPathComponent(".gemini/tmp").path],home:home.path)
        let first=try await collector.collect(store:store);XCTAssertEqual(first.health.imported,2);XCTAssertTrue(first.health.errors.isEmpty)
        let sum=try await store.summary();XCTAssertEqual(sum.metrics["total"]?.value,1420);XCTAssertEqual(sum.metrics["input"]?.value,1200);XCTAssertEqual(sum.metrics["output"]?.value,220)
        let second=try await GeminiCollector(roots:collector.descriptor.sourceRoots,home:home.path).collect(store:store)
        XCTAssertEqual(second.health.bytesRead,0);XCTAssertEqual(second.health.imported,0);XCTAssertEqual(try Data(contentsOf:path),original)
        var doc=try JSONSerialization.jsonObject(with:original) as! [String:Any];var messages=doc["messages"] as! [[String:Any]]
        messages[0]["content"]="SECRET_CANARY";messages[0]["thoughts"]="SECRET_CANARY";doc["messages"]=messages
        try JSONSerialization.data(withJSONObject:doc).write(to:path)
        _=try await collector.collect(store:store);let events=try await store.events()
        XCTAssertFalse(try Utilities.json(events).contains("SECRET_CANARY"));XCTAssertEqual(events.events.first?.workingDirectory,"/anonymous/GeminiProject")
    }
    private func varint(_ value:UInt64) -> Data {var value=value;var bytes=Data();repeat{let part=UInt8(value&127);value>>=7;bytes.append(part|(value>0 ? 128:0))}while value>0;return bytes}
    private func number(_ field:Int,_ value:UInt64) -> Data {varint(UInt64(field<<3))+varint(value)}
    private func message(_ field:Int,_ value:Data) -> Data {varint(UInt64(field<<3|2))+varint(UInt64(value.count))+value}
    private func text(_ field:Int,_ value:String) -> Data {message(field,Data(value.utf8))}
    private func source(_ path:String,_ operation:(OpaquePointer)->Void) throws {
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(path,&db),SQLITE_OK);defer{sqlite3_close(db)};operation(db!)
    }
    func testAntigravityVerifiedWireFieldsPendingRowsAndSourceReadOnly() async throws {
        let home=try root(),path=home.appendingPathComponent("anonymous-conversation.db").path
        let usage=number(2,100)+number(3,20)+number(5,800)+number(9,5)+number(10,15)+number(6,24)+text(11,"anonymous-generation")
        let stamp=number(1,1791115201)
        let chat=message(4,usage)+message(9,message(4,stamp))+text(19,"gemini/raw")+text(1,"SECRET_CANARY")
        let blob=message(1,chat)+message(2,Data([2]))+text(4,"anonymous-execution")+text(9,"SECRET_CANARY")
        try source(path){db in
            XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB); CREATE TABLE steps(idx INTEGER PRIMARY KEY,status INTEGER,metadata BLOB); INSERT INTO steps VALUES(2,2,NULL);",nil,nil,nil),SQLITE_OK)
            var s:OpaquePointer?;sqlite3_prepare_v2(db,"INSERT INTO gen_metadata VALUES(0,?)",-1,&s,nil)
            _=blob.withUnsafeBytes{sqlite3_bind_blob(s,1,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))};XCTAssertEqual(sqlite3_step(s),SQLITE_DONE);sqlite3_finalize(s)
        }
        let before=try Data(contentsOf:URL(fileURLWithPath:path));let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let collector=AntigravityCollector(agentID:"antigravity",name:"Antigravity",roots:[home.path],home:home.path)
        let pending=try await collector.collect(store:store);XCTAssertEqual(pending.health.imported,0);XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),before)
        try source(path){db in XCTAssertEqual(sqlite3_exec(db,"UPDATE steps SET status=3",nil,nil,nil),SQLITE_OK)}
        let finished=try await collector.collect(store:store);XCTAssertEqual(finished.health.imported,1);XCTAssertTrue(finished.health.errors.isEmpty)
        let page=try await store.events();let event=try XCTUnwrap(page.events.first)
        XCTAssertEqual(event.metrics.input.value,900);XCTAssertEqual(event.metrics.output.value,20);XCTAssertEqual(event.metrics.total.value,920);XCTAssertEqual(event.metrics.reasoning.value,5)
        XCTAssertEqual(event.rawModelName,"gemini/raw");XCTAssertFalse(try Utilities.json(event).contains("SECRET_CANARY"))
        let idle=try await collector.collect(store:store);XCTAssertEqual(idle.health.bytesRead,0);XCTAssertEqual(idle.health.imported,0)
        XCTAssertThrowsError(try ProtoMetadata(Data([10,255]),allowed:[1]))
    }
    func testSnapshotScopeEncodingPersistenceAndLiveOnlyExclusions() async throws {
        let root=try root(),path=root.appendingPathComponent("usage.sqlite").path
        let cache=DashboardSnapshotCache(databasePath:path)
        let key=DashboardSnapshotCache.key("/api/overview",items:[.init(name:"tz",value:"Asia/Shanghai"),.init(name:"agent",value:"agent-a")])
        XCTAssertEqual(key,"overview?agent=agent-a&tz=Asia%2FShanghai")
        let payload=Data("{\"tokens\":123}".utf8);await cache.record(key,body:payload,tag:"epoch:1")
        let fresh=await cache.fresh(key,tag:"epoch:1"),wrong=await cache.fresh(key,tag:"epoch:2")
        XCTAssertEqual(fresh,payload);XCTAssertNil(wrong)
        await cache.record("settings",body:Data("SECRET_CANARY".utf8),tag:"epoch:1")
        await cache.record("status",body:Data("SECRET_CANARY".utf8),tag:"epoch:1")
        let boot=try await cache.bootstrap(language:"zh-Hans");XCTAssertFalse(boot.contains("SECRET_CANARY"))
        try await Task.sleep(nanoseconds:1_200_000_000)
        let restarted=DashboardSnapshotCache(databasePath:path)
        let saved=try await restarted.bootstrap(language:"en");XCTAssertTrue(saved.contains(Data(payload).base64EncodedString()))
        let other=DashboardSnapshotCache(databasePath:root.appendingPathComponent("other.sqlite").path)
        let otherBoot=try await other.bootstrap(language:"en");XCTAssertFalse(otherBoot.contains(payload.base64EncodedString()))
    }
    func testInspectionAdapterNeverTurnsCreditsOrConversationTextIntoTokens() async throws {
        let home=try root(),logs=home.appendingPathComponent("logs");try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
        let file=logs.appendingPathComponent("main.log");try Data("credits=999999; SECRET_CANARY".utf8).write(to:file)
        let store=try EventStore(path:home.appendingPathComponent("usage.sqlite").path)
        let inspector=SourceInspectionCollector(rule:.init(id:"example",name:"Example"),roots:[logs.path],home:home.path)
        let result=try await inspector.collect(store:store);XCTAssertEqual(result.health.status,"no_token_records");XCTAssertEqual(result.health.imported,0)
        let summary=try await store.summary();XCTAssertEqual(summary.events,0);XCTAssertNil(summary.metrics["total"]?.value)
        let idle=try await inspector.collect(store:store);XCTAssertEqual(idle.health.bytesRead,0)
        XCTAssertFalse(try Utilities.json(result).contains("SECRET_CANARY"))
    }
}
