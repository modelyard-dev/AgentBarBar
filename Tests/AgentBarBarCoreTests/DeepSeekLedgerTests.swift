import XCTest
import CSQLite
@testable import AgentBarBarCore

final class DeepSeekLedgerTests: XCTestCase {
    private func setupLedger() throws -> (URL,FixtureDatabase,EventStore,DeepSeekLedgerCollector) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        let path=root.appendingPathComponent("dsh_token_usage_sidebar.sqlite").path
        let db=try FixtureDatabase(path:path)
        let fixture=try String(contentsOf:Bundle.module.url(forResource:"dsh-ledger-v4",withExtension:"sql",subdirectory:"Fixtures")!,encoding:.utf8)
        try db.execute(fixture)
        return(root,db,try EventStore(path:root.appendingPathComponent("agentbarbar.sqlite").path),DeepSeekLedgerCollector(roots:[path],home:root.path))
    }
    func testAuthoritativeLedgerSupersedesLogsAndPreservesSourceAndProjects() async throws {
        let (root,_,store,collector)=try setupLedger()
        var state=ParserState();state.sessionID="anonymous-session";state.cwd="/anonymous/project"
        var metrics=TokenMetrics();metrics.total=Metric(999)
        let context=ParseContext(agentID:"deepseek-harness",agentName:"DeepSeek Harness",collectorID:"dsh-local",path:"/anonymous/session",projects:ProjectDetector())
        let old=try context.event(timestamp:"2026-10-04T00:00:00Z",identity:"message:anonymous",metrics:metrics,state:state,parser:"old")
        _=try await store.commit(events:[old])
        let before=try Data(contentsOf:root.appendingPathComponent("dsh_token_usage_sidebar.sqlite"))
        let first=try await collector.collect(store:store);XCTAssertEqual(first.health.imported,2)
        let sum=try await store.summary(QueryFilter(agent:"deepseek-harness"))
        XCTAssertEqual(sum.events,2);XCTAssertEqual(sum.metrics["total"]?.value,410)
        XCTAssertEqual(sum.metrics["input"]?.value,370);XCTAssertEqual(sum.uncachedInput?.value,70)
        XCTAssertEqual(sum.metrics["reasoning"]?.value,8);XCTAssertEqual(sum.metrics["cacheWrite"]?.value,0)
        let events=try await store.events();XCTAssertTrue(events.events.allSatisfy{$0.workingDirectory=="/anonymous/project"})
        XCTAssertTrue(events.events.allSatisfy{$0.sourceType=="local_sqlite" && $0.sourceMetadata["canonical_id"] != nil})
        let unchanged=try await collector.collect(store:store);XCTAssertEqual(unchanged.health.bytesRead,0)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("dsh_token_usage_sidebar.sqlite")),before)
        let archiveDB=try FixtureDatabase(path:await store.path)
        let archive=try archiveDB.prepare("SELECT count(*) FROM superseded_usage_events")
        defer{sqlite3_finalize(archive)};XCTAssertEqual(sqlite3_step(archive),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(archive,0),1)
    }
    func testLedgerCorrectionExclusionBackdatedRecoveryAndRestart() async throws {
        let (_,db,store,collector)=try setupLedger();_=try await collector.collect(store:store)
        // An authoritative accounting correction can legitimately lower a completed total.
        try db.execute("UPDATE usage_records SET input_tokens=10,total_tokens=120,updated_at=3000,accounting_version=2 WHERE canonical_id='anonymous-session:1:1';UPDATE aggregate_global SET total_tokens=370;UPDATE meta SET record_generation=3,aggregate_generation=3")
        _=try await collector.collect(store:store)
        var sum=try await store.summary();XCTAssertEqual(sum.metrics["total"]?.value,370)
        try db.execute("UPDATE usage_records SET excluded_reason='duplicate',updated_at=4000 WHERE canonical_id='anonymous-session:1:2';UPDATE aggregate_global SET total_tokens=120,calls=1;UPDATE meta SET record_generation=4,aggregate_generation=4")
        _=try await collector.collect(store:store);sum=try await store.summary();XCTAssertEqual(sum.events,1);XCTAssertEqual(sum.metrics["total"]?.value,120)
        // Recovery can introduce a row whose updated time is behind the high-water mark.
        try db.execute("INSERT INTO usage_records VALUES('recovered:1:1','recovered',1791043200000,NULL,NULL,1,2,3,0,0,6,0,'legacy_store','historical',500,2,2,NULL);UPDATE aggregate_global SET total_tokens=126,calls=2;UPDATE meta SET record_generation=5,aggregate_generation=5")
        _=try await collector.collect(store:store);sum=try await store.summary();XCTAssertEqual(sum.events,2);XCTAssertEqual(sum.metrics["total"]?.value,126)
        let restart=DeepSeekLedgerCollector(roots:collector.descriptor.sourceRoots,home:"/anonymous")
        let restarted=try await restart.collect(store:store);XCTAssertEqual(restarted.health.bytesRead,0)
    }
    func testUnfinishedOrIncompatibleLedgerDoesNotReplaceTrustedData() async throws {
        let (_,db,store,collector)=try setupLedger();_=try await collector.collect(store:store)
        try db.execute("UPDATE meta SET storage_schema_version=99,record_generation=3,aggregate_generation=3")
        do {_=try await collector.collect(store:store);XCTFail("Unknown schema accepted")} catch {}
        let sum=try await store.summary();XCTAssertEqual(sum.events,2);XCTAssertEqual(sum.metrics["total"]?.value,410)
    }
}

private final class FixtureDatabase {
    private var handle:OpaquePointer?
    init(path:String) throws { guard sqlite3_open(path,&handle)==SQLITE_OK else {throw CoreError.database("Fixture open failed")} }
    deinit {sqlite3_close(handle)}
    func execute(_ sql:String) throws { guard sqlite3_exec(handle,sql,nil,nil,nil)==SQLITE_OK else {throw CoreError.database(String(cString:sqlite3_errmsg(handle)))} }
    func prepare(_ sql:String) throws -> OpaquePointer {var p:OpaquePointer?;guard sqlite3_prepare_v2(handle,sql,-1,&p,nil)==SQLITE_OK,let p else {throw CoreError.database("Fixture prepare failed")};return p}
}
