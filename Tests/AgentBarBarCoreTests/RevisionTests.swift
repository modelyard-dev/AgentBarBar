import XCTest
import CSQLite
@testable import AgentBarBarCore

final class RevisionTests:XCTestCase {
    func testDiagnosticSeverityPreservesCoverageAndRealFailures() throws {
        var health = CollectorHealth()
        health.status = "partial"
        let history = "History baseline unavailable: first cumulative snapshot exceeds last request"
        health.errors = [history, history]
        XCTAssertEqual(health.diagnostics.count, 1)
        XCTAssertEqual(health.diagnostics.first?.severity, .info)
        XCTAssertEqual(health.presentationStatus, "history_partial")
        XCTAssertEqual(health.status, "partial")
        XCTAssertEqual(health.errors.count, 2)
        health.errors.append("OpenCode message anonymous: Invalid source counters: input; these components are Unknown")
        XCTAssertEqual(health.diagnostics.last?.severity, .warning)
        XCTAssertEqual(health.presentationStatus, "partial")
        health.errors.append("Permission denied: /anonymous/source")
        XCTAssertEqual(health.diagnostics.last?.severity, .error)
        XCTAssertEqual(CollectorDiagnostic.classify("Unexpected parser failure").severity, .error)
        let decoded = try JSONDecoder().decode(CollectorHealth.self, from: JSONEncoder().encode(health))
        XCTAssertEqual(decoded.errors, health.errors)
        let inspection = "Checked local log/schema metadata; no validated Token records. Conversation text, credits and quotas are not Token counts"
        XCTAssertEqual(CollectorDiagnostic.classify(inspection).severity, .info)
        XCTAssertNotEqual(Localizer("zh-Hans").diagnostic(inspection), inspection)
        XCTAssertEqual(Localizer("en").diagnostic(inspection), inspection)
    }
    func testTokenSurveyBoundariesPrivacyAndReadOnlySources() throws {
        let root = try temporary().resolvingSymlinksInPath()
        let source = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let path = source.appendingPathComponent("usage.json")
        let data = Data(#"{"usage":{"input_tokens":42,"output_tokens":7},"private_value":"ANONYMOUS_PRIVATE_CANARY"}"#.utf8)
        try data.write(to:path)
        try data.write(to:source.appendingPathComponent("auth.json"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try data.write(to:outside.appendingPathComponent("other.json"))
        try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("linked"),withDestinationURL:outside)
        let report = TokenSourceSurvey.inspect(agentID:"anonymous",roots:[source.path])
        XCTAssertEqual(report.findings.count,1)
        XCTAssertEqual(report.findings.first?.fields,["input_tokens","output_tokens"])
        XCTAssertEqual(report.collectionStatus,"not_collected")
        XCTAssertFalse(try Utilities.json(report).contains("ANONYMOUS_PRIVATE_CANARY"))
        XCTAssertEqual(try Data(contentsOf:path),data)
        XCTAssertFalse(report.findings.contains { $0.path.contains("auth") || $0.path.contains("linked") })
        XCTAssertTrue(TokenSourceSurvey.inspect(agentID:"anonymous",roots:[source.path],fileLimit:0).limited)
        XCTAssertTrue(TokenSourceSurvey.inspect(agentID:"anonymous",roots:["/"]).findings.isEmpty)
    }
    func testClaudeDesktopSurveyChecksIndexedDBMarkersWithoutValues() throws {
        let root = try temporary().resolvingSymlinksInPath()
        let support = root.appendingPathComponent("Library/Application Support/Claude")
        let indexed = support.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.leveldb")
        let local = support.appendingPathComponent("Local Storage/leveldb")
        try FileManager.default.createDirectory(at:indexed,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
        let source = indexed.appendingPathComponent("000001")
        try Data(#"{"inputTokens":42,"field_value_canary":"VALUE_SHOULD_NOT_PERSIST"}"#.utf8).write(to:source)
        try Data(#"{"outputTokens":7}"#.utf8).write(to:local.appendingPathComponent("000002.log"))
        let report = TokenSourceSurvey.inspect(agentID:"claude-desktop",roots:[support.path])
        XCTAssertEqual(report.findings.count,1)
        XCTAssertEqual(report.findings.first?.fields,["inputTokens"])
        XCTAssertFalse(try Utilities.json(report).contains("VALUE_SHOULD_NOT_PERSIST"))
        XCTAssertFalse(report.findings.contains { $0.path.contains("Local Storage") })
        XCTAssertEqual(try Data(contentsOf:source),Data(#"{"inputTokens":42,"field_value_canary":"VALUE_SHOULD_NOT_PERSIST"}"#.utf8))
    }
    func testSurveyPersistsCandidatesWithoutImportingUnknownUsage() async throws {
        let root = try temporary().resolvingSymlinksInPath()
        let source = root.appendingPathComponent("Library/Application Support/Doubao")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data(#"{"input_tokens":12,"output_tokens":4}"#.utf8).write(to:source.appendingPathComponent("usage.json"))
        let store = try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let engine = CollectorEngine(store:store,home:root.path)
        try await engine.configure(AppSettings())
        let report = try await engine.surveyTokenSources(agentID:"doubao")
        XCTAssertEqual(report.findings.count,1)
        let saved = try await store.setting("token-survey:doubao",as:TokenSourceSurvey.self)
        XCTAssertEqual(saved?.findings.first?.path,report.findings.first?.path)
        let summary = try await store.summary()
        XCTAssertEqual(summary.events,0)
        do { _ = try await engine.surveyTokenSources(agentID:"unknown-agent"); XCTFail("Unknown Agent accepted") } catch {}
    }
    func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentBarBarRevision-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    func testLanguageDefaultsPreserveExistingSettingsAndSources() throws {
        let old=Data(#"{"menuBarMode":"agents","port":56789,"reconciliationSeconds":240,"disabledCollectors":["pi-local"],"sourceOverrides":{"codex-local":["/anonymous/codex"]},"customAgents":[]}"#.utf8)
        var settings=try JSONDecoder().decode(AppSettings.self,from:old)
        XCTAssertEqual(settings.language,"system");XCTAssertEqual(settings.menuBarMode,"agents");XCTAssertEqual(settings.sourceOverrides["codex-local"],["/anonymous/codex"])
        let signature=settings.collectorConfiguration;settings.language="zh-Hans";XCTAssertEqual(settings.collectorConfiguration,signature)
        let roundTrip=try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings));XCTAssertEqual(roundTrip.language,"zh-Hans");_=try roundTrip.validated()
        settings.language="invalid";XCTAssertThrowsError(try settings.validated())
        XCTAssertEqual(Localizer("system",preferredLanguages:["zh-CN"]).text("Open Dashboard"),"打开仪表盘")
        XCTAssertEqual(Localizer("en",preferredLanguages:["zh-CN"]).text("Open Dashboard"),"Open Dashboard")
        XCTAssertEqual(Localizer("zh-Hans").text("gpt/raw-model"),"gpt/raw-model")
        XCTAssertEqual(Localizer("zh-Hans").text("source_unavailable"),"数据源不可用")
    }
    func testBundleIdentityRenamesNestedAppsAndFalsePositiveChatGPT() throws {
        let root=try temporary()
        func bundle(_ name:String,_ id:String) throws {
            let path=root.appendingPathComponent(name+"/Contents");try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":id,"CFBundleShortVersionString":"2.3.4"],format:.xml,options:0).write(to:path.appendingPathComponent("Info.plist"))
        }
        try bundle("Developer/Renamed.app","com.openai.codex");try bundle("ChatGPT Classic.app","com.openai.chat");try bundle("ChatGPT.app","com.apple.Safari.WebApp.fixture")
        let discovery=DiscoveryEngine(home:root.path,applicationRoots:[root.path],pathDirectories:[],extensionRoots:[],runningProcesses:[],npmRoots:[])
        let codex=discovery.detect(DiscoveryEngine.catalog.first{$0.id=="codex"}!)
        XCTAssertTrue(codex.installed);XCTAssertTrue(codex.applicationPath?.hasSuffix("Renamed.app")==true);XCTAssertEqual(codex.version,"2.3.4")
        let chat=discovery.detect(DiscoveryEngine.catalog.first{$0.id=="chatgpt"}!)
        XCTAssertTrue(chat.installed);XCTAssertTrue(chat.applicationPath?.hasSuffix("ChatGPT Classic.app")==true)
        XCTAssertFalse(discovery.detect(DiscoveryEngine.catalog.first{$0.id=="pi"}!).installed)
        let running=DiscoveryEngine(home:root.path,applicationRoots:[],pathDirectories:[],extensionRoots:[],runningProcesses:[root.path+"/Developer/Renamed.app/Contents/MacOS/Client"],npmRoots:[])
        XCTAssertTrue(running.detect(DiscoveryEngine.catalog.first{$0.id=="codex"}!).installed)
    }
    func testExtensionManifestsPackagesCustomProcessesAndConfigurationOnly() throws {
        let root=try temporary();let ext=root.appendingPathComponent("extensions/misleading-folder");try FileManager.default.createDirectory(at:ext,withIntermediateDirectories:true)
        try Data(#"{"publisher":"rooveterinaryinc","name":"roo-cline","version":"3.0.0"}"#.utf8).write(to:ext.appendingPathComponent("package.json"))
        let npm=root.appendingPathComponent("npm/@google/gemini-cli");try FileManager.default.createDirectory(at:npm,withIntermediateDirectories:true)
        try Data(#"{"name":"@google/gemini-cli","version":"1.2.3"}"#.utf8).write(to:npm.appendingPathComponent("package.json"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".copilot"),withIntermediateDirectories:true)
        let discovery=DiscoveryEngine(home:root.path,applicationRoots:[],pathDirectories:[],extensionRoots:[root.appendingPathComponent("extensions").path],runningProcesses:["/custom/MyAgent","/custom/claude-helper"],npmRoots:[root.appendingPathComponent("npm").path])
        XCTAssertTrue(discovery.detect(DiscoveryEngine.catalog.first{$0.id=="roo"}!).installed)
        XCTAssertEqual(discovery.detect(DiscoveryEngine.catalog.first{$0.id=="gemini"}!).version,"1.2.3")
        let copilot=discovery.detect(DiscoveryEngine.catalog.first{$0.id=="copilot"}!);XCTAssertFalse(copilot.installed);XCTAssertFalse(copilot.sourceAvailable);XCTAssertEqual(copilot.evidence.count,1)
        XCTAssertTrue(discovery.detect(.init(id:"custom",name:"Custom",processes:["MyAgent"])).installed)
        XCTAssertFalse(discovery.detect(DiscoveryEngine.catalog.first{$0.id=="claude-code"}!).installed)
    }
    func testDiscoveryOnlyAgentDoesNotInventZeroUsage() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        try await store.registerAgent(id:"workbuddy",name:"WorkBuddy",detection:.init(installed:true,evidence:["application: fixture"],sourceAvailable:false))
        let agents=try await store.agents();XCTAssertEqual(agents.count,1);XCTAssertNil(agents[0].summary.metrics["total"]?.value);XCTAssertEqual(agents[0].summary.metrics["total"]?.state,.unsupported)
    }
    func testCustomDiscoveryOnlyRequiresNoTokenDataAndCreatesNoCursor() async throws {
        let root=try temporary();let binary=root.appendingPathComponent("future-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:binary);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        var settings=AppSettings();settings.disabledCollectors=["codex-local","claude-local","pi-local","kimi-local","opencode-local","workbuddy-local","dsh-local","gemini-local","qwen-local","cline-local","antigravity-local","antigravity-ide-local"]
        settings.customAgents=[CustomAgent(id:"future",name:"Future Agent",executable:binary.path,logDirectory:"",mapping:[:],discoveryOnly:true)]
        _=try settings.validated()
        let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path);try await store.setSetting("app",value:settings)
        let engine=CollectorEngine(store:store,home:root.path);try await engine.configure(settings)
        let roots=await engine.sourceRoots();XCTAssertTrue(roots.isEmpty)
        _=await engine.synchronize();let agents=try await store.agents(QueryFilter(agent:"custom-future"))
        XCTAssertEqual(agents.count,1);XCTAssertTrue(agents[0].detection.installed);XCTAssertNil(agents[0].collector)
        XCTAssertEqual(agents[0].summary.metrics["total"]?.state,.unsupported);XCTAssertNil(agents[0].summary.metrics["total"]?.value)
        let count=try await store.cursorCount();XCTAssertEqual(count,0)
    }
    func testKimiUsageDedupMissingModelAndRealComponents() async throws {
        let root=try temporary();let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let parser=KimiParserV1(workDirectories:["project-hash":"/anonymous/ProjectK"]);var state=ParserState();var events:[UsageEvent]=[]
        let fixture=try Data(contentsOf:Bundle.module.url(forResource:"kimi-wire",withExtension:"jsonl",subdirectory:"Fixtures")!)
        for row in fixture.split(separator:10) {
            if let event=try parser.parse(Data(row),state:&state,context:.init(agentID:"kimi-cli",agentName:"Kimi CLI",collectorID:"kimi-local",path:"/anonymous/sessions/project-hash/session-k/wire.jsonl")){events.append(event)}
        }
        XCTAssertEqual(events.count,2);XCTAssertEqual(events[0].metrics.input.value,1520);XCTAssertEqual(events[0].metrics.total.value,1600);XCTAssertEqual(events[0].metrics.reasoning.state,.unsupported)
        XCTAssertNil(events[0].rawModelName);XCTAssertNil(events[0].provider);XCTAssertEqual(events[0].sessionID,"session-k");XCTAssertEqual(events[0].workingDirectory,"/anonymous/ProjectK")
        let committed=try await store.commit(events:events);XCTAssertEqual(committed.inserted,1);XCTAssertEqual(committed.duplicates,1)
        let invalid=Data(#"{"timestamp":1791061202,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":1,"output":1,"input_cache_read":0,"input_cache_creation":0}}}}"#.utf8)
        XCTAssertThrowsError(try parser.parse(invalid,state:&state,context:.init(agentID:"kimi-cli",agentName:"Kimi",collectorID:"kimi-local",path:"fixture")))
        XCTAssertThrowsError(try parser.parse(Data(#"{"type":"metadata","protocol_version":"2.0"}"#.utf8),state:&state,context:.init(agentID:"kimi-cli",agentName:"Kimi",collectorID:"kimi-local",path:"fixture")))
    }
    func testOpenCodeInvalidComponentRetainsReportedTotalWithUnknownBreakdown() throws {
        let parser=OpenCodeParserV1();var state=ParserState();let context=ParseContext(agentID:"opencode",agentName:"OpenCode",collectorID:"opencode-local",path:"fixture")
        let row: [String:Any]=["id":"negative-source-component","session_id":"session","role":"assistant","completed":1791061202000 as Int64,"tokens":["input":-143,"output":35,"reasoning":0,"total":15572,"cache":["read":15680,"write":0]]]
        let event=try XCTUnwrap(parser.parse(JSONSerialization.data(withJSONObject:row),state:&state,context:context))
        XCTAssertNil(event.metrics.input.value);XCTAssertEqual(event.metrics.input.state,.unknown);XCTAssertEqual(event.metrics.total.value,15572)
        XCTAssertEqual(event.quality,"partial");XCTAssertFalse(event.isEstimated);XCTAssertEqual(event.sourceMetadata["invalid_source_metrics"],"input")
        var bad=row;bad["completed"]=true;XCTAssertThrowsError(try parser.parse(JSONSerialization.data(withJSONObject:bad),state:&state,context:context))
    }
    func source(_ path:String,_ sql:String) throws {
        var handle:OpaquePointer?;XCTAssertEqual(sqlite3_open(path,&handle),SQLITE_OK);defer{sqlite3_close(handle)}
        guard sqlite3_exec(handle,sql,nil,nil,nil)==SQLITE_OK else{throw CoreError.invalid(String(cString:sqlite3_errmsg(handle)))}
    }
    func testOpenCodeReadOnlyCursorRestartFinalizationForkAndNormalization() async throws {
        let root=try temporary();let path=root.appendingPathComponent("opencode.db").path
        let fixture=try String(contentsOf:Bundle.module.url(forResource:"opencode",withExtension:"sql",subdirectory:"Fixtures")!,encoding:.utf8)
        try source(path,fixture)
        let original=try Data(contentsOf:URL(fileURLWithPath:path))
        let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path);let collector=OpenCodeCollector(roots:[root.path],home:root.path)
        let first=try await collector.collect(store:store);XCTAssertEqual(first.health.imported,1);XCTAssertTrue(first.health.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),original)
        let events=try await store.events();let e=try XCTUnwrap(events.events.first)
        XCTAssertEqual(e.metrics.input.value,1120);XCTAssertEqual(e.metrics.output.value,100);XCTAssertEqual(e.metrics.total.value,1220);XCTAssertEqual(e.sourceType,"local_sqlite");XCTAssertEqual(e.rawModelName,"provider/raw-model-1");XCTAssertNil(e.cost)
        let restarted=try await OpenCodeCollector(roots:[root.path],home:root.path).collect(store:store);XCTAssertEqual(restarted.health.bytesRead,0);XCTAssertEqual(restarted.health.imported,0)
        try source(path,"UPDATE message SET time_updated=1791061500000,data=json_set(data,'$.time.completed',1791061500000,'$.tokens.input',200,'$.tokens.output',50) WHERE id='open-inflight';")
        let finalized=try await collector.collect(store:store);XCTAssertEqual(finalized.health.imported,1)
        let sum=try await store.summary();XCTAssertEqual(sum.events,2);XCTAssertEqual(sum.metrics["total"]?.value,1470)
        let replay=try await collector.collect(store:store);XCTAssertEqual(replay.health.bytesRead,0)
    }
    func testOpenCodeMalformedRecordDoesNotBlockOtherRequestsAndHealthSurvivesRestart() async throws {
        let root=try temporary();let path=root.appendingPathComponent("opencode.db").path
        let fixture=try String(contentsOf:Bundle.module.url(forResource:"opencode",withExtension:"sql",subdirectory:"Fixtures")!,encoding:.utf8)
        try source(path,fixture+"INSERT INTO message VALUES('bad-row','anonymous-open-session',1791061600000,1791061600000,'{\"role\":\"assistant\",\"time\":{\"completed\":1791061600000},\"tokens\":{\"input\":-1}}');")
        let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let first=try await OpenCodeCollector(roots:[root.path],home:root.path).collect(store:store)
        XCTAssertEqual(first.health.imported,1);XCTAssertEqual(first.health.status,"partial");XCTAssertFalse(first.health.errors.isEmpty)
        let second=try await OpenCodeCollector(roots:[root.path],home:root.path).collect(store:store)
        XCTAssertEqual(second.health.bytesRead,0);XCTAssertEqual(second.health.status,"partial");XCTAssertFalse(second.health.errors.isEmpty)
    }
    func testOpenCodeUnknownSchemaReportsHealthWithoutData() async throws {
        let root=try temporary();try source(root.appendingPathComponent("opencode.db").path,"CREATE TABLE message(id TEXT); CREATE TABLE session(id TEXT);")
        let store=try EventStore(path:root.appendingPathComponent("usage.sqlite").path)
        let result=try await OpenCodeCollector(roots:[root.path],home:root.path).collect(store:store)
        XCTAssertEqual(result.health.status,"partial");XCTAssertTrue(result.health.errors.first?.contains("Parser incompatible")==true)
        let sum=try await store.summary();XCTAssertEqual(sum.events,0)
    }
}
