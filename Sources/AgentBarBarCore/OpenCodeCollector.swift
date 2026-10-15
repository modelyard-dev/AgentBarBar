import Foundation
import CSQLite

public final class OpenCodeCollector: AgentCollector {
    public let descriptor:CollectorDescriptor
    private let home:String
    private var currentHealth=CollectorHealth()
    private let parser=OpenCodeParserV1()
    public init(roots:[String],home:String=FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home=home
        descriptor=CollectorDescriptor(id:"opencode-local",agentID:"opencode",name:"OpenCode",version:"1.0.0",parserVersion:parser.version,
            supportedAgentVersions:["1.18.18 desktop / 1.18.21 CLI local schema"],
            capabilities:["input":.supported,"output":.supported,"cacheRead":.supported,"cacheWrite":.supported,"reasoning":.supported,"total":.conditional,"cachedOutput":.unsupported,"model":.supported,"session":.supported,"project":.conditional,"cost":.unsupported],sourceRoots:roots,sourceDescription:"OpenCode local SQLite message metadata")
    }
    public func detect() async -> DetectionResult {await detect(using:DiscoveryEngine(home:home))}
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult {discovery.detect(DiscoveryEngine.catalog.first{$0.id=="opencode"}!,sourceRoots:descriptor.sourceRoots.filter{FileManager.default.fileExists(atPath:databasePath($0))})}
    public func health() async -> CollectorHealth {currentHealth}
    private func databasePath(_ root:String) -> String {root.hasSuffix(".db") ? root : root+"/opencode.db"}
    public func collect(store:EventStore) async throws -> CollectionResult {
        let run=try await store.beginRun(collectorID:descriptor.id)
        var health=CollectorHealth();health.status="healthy";health.compatibility="schema_verified_agent_version_unverified"
        for root in descriptor.sourceRoots {
            let path=databasePath(root)
            guard FileManager.default.fileExists(atPath:path) else{continue}
            health.files+=1
            do {
                let attrs=try FileManager.default.attributesOfItem(atPath:path)
                let identity="\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
                let signature=try fileSignature(path)
                var cursor=try await store.cursor(path:path) ?? SourceCursor(path:path,identity:identity,parserVersion:parser.version)
                if cursor.identity != identity || cursor.parserVersion != parser.version {cursor=SourceCursor(path:path,identity:identity,parserVersion:parser.version)}
                if cursor.boundaryHash==signature,let count=cursor.state.counters?["reconciled_count"] {
                    let own=try await store.basicUsage(agentID:descriptor.agentID)
                    let total=cursor.state.counters?["reconciled_total"]
                    health.reconciliation=Reconciliation(status:own.count==Int(count) && own.total==total ? "matched":"mismatch",checkedAt:Utilities.iso(),sourceCount:Int(count),collectedCount:own.count,sourceTotal:total,collectedTotal:own.total,scope:"Eligible current local message database");
                    if health.reconciliation?.status=="mismatch" {health.errors.append("Local usage reconciliation differs from source")}
                    if let error=cursor.lastError {health.errors.append(error)}
                    health.errors += Array((cursor.state.sourceRecordErrors ?? [:]).values.sorted().prefix(12))
                    continue
                }
                let database=try ReadOnlySourceDatabase(path:path)
                let begin=try database.prepare("BEGIN");defer{sqlite3_finalize(begin)}
                guard sqlite3_step(begin)==SQLITE_DONE else{throw database.error()}
                try database.verifyColumns("message",required:["id","session_id","time_created","time_updated","data"])
                try database.verifyColumns("session",required:["id","directory","parent_id","time_created"])
                // No source index or pragma is changed. An unchanged DB+WAL performs no SQL scan.
                // time_updated catches existing rows finalized by a streaming request; an overlap handles equal timestamps.
                let statement=try database.prepare("""
                SELECT m.time_updated, json_object(
                 'id',m.id,'session_id',m.session_id,'role',json_extract(m.data,'$.role'),
                 'created',json_extract(m.data,'$.time.created'),'completed',json_extract(m.data,'$.time.completed'),
                 'model',json_extract(m.data,'$.modelID'),'provider',json_extract(m.data,'$.providerID'),
                 'tokens',json_extract(m.data,'$.tokens'),'cost',json_extract(m.data,'$.cost'),
                 'has_error',CASE WHEN json_type(m.data,'$.error') IS NOT NULL AND json_type(m.data,'$.error')!='null' THEN 1 ELSE 0 END,
                 'cwd',coalesce(json_extract(m.data,'$.path.cwd'),s.directory),
                 'parent_id',s.parent_id,'session_created',s.time_created)
                FROM message m JOIN session s ON s.id=m.session_id
                WHERE m.time_updated>=? AND json_extract(m.data,'$.role')='assistant'
                ORDER BY m.time_updated,m.id
                """)
                defer{sqlite3_finalize(statement)}
                sqlite3_bind_int64(statement,1,Int64(min(cursor.offset,UInt64(Int64.max))))
                var events:[UsageEvent]=[];var state=ParserState();let projects=ProjectDetector();cursor.lastError=nil;cursor.boundaryHash=nil
                var code=sqlite3_step(statement)
                while code==SQLITE_ROW {
                    let updated=sqlite3_column_int64(statement,0)
                    guard updated>=0,let text=database.string(statement,1) else{throw CoreError.invalid("Parser incompatible: OpenCode updated timestamp")}
                    let data=Data(text.utf8);health.bytesRead+=UInt64(data.count)
                    let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,collectorVersion:descriptor.version,path:path,line:0,projects:projects)
                    let rowID=(try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["id"] as? String ?? "unknown"
                    let prefix="OpenCode message "+rowID+": "
                    if cursor.state.sourceRecordErrors==nil {cursor.state.sourceRecordErrors=[:]}
                    cursor.state.sourceRecordErrors?.removeValue(forKey:rowID)
                    func recordError(_ description:String) {
                        if (cursor.state.sourceRecordErrors?.count ?? 0)<1000 {cursor.state.sourceRecordErrors?[rowID]=prefix+description}
                    }
                    do {
                        if let event=try parser.parse(data,state:&state,context:context) {
                            events.append(event)
                            if let invalid=event.sourceMetadata["invalid_source_metrics"] {recordError("Invalid source counters: "+invalid+"; these components are Unknown")}
                        }
                    } catch {recordError((error as? CoreError)?.localizedDescription ?? "Parser incompatible: metadata record")}
                    cursor.offset=max(cursor.offset,UInt64(updated))
                    if events.count>=200 {let result=try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id);health.imported+=result.inserted;health.updated+=result.updated;health.duplicates+=result.duplicates;events.removeAll(keepingCapacity:true)}
                    code=sqlite3_step(statement)
                }
                guard code==SQLITE_DONE else{throw database.error()}
                cursor.boundaryHash=signature
                health.errors += Array((cursor.state.sourceRecordErrors ?? [:]).values.sorted().prefix(12))
                let result=try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id)
                health.imported+=result.inserted;health.updated+=result.updated;health.duplicates+=result.duplicates
                if descriptor.sourceRoots.count==1 {
                    let verify=try database.prepare("""
                    SELECT COUNT(*),SUM(COALESCE(json_extract(m.data,'$.tokens.total'),
                      json_extract(m.data,'$.tokens.input')+json_extract(m.data,'$.tokens.cache.read')+json_extract(m.data,'$.tokens.cache.write')+json_extract(m.data,'$.tokens.output')+json_extract(m.data,'$.tokens.reasoning')))
                    FROM message m JOIN session s ON s.id=m.session_id
                    WHERE json_extract(m.data,'$.role')='assistant' AND json_extract(m.data,'$.time.completed') IS NOT NULL
                      AND (s.parent_id IS NULL OR json_extract(m.data,'$.time.created')>=s.time_created)
                      AND NOT (json_type(m.data,'$.error') IS NOT NULL AND json_type(m.data,'$.error')!='null' AND json_extract(m.data,'$.tokens.total')=0)
                    """)
                    defer{sqlite3_finalize(verify)}
                    if sqlite3_step(verify)==SQLITE_ROW {
                        let own=try await store.basicUsage(agentID:descriptor.agentID)
                        let sourceCount=Int(sqlite3_column_int64(verify,0)),sourceTotal=sqlite3_column_type(verify,1)==SQLITE_NULL ? nil:sqlite3_column_int64(verify,1)
                        health.reconciliation=Reconciliation(status:own.count==sourceCount && own.total==sourceTotal ? "matched":"mismatch",checkedAt:Utilities.iso(),sourceCount:sourceCount,collectedCount:own.count,sourceTotal:sourceTotal,collectedTotal:own.total,scope:"Eligible current local message database")
                        if health.reconciliation?.status=="mismatch" {health.errors.append("Local usage reconciliation differs from source")}
                        cursor.state.counters=["reconciled_count":Int64(sourceCount)]
                        cursor.state.counters?["reconciled_total"]=sourceTotal
                        _=try await store.commit(events:[],cursor:cursor,collectorID:descriptor.id)
                    }
                }
            } catch {health.errors.append((error as? CoreError)?.localizedDescription ?? "Cannot read OpenCode database: "+path)}
        }
        if health.files==0 {health.status="source_unavailable";health.compatibility="unverified"}
        if !health.errors.isEmpty {health.status="partial"}
        health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
    }
    private func fileSignature(_ path:String) throws -> String {
        var parts:[String]=[]
        for file in [path,path+"-wal"] {
            if let attrs=try? FileManager.default.attributesOfItem(atPath:file) {parts.append("\(attrs[.size] ?? 0):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")}
            else {parts.append("absent")}
        };return Utilities.hash(parts.joined(separator:"|"))
    }
}

final class ReadOnlySourceDatabase {
    private var handle:OpaquePointer?
    private let label:String
    init(path:String,label:String="OpenCode") throws {
        self.label=label
        let result=sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil)
        guard result==SQLITE_OK,sqlite3_db_readonly(handle,"main")==1 else{if let handle{sqlite3_close(handle)};handle=nil;throw CoreError.io("Cannot read "+label+" database: "+path)}
        sqlite3_busy_timeout(handle,1000)
    }
    deinit{sqlite3_close(handle)}
    func prepare(_ sql:String) throws -> OpaquePointer {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(handle,sql,-1,&statement,nil)==SQLITE_OK,let statement else{throw error()};return statement
    }
    func string(_ p:OpaquePointer,_ column:Int32) -> String? {sqlite3_column_text(p,column).map{String(cString:$0)}}
    func bytes(_ p:OpaquePointer,_ column:Int32) -> Data? {
        guard let pointer=sqlite3_column_blob(p,column) else{return nil}
        return Data(bytes:pointer,count:Int(sqlite3_column_bytes(p,column)))
    }
    func verifyColumns(_ table:String,required:Set<String>) throws {
        let p=try prepare("PRAGMA table_info(\(table))");defer{sqlite3_finalize(p)};var columns=Set<String>()
        while sqlite3_step(p)==SQLITE_ROW {if let name=string(p,1){columns.insert(name)}}
        guard required.isSubset(of:columns) else{throw CoreError.invalid("Parser incompatible: \(label) \(table) schema; missing \(required.subtracting(columns).sorted().joined(separator:", "))")}
    }
    func error() -> CoreError {.io(label+" database: "+String(cString:sqlite3_errmsg(handle)))}
}
