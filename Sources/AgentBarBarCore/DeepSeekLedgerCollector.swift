import Foundation
import CSQLite

/// DSH's own canonical accounting ledger includes recovered history absent from session logs.
public final class DeepSeekLedgerCollector: AgentCollector {
    public let descriptor: CollectorDescriptor
    private let home: String
    private var currentHealth = CollectorHealth()
    public init(roots: [String], home: String) {
        self.home = home
        descriptor = CollectorDescriptor(id:"dsh-local",agentID:"deepseek-harness",name:"DeepSeek Harness",version:"1.1.0",parserVersion:"dsh-canonical-ledger-v4.1.0",
            supportedAgentVersions:["Storage schema 4; record schemas 1–4; accounting versions 1–2"],
            capabilities:["input":.derived,"output":.supported,"total":.supported,"cacheRead":.supported,"cacheWrite":.supported,"cachedOutput":.unsupported,"reasoning":.supported,"model":.conditional,"session":.supported,"project":.conditional,"cost":.unsupported],
            sourceRoots:roots,sourceDescription:"DeepSeek Harness canonical SQLite Token ledger")
    }
    public func detect() async -> DetectionResult { await detect(using:DiscoveryEngine(home:home)) }
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult { discovery.detect(DiscoveryEngine.catalog.first{$0.id=="deepseek-harness"}!,sourceRoots:descriptor.sourceRoots) }
    public func health() async -> CollectorHealth { currentHealth }
    public func collect(store:EventStore) async throws -> CollectionResult {
        let run = try await store.beginRun(collectorID:descriptor.id)
        var health = CollectorHealth(); health.status="healthy"; health.compatibility="schema_verified_agent_version_unverified"
        // Never combine two copies of a canonical ledger or append session-log counts to it.
        guard descriptor.sourceRoots.count==1 else { throw CoreError.invalid("Choose one authoritative DeepSeek ledger") }
        let root=descriptor.sourceRoots[0]
        let path=root.hasSuffix(".sqlite") ? root : root+"/dsh_token_usage_sidebar.sqlite"
        if !FileManager.default.fileExists(atPath:path) {
            health.status="source_unavailable"
        } else {
            health.files=1
            let source=try ReadOnlySourceDatabase(path:path,label:"DeepSeek")
            let begin=try source.prepare("BEGIN"); defer{sqlite3_finalize(begin)}
            guard sqlite3_step(begin)==SQLITE_DONE else {throw source.error()}
            try source.verifyColumns("usage_records",required:["canonical_id","session_id","timestamp","provider","model","input_tokens","output_tokens","cache_read_tokens","cache_write_tokens","reasoning_tokens","total_tokens","unclassified","source_type","historical_or_live","updated_at","schema_version","accounting_version","excluded_reason"])
            let meta=try source.prepare("SELECT storage_schema_version,record_generation,aggregate_generation,migration_status FROM meta WHERE id=1")
            defer{sqlite3_finalize(meta)}
            guard sqlite3_step(meta)==SQLITE_ROW,sqlite3_column_int(meta,0)==4,source.string(meta,3)=="done",sqlite3_column_int64(meta,1)==sqlite3_column_int64(meta,2) else {throw CoreError.invalid("Parser incompatible: DeepSeek canonical ledger schema or unfinished accounting migration")}
            let generation=sqlite3_column_int64(meta,1)
            let attrs=try FileManager.default.attributesOfItem(atPath:path)
            let identity="\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
            var cursor=try await store.cursor(path:path) ?? SourceCursor(path:path,identity:identity,parserVersion:descriptor.parserVersion)
            if cursor.identity==identity,cursor.parserVersion==descriptor.parserVersion,cursor.state.counters?["record_generation"]==generation {
                let aggregate=try source.prepare("SELECT calls,total_tokens FROM aggregate_global WHERE id=1")
                defer{sqlite3_finalize(aggregate)}
                if sqlite3_step(aggregate)==SQLITE_ROW {
                    let own=try await store.basicUsage(agentID:descriptor.agentID)
                    health.reconciliation=Reconciliation(status:own.count==Int(sqlite3_column_int64(aggregate,0)) && own.total==sqlite3_column_int64(aggregate,1) ? "matched":"mismatch",checkedAt:Utilities.iso(),sourceCount:Int(sqlite3_column_int64(aggregate,0)),collectedCount:own.count,sourceTotal:sqlite3_column_int64(aggregate,1),collectedTotal:own.total,scope:"Current local accounting ledger")
                }
                health.lastCollection=Utilities.iso();currentHealth=health
                let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
            }
            let aggregate=try source.prepare("SELECT calls,total_tokens FROM aggregate_global WHERE id=1")
            defer{sqlite3_finalize(aggregate)}
            guard sqlite3_step(aggregate)==SQLITE_ROW else {throw CoreError.invalid("Parser incompatible: DeepSeek aggregate missing")}
            let count=Int(sqlite3_column_int64(aggregate,0)),total=sqlite3_column_int64(aggregate,1)
            let check=try source.prepare("SELECT COUNT(*),COALESCE(SUM(total_tokens),0) FROM usage_records WHERE excluded_reason IS NULL")
            defer{sqlite3_finalize(check)}
            guard sqlite3_step(check)==SQLITE_ROW,sqlite3_column_int64(check,0)==Int64(count),sqlite3_column_int64(check,1)==total else {throw CoreError.invalid("DeepSeek ledger records do not match the source aggregate")}
            let cwd=try await store.sessionWorkingDirectories(agentID:descriptor.agentID)
            var replace=cursor.identity != identity || cursor.parserVersion != descriptor.parserVersion || cursor.state.counters?["record_generation"]==nil || generation<(cursor.state.counters?["record_generation"] ?? 0) || count<Int(cursor.state.counters?["calls"] ?? 0)
            let projects=ProjectDetector()
            func read(since: UInt64) throws -> ([UsageEvent],[String],UInt64) {
                let p=try source.prepare("SELECT canonical_id,session_id,timestamp,provider,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,total_tokens,unclassified,source_type,historical_or_live,updated_at,schema_version,accounting_version,excluded_reason FROM usage_records WHERE updated_at>=? ORDER BY updated_at,canonical_id")
                defer{sqlite3_finalize(p)};sqlite3_bind_int64(p,1,Int64(min(since,UInt64(Int64.max))))
                var events:[UsageEvent]=[],removed:[String]=[];var offset=since;var code=sqlite3_step(p)
                while code==SQLITE_ROW {
                    guard let id=source.string(p,0),!id.isEmpty,let session=source.string(p,1),!session.isEmpty else {throw CoreError.invalid("Parser incompatible: DeepSeek ledger identity")}
                    let updated=sqlite3_column_int64(p,14)
                    guard updated>=0 else {throw CoreError.invalid("Parser incompatible: DeepSeek updated timestamp")}
                    offset=max(offset,UInt64(updated))
                    if source.string(p,17) != nil {removed.append(descriptor.agentID+":ledger:"+id);code=sqlite3_step(p);continue}
                    guard [1,2,3,4].contains(Int(sqlite3_column_int(p,15))),[1,2].contains(Int(sqlite3_column_int(p,16))) else {throw CoreError.invalid("Parser incompatible: DeepSeek record accounting version")}
                    var values:[Int64]=[]
                    for column:Int32 in 5...10 {guard sqlite3_column_type(p,column)==SQLITE_INTEGER,sqlite3_column_int64(p,column)>=0 else {throw CoreError.invalid("Invalid source counters: DeepSeek ledger")};values.append(sqlite3_column_int64(p,column))}
                    let unknown=sqlite3_column_int(p,11) != 0
                    let (readInput,o1)=values[0].addingReportingOverflow(values[2]);let (input,o2)=readInput.addingReportingOverflow(values[3]);let (sum,o3)=input.addingReportingOverflow(values[1])
                    guard !o1 && !o2 && !o3,unknown || (sum==values[5] && values[4]<=values[1]) else {throw CoreError.invalid("Invalid source counters: DeepSeek canonical components")}
                    var metrics=TokenMetrics();metrics.total=Metric(values[5])
                    if unknown {metrics.input=Metric(state:.unknown);metrics.output=Metric(state:.unknown);metrics.cacheRead=Metric(state:.unknown);metrics.cacheWrite=Metric(state:.unknown);metrics.reasoning=Metric(state:.unknown)}
                    else {metrics.input=Metric(input);metrics.output=Metric(values[1]);metrics.cacheRead=Metric(values[2]);metrics.cacheWrite=Metric(values[3]);metrics.reasoning=Metric(values[4])}
                    var state=ParserState();state.sessionID=session;state.model=source.string(p,4);state.provider=source.string(p,3);state.cwd=cwd[session]
                    let metadata=["canonical_id":id,"input_semantics":"normalized input includes cache reads and cache writes; source input is uncached","reported_uncached_input":String(values[0]),"reasoning_semantics":"included in output","source_record_type":source.string(p,12) ?? "unknown","historical_or_live":source.string(p,13) ?? "unknown","storage_schema_version":"4","accounting_version":String(sqlite3_column_int(p,16)),"counting_method":"dsh_canonical_ledger"]
                    let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,collectorVersion:descriptor.version,path:path,line:0,projects:projects)
                    var event=try context.event(timestamp:Utilities.iso(Date(timeIntervalSince1970:Double(sqlite3_column_int64(p,2))/1000)),identity:"ledger:"+id,metrics:metrics,state:state,parser:descriptor.parserVersion,metadata:metadata,partial:unknown)
                    event.sourceType="local_sqlite";events.append(event);health.bytesRead+=UInt64(try Utilities.json(metadata).utf8.count)
                    code=sqlite3_step(p)
                }
                guard code==SQLITE_DONE else {throw source.error()};return(events,removed,offset)
            }
            var batch=try read(since:replace ? 0:cursor.offset)
            func save() async throws -> CommitResult {
                cursor.offset=batch.2;cursor.identity=identity;cursor.parserVersion=descriptor.parserVersion;cursor.state.counters=["record_generation":generation,"calls":Int64(count)]
                return try await store.commit(events:batch.0,cursor:cursor,collectorID:descriptor.id,authoritativeAgent:descriptor.agentID,replaceAgent:replace,removedSourceIDs:batch.1,expectedCount:count,expectedTotal:total)
            }
            let result:CommitResult
            do {result=try await save()}
            catch let error as CoreError {
                guard !replace,error.localizedDescription.contains("Authoritative ledger reconciliation mismatch") else {throw error}
                // Backdated inserts or removed records require a fresh authoritative snapshot.
                replace=true;batch=try read(since:0);result=try await save()
            }
            health.imported=result.inserted;health.updated=result.updated;health.duplicates=result.duplicates
            health.reconciliation=Reconciliation(status:"matched",checkedAt:Utilities.iso(),sourceCount:count,collectedCount:count,sourceTotal:total,collectedTotal:total,scope:"Current local accounting ledger")
            if batch.0.contains(where:{$0.quality=="partial"}) {health.status="partial"}
        }
        health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
    }
}
