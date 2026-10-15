import Foundation

/// Historical Cline task UI schema only. The SDK messages format has a different scope.
public enum ClineTaskParserV1 {
    public static let version = "cline-task-ui-v1.0.0"
    private struct Row: Decodable {
        var type: String
        var say: String?
        var ts: Double?
        var usage: [String:Int64?]?
        enum CodingKeys: String,CodingKey {case type,say,ts,text}
        init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            type=try c.decode(String.self,forKey:.type)
            say=try c.decodeIfPresent(String.self,forKey:.say)
            ts=try c.decodeIfPresent(Double.self,forKey:.ts)
            // Never materialize user/assistant text. Request carriers may contain
            // a prompt; extract only numeric usage in memory and discard it.
            if type=="say",["api_req_started","api_req_finished"].contains(say),
               let text=try c.decodeIfPresent(String.self,forKey:.text),
               let data=text.data(using:.utf8),let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any] {
                var counters:[String:Int64?]=[:]
                for key in ["tokensIn","tokensOut","cacheReads","cacheWrites"] {
                    if raw[key] != nil {counters[key] = .some(try Utilities.token(raw,key))}
                }
                usage=counters
            }
        }
    }
    public static func parse(_ data:Data,task:String,context:ParseContext) throws -> (events:[UsageEvent],excludedAggregates:Int) {
        let rows=try JSONDecoder().decode([Row].self,from:data)
        var state=ParserState();state.sessionID=task
        var events:[UsageEvent]=[]
        let aggregates=rows.filter{$0.type=="say" && ["subagent_usage","deleted_api_reqs"].contains($0.say)}.count
        for (index,row) in rows.enumerated() where row.type=="say" && row.say=="api_req_started" {
            var usage=row.usage ?? [:]
            // Pair within the current request only; never steal another request's finish.
            for next in rows.dropFirst(index+1) {
                if next.type=="say",next.say=="api_req_started" {break}
                if next.type=="say",next.say=="api_req_finished" {
                    usage.merge(next.usage ?? [:]){_,new in new};break
                }
            }
            func value(_ key:String) -> Int64? {usage[key] ?? nil}
            let input=value("tokensIn"),output=value("tokensOut"),read=value("cacheReads"),write=value("cacheWrites")
            if input==nil && output==nil && read==nil && write==nil {continue}
            guard let ts=row.ts,ts.isFinite,ts>=0,ts<=9_007_199_254_740_991,ts.rounded()==ts else{throw CoreError.invalid("Cline request timestamp missing or invalid")}
            var metrics=TokenMetrics();metrics.output=Metric(output)
            metrics.cacheRead=Metric(read);metrics.cacheWrite=Metric(write);metrics.reasoning=Metric(state:.unsupported)
            if let input,let read,let write {metrics.input=Metric(input+read+write)}
            if let full=metrics.input.value,let output {metrics.total=Metric(full+output)}
            var raw:[String:Int64]=[:]
            for key in ["tokensIn","tokensOut","cacheReads","cacheWrites"] {raw[key]=value(key)}
            var event=try context.event(timestamp:Utilities.iso(Date(timeIntervalSince1970:ts/1000)),
                identity:"task:"+task+":request:"+String(Int64(ts)),metrics:metrics,state:state,parser:version,
                metadata:["reported_usage":try Utilities.json(raw),"json_pointer":String(index),
                          "usage_scope":"request","counting_method":"task_request_carrier",
                          "input_semantics":"uncached input plus cache reads and writes only when all reported",
                          "total_semantics":"derived from complete input plus output",
                          "excluded_aggregate_records":String(aggregates),
                          "coverage_notes":"deleted request and subagent aggregates excluded; model/project unavailable"],
                partial:metrics.total.value==nil || aggregates>0)
            event.sourceType="local_task_ui_json";events.append(event)
        }
        return (events,aggregates)
    }
}

public final class ClineCollector: AgentCollector {
    public let descriptor: CollectorDescriptor
    private let home:String
    private var currentHealth=CollectorHealth()
    public init(roots:[String],home:String) {
        self.home=home
        descriptor=CollectorDescriptor(id:"cline-local",agentID:"cline",name:"Cline",version:"1.0.0",parserVersion:ClineTaskParserV1.version,
            supportedAgentVersions:["Historical task UI schema; official v3.70.0 fixture contract"],
            capabilities:["input":.conditional,"output":.conditional,"total":.derived,"cacheRead":.conditional,
                          "cacheWrite":.conditional,"reasoning":.unsupported,"cachedOutput":.unsupported,
                          "model":.unsupported,"project":.unsupported,"session":.supported,"cost":.unsupported],
            sourceRoots:roots,sourceDescription:"Cline historical task ui_messages.json; aggregates excluded")
    }
    public func detect() async -> DetectionResult {await detect(using:DiscoveryEngine(home:home))}
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult {discovery.detect(DiscoveryEngine.catalog.first{$0.id=="cline"}!,sourceRoots:descriptor.sourceRoots)}
    public func health() async -> CollectorHealth {currentHealth}
    public func collect(store:EventStore) async throws -> CollectionResult {try await collectSources(store:store,changes:nil)}
    public func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult {try await collectSources(store:store,changes:paths)}
    private func collectSources(store:EventStore,changes:[String]?) async throws -> CollectionResult {
        let run=try await store.beginRun(collectorID:descriptor.id)
        var health=CollectorHealth();health.status="healthy";health.compatibility="schema_verified_agent_version_unverified"
        let fm=FileManager.default;var files=Set<URL>()
        for path in descriptor.sourceRoots {
            let root=URL(fileURLWithPath:path)
            guard root.resolvingSymlinksInPath().path==root.standardizedFileURL.path else {continue}
            if root.lastPathComponent=="ui_messages.json" {files.insert(root);continue}
            guard let reader=fm.enumerator(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey],options:[.skipsHiddenFiles]) else {continue}
            for case let url as URL in reader {
                let attrs=try? url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
                if attrs?.isSymbolicLink==true {reader.skipDescendants();continue}
                if attrs?.isRegularFile==true && url.lastPathComponent=="ui_messages.json" {files.insert(url)}
            }
        }
        if let changes {
            let paths=changes.map{URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath().path}
            files=Set(files.filter{url in
                let path=url.standardizedFileURL.resolvingSymlinksInPath().path
                return paths.contains{path==$0 || path.hasPrefix($0+"/")}
            })
        }
        health.files=files.count;if files.isEmpty && changes==nil {health.status="source_unavailable"}
        for file in files.sorted(by:{$0.path<$1.path}) {
            do {
                let attrs=try fm.attributesOfItem(atPath:file.path)
                let size=(attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let modified=(attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let identity="\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
                var cursor=try await store.cursor(path:file.path) ?? SourceCursor(path:file.path,identity:identity,parserVersion:descriptor.parserVersion)
                if cursor.identity==identity,cursor.modified==modified,cursor.observedSize==size,cursor.parserVersion==descriptor.parserVersion {
                    if let error=cursor.lastError {health.errors.append(error)};continue
                }
                guard size<=64*1024*1024 else{throw CoreError.invalid("Cline task exceeds supported size")}
                let data=try Data(contentsOf:file);health.bytesRead+=UInt64(data.count)
                let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,path:file.path,line:0)
                let parsed=try ClineTaskParserV1.parse(data,task:file.deletingLastPathComponent().lastPathComponent,context:context)
                cursor.identity=identity;cursor.modified=modified;cursor.observedSize=size;cursor.offset=size;cursor.parserVersion=descriptor.parserVersion
                cursor.lastError=parsed.excludedAggregates>0 ? "Cline deleted/subagent aggregate records excluded; request coverage is partial":nil
                let saved=try await store.commit(events:parsed.events,cursor:cursor,collectorID:descriptor.id,authoritativeAgent:descriptor.agentID)
                health.imported+=saved.inserted;health.updated+=saved.updated;health.duplicates+=saved.duplicates
                if let error=cursor.lastError {health.errors.append(error)}
            } catch {if health.errors.count<12 {health.errors.append("Cline task metadata cannot be parsed: "+file.lastPathComponent)}}
        }
        if !health.errors.isEmpty {health.status="partial"}
        health.lastCollection=Utilities.iso();currentHealth=health
        try await store.updateHealth(descriptor.id,health)
        let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.finishRun(run,result:result);return result
    }
}
