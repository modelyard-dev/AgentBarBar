import Foundation
import CSQLite

/// Field numbers were verified against descriptors embedded in the installed official server.
/// Unknown payloads are skipped without decoding prompts, headers, tools or response content.
struct ProtoMetadata {
    var integers:[Int:[UInt64]]=[:]
    var bytes:[Int:[Data]]=[:]
    init(_ data:Data,allowed:Set<Int>) throws {
        var position=0
        func varint() throws -> UInt64 {
            var value:UInt64=0
            for shift in stride(from:0,to:70,by:7) {
                guard position<data.count else{throw CoreError.invalid("Parser incompatible: truncated metadata protobuf")}
                let byte=data[data.startIndex+position];position+=1
                if shift==63 && byte>1 {throw CoreError.invalid("Parser incompatible: metadata integer overflow")}
                value |= UInt64(byte&127)<<shift
                if byte&128==0 {return value}
            };throw CoreError.invalid("Parser incompatible: metadata varint")
        }
        while position<data.count {
            let key=try varint(),field=Int(key>>3),wire=key&7
            guard field>0 else{throw CoreError.invalid("Parser incompatible: metadata field zero")}
            switch wire {
            case 0:let value=try varint();if allowed.contains(field){integers[field,default:[]].append(value)}
            case 2:
                let length=try varint();guard length<=UInt64(data.count-position) else{throw CoreError.invalid("Parser incompatible: metadata length")}
                let end=position+Int(length)
                if allowed.contains(field){bytes[field,default:[]].append(Data(data[(data.startIndex+position)..<(data.startIndex+end)]))};position=end
            case 1,5:position += wire==1 ? 8:4;guard position<=data.count else{throw CoreError.invalid("Parser incompatible: metadata fixed field")}
            default:throw CoreError.invalid("Parser incompatible: metadata wire type")
            }
        }
    }
    func integer(_ field:Int) -> UInt64? {integers[field]?.first}
    func message(_ field:Int) -> Data? {bytes[field]?.first}
    func string(_ field:Int) -> String? {message(field).flatMap{String(data:$0,encoding:.utf8)}}
    func packed(_ field:Int) throws -> [Int64] {
        if let direct=integers[field] {return direct.map{Int64(clamping:$0)}}
        guard let data=message(field) else{return []}
        var result:[Int64]=[];var value:UInt64=0;var shift=0
        for byte in data {
            guard shift<64 else{throw CoreError.invalid("Parser incompatible: packed metadata index")}
            value |= UInt64(byte&127)<<shift
            if byte&128==0 {result.append(Int64(clamping:value));value=0;shift=0}else{shift+=7}
        }
        guard shift==0 else{throw CoreError.invalid("Parser incompatible: incomplete metadata index")};return result
    }
}

public final class AntigravityCollector:AgentCollector {
    public let descriptor:CollectorDescriptor
    private let home:String
    private var currentHealth=CollectorHealth()
    public init(agentID:String,name:String,roots:[String],home:String=FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home=home
        descriptor=CollectorDescriptor(id:agentID+"-local",agentID:agentID,name:name,version:"1.0.0",parserVersion:"antigravity-sqlite-protobuf-v1.0.0",supportedAgentVersions:["2.5.5 IDE / 2.8.1 desktop, verified embedded metadata descriptors"],capabilities:["input":.derived,"output":.supported,"total":.derived,"cacheRead":.supported,"cacheWrite":.supported,"reasoning":.supported,"cachedOutput":.unsupported,"model":.conditional,"session":.supported,"project":.unsupported,"cost":.unsupported],sourceRoots:roots,sourceDescription:"Antigravity local generation SQLite / protobuf metadata")
    }
    public func health() async -> CollectorHealth {currentHealth}
    public func detect() async -> DetectionResult {await detect(using:DiscoveryEngine(home:home))}
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult {discovery.detect(DiscoveryEngine.catalog.first{$0.id==descriptor.agentID}!,sourceRoots:descriptor.sourceRoots)}
    public func collect(store:EventStore) async throws -> CollectionResult {try await collectSources(store:store,changes:nil)}
    public func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult {try await collectSources(store:store,changes:paths)}
    private func collectSources(store:EventStore,changes:[String]?) async throws -> CollectionResult {
        let run=try await store.beginRun(collectorID:descriptor.id);var health=CollectorHealth();health.status="healthy";health.compatibility="schema_verified_agent_version_unverified"
        let fm=FileManager.default;var files:[URL]=[]
        for root in descriptor.sourceRoots {
            files += ((try? fm.contentsOfDirectory(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension=="db" && (try? $0.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true}
        }
        if let changes {files=files.filter{file in changes.contains{file.path==$0 || file.path+"-wal"==$0 || file.path+"-shm"==$0 || file.path.hasPrefix($0+"/")}}}
        health.files=files.count;if files.isEmpty && changes==nil {health.status="source_unavailable"}
        for file in files.sorted(by:{$0.path<$1.path}) {
            do {
                let attrs=try fm.attributesOfItem(atPath:file.path);let identity="\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
                let signature=Utilities.hash([file.path,file.path+"-wal"].map{path -> String in let a=try? fm.attributesOfItem(atPath:path);return "\(a?[.size] ?? 0):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"}.joined(separator:"|"))
                var cursor=try await store.cursor(path:file.path) ?? SourceCursor(path:file.path,identity:identity,parserVersion:descriptor.parserVersion)
                if cursor.identity != identity || cursor.parserVersion != descriptor.parserVersion {cursor=SourceCursor(path:file.path,identity:identity,parserVersion:descriptor.parserVersion)}
                if cursor.boundaryHash==signature {if let error=cursor.lastError{health.errors.append(error)};continue}
                let db=try ReadOnlySourceDatabase(path:file.path)
                try db.verifyColumns("gen_metadata",required:["idx","data"]);try db.verifyColumns("steps",required:["idx","status","metadata"])
                let pending=Array((cursor.state.pendingSourceRows ?? []).prefix(1024));let placeholders=pending.map{_ in "?"}.joined(separator:",")
                let statement=try db.prepare("SELECT idx,data FROM gen_metadata WHERE idx>=?"+(pending.isEmpty ? "":" OR idx IN ("+placeholders+")")+" ORDER BY idx")
                defer{sqlite3_finalize(statement)};sqlite3_bind_int64(statement,1,Int64(clamping:cursor.offset))
                for (index,id) in pending.enumerated(){sqlite3_bind_int64(statement,Int32(index+2),id)}
                var events:[UsageEvent]=[];var waiting=Set(pending);cursor.lastError=nil
                var code=sqlite3_step(statement)
                while code==SQLITE_ROW {
                    let index=sqlite3_column_int64(statement,0);guard index>=0,let blob=db.bytes(statement,1),blob.count<=64*1024*1024 else{throw CoreError.invalid("Parser incompatible: generation metadata record")}
                    health.bytesRead+=UInt64(blob.count);cursor.offset=max(cursor.offset,UInt64(index+1))
                    let generation=try ProtoMetadata(blob,allowed:[1,2,4]);let indices=try generation.packed(2)
                    if let chatData=generation.message(1) {
                        let chat=try ProtoMetadata(chatData,allowed:[4,9,19,22])
                        if let usageData=chat.message(4) {
                            let usage=try ProtoMetadata(usageData,allowed:[1,2,3,4,5,6,7,9,10,11,12])
                            let input=usage.integer(2) ?? 0,output=usage.integer(3) ?? 0,read=usage.integer(5) ?? 0,write=usage.integer(4) ?? 0,reasoning=usage.integer(9) ?? 0
                            guard [input,output,read,write,reasoning].allSatisfy({$0<=9_007_199_254_740_991}) else{throw CoreError.invalid("Parser incompatible: generation token counter")}
                            var complete=true;var stepMetadata:Data?
                            if let step=indices.first {
                                let s=try db.prepare("SELECT status,metadata FROM steps WHERE idx=?");sqlite3_bind_int64(s,1,step)
                                if sqlite3_step(s)==SQLITE_ROW {complete=[3,6,7,12].contains(Int(sqlite3_column_int(s,0)));stepMetadata=db.bytes(s,1)}else{complete=false};sqlite3_finalize(s)
                            }
                            if !complete || input+output+read+write==0 {waiting.insert(index)}
                            else {
                                waiting.remove(index)
                                var timestampData:Data?
                                if let startData=chat.message(9) {timestampData=try ProtoMetadata(startData,allowed:[4]).message(4)}
                                if timestampData==nil,let stepMetadata {
                                    let metadata=try ProtoMetadata(stepMetadata,allowed:[1,7,8,32])
                                    timestampData=metadata.message(8) ?? metadata.message(7) ?? metadata.message(32) ?? metadata.message(1)
                                }
                                guard let timestampData else{throw CoreError.invalid("Parser incompatible: generation timestamp missing")}
                                let stamp=try ProtoMetadata(timestampData,allowed:[1,2]);let seconds=stamp.integer(1) ?? 0,nanos=stamp.integer(2) ?? 0
                                guard seconds>0,seconds<253_402_300_799,nanos<1_000_000_000 else{throw CoreError.invalid("Parser incompatible: generation timestamp")}
                                let request=usage.string(11) ?? usage.string(12) ?? usage.string(7) ?? generation.string(4)
                                guard let request,!request.isEmpty else{throw CoreError.invalid("Parser incompatible: generation request ID missing")}
                                var state=ParserState();state.sessionID=file.deletingPathExtension().lastPathComponent
                                state.model=chat.string(22) ?? chat.string(19) ?? usage.integer(1).map{"model_enum:"+String($0)}
                                let providers:[UInt64:String]=[1:"API_PROVIDER_INTERNAL",3:"API_PROVIDER_GOOGLE_VERTEX",24:"API_PROVIDER_GOOGLE_GEMINI",26:"API_PROVIDER_ANTHROPIC_VERTEX",30:"API_PROVIDER_GOOGLE_EVERGREEN",31:"API_PROVIDER_OPENAI_VERTEX"]
                                state.provider=usage.integer(6).map{providers[$0] ?? "api_provider_enum:"+String($0)}
                                var metrics=TokenMetrics();metrics.input=Metric(Int64(input+read+write));metrics.output=Metric(Int64(output));metrics.total=Metric(Int64(input+read+write+output));metrics.cacheRead=Metric(Int64(read));metrics.cacheWrite=Metric(Int64(write));metrics.reasoning=reasoning<=output ? Metric(Int64(reasoning)):Metric(state:.unknown)
                                let counters=["input_tokens":input,"output_tokens":output,"cache_read_tokens":read,"cache_write_tokens":write,"thinking_output_tokens":reasoning]
                                let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,path:file.path,line:0,offset:0)
                                var event=try context.event(timestamp:Utilities.iso(Date(timeIntervalSince1970:Double(seconds)+Double(nanos)/1e9)),identity:"generation:"+request,metrics:metrics,state:state,parser:descriptor.parserVersion,metadata:["reported_usage":try Utilities.json(counters),"counting_method":"completed_generation_usage","source_table":"gen_metadata","source_row_id":String(index),"input_semantics":"uncached input plus cache read/write","output_semantics":"reported output already includes thinking"],partial:reasoning>output)
                                event.sourceType="local_sqlite_protobuf";events.append(event)
                            }
                        }
                    }
                    code=sqlite3_step(statement)
                }
                guard code==SQLITE_DONE else{throw db.error()}
                cursor.state.pendingSourceRows=Array(waiting.sorted().prefix(1024));cursor.boundaryHash=signature
                let result=try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id);health.imported+=result.inserted;health.updated+=result.updated;health.duplicates+=result.duplicates
            }catch{if health.errors.count<12 {health.errors.append("\(file.lastPathComponent): \((error as? CoreError)?.localizedDescription ?? "Cannot read generation metadata")")}}
        }
        if !health.errors.isEmpty{health.status="partial"};health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
    }
}
