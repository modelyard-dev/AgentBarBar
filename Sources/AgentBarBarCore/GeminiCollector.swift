import Foundation

private struct GeminiSourceLocation {var line:Int;var offset:UInt64;var pointer:String?}
private struct GeminiSessionMetadata:Decodable {var sessionId:String;var messages:[GeminiMessageMetadata]}
// Whitelist decoder: conversation, tools, summaries and patch content are never retained.
private struct GeminiStreamMetadata: Decodable {
    var sessionId: String?
    var id: String?
    var timestamp: String?
    var type: String?
    var tokens: [String: Int64?]?
    var model: String?
    var messages: [GeminiMessageMetadata]?
    var set: GeminiSetMetadata?
    var rewind: String?
    var patch: GeminiPatchMetadata?
    enum CodingKeys: String, CodingKey {
        case sessionId, id, timestamp, type, tokens, model, messages
        case set = "$set", rewind = "$rewindTo", patch = "$patch"
    }
}
private struct GeminiSetMetadata: Decodable { var sessionId: String?; var messages: [GeminiMessageMetadata]? }
private struct GeminiPatchMetadata: Decodable { var id: String?; var removeIds: [String]?; var orderIds: [String]? }
private struct GeminiMessageMetadata:Codable {var id:String?;var timestamp:String?;var type:String;var tokens:[String:Int64?]?;var model:String?;var provider:String?}

public final class GeminiParserV1:UsageParser {
    public let version="gemini-session-json-v1.1.0"
    public init() {}
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        guard let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],row["type"] as? String=="gemini",
              let usage=row["tokens"] as? [String:Any] else{return nil}
        guard let id=row["id"] as? String,!id.isEmpty,state.sessionID != nil else{throw CoreError.invalid("Parser incompatible: Gemini message/session identity")}
        let input=try Utilities.token(usage,"input"),output=try Utilities.token(usage,"output"),thoughts=try Utilities.token(usage,"thoughts")
        var metrics=TokenMetrics();metrics.total=Metric(try Utilities.token(usage,"total"));metrics.reasoning=Metric(thoughts)
        metrics.cacheRead=Metric(try Utilities.token(usage,"cached"));metrics.cacheWrite=Metric(state:.unsupported)
        if let output,let thoughts {metrics.output=Metric(output+thoughts)}
        if let input {metrics.input=Metric(input)}
        else if let total=metrics.total.value,let out=metrics.output.value,total>=out {metrics.input=Metric(total-out);metrics.input.state = .partial}
        if metrics.output.value==nil,let total=metrics.total.value,let input=metrics.input.value,total>=input {metrics.output=Metric(total-input);metrics.output.state = .partial}
        guard metrics.total.value != nil || metrics.input.value != nil || metrics.output.value != nil else{throw CoreError.invalid("Parser incompatible: Gemini token counters missing")}
        state.model=row["model"] as? String;state.provider=row["provider"] as? String
        var counters:[String:Int64]=[:]
        for key in ["input","output","thoughts","tool","cached","total"] {counters[key]=try Utilities.token(usage,key)}
        if metrics.total.value==0 {metrics.total.state = .partial}
        if metrics.input.value==0 {metrics.input.state = .partial}
        if metrics.output.value==0 {metrics.output.state = .partial}
        if metrics.reasoning.value==0 {metrics.reasoning.state = .partial}
        if metrics.cacheRead.value==0 {metrics.cacheRead.state = .partial}
        let partial=metrics.input.state == .partial || metrics.output.state == .partial || usage.values.contains{($0 as? NSNumber)?.int64Value == 0} || metrics.input.value==nil || metrics.output.value==nil || (metrics.total.value != metrics.input.value.flatMap{i in metrics.output.value.map{i+$0}})
        var event=try context.event(timestamp:row["timestamp"] as? String,identity:"message:"+id,metrics:metrics,state:state,parser:version,
            metadata:["reported_usage":try Utilities.json(counters),"counting_method":"session_message_usage","output_semantics":"candidate output plus thoughts","input_semantics":"reported prompt preferred; otherwise total minus complete output; cache included; tool not added","source_reliability":"upstream may substitute zero for absent provider counters","usage_scope":"request"],partial:partial)
        event.sourceType="local_session_json";return event
    }
}

public final class GeminiCollector:AgentCollector {
    public let descriptor:CollectorDescriptor
    private let home:String
    private let parser=GeminiParserV1()
    private let streamParser=GeminiJSONLParserV1()
    private let parserVersion="gemini-session-v2.0.1"
    private var currentHealth=CollectorHealth()
    public init(roots:[String],home:String=FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home=home
        descriptor=CollectorDescriptor(id:"gemini-local",agentID:"gemini",name:"Gemini CLI",version:"1.1.1",parserVersion:parserVersion,
            supportedAgentVersions:["Session JSON token schema observed in 2026-03 history", "Append-only JSONL pinned fb972b2"],
            capabilities:["input":.conditional,"output":.conditional,"total":.supported,"reasoning":.conditional,"cacheRead":.conditional,"cacheWrite":.unsupported,"cachedOutput":.unsupported,"model":.conditional,"session":.supported,"project":.conditional,"cost":.unsupported],sourceRoots:roots,sourceDescription:"Gemini CLI local chat session JSON / append-only JSONL")
    }
    private static func readStream(_ data: Data) throws -> (GeminiSessionMetadata, [String:String], [String:GeminiSourceLocation]) {
        var session: String?
        var order: [String]=[]
        var messages: [String:GeminiMessageMetadata]=[:]
        var locations:[String:GeminiSourceLocation]=[:]
        var rewinds=0,patches=0
        func remember(_ message: GeminiMessageMetadata,location:GeminiSourceLocation) throws {
            guard let id=message.id,!id.isEmpty else { throw CoreError.invalid("Gemini JSONL message identity missing") }
            if messages[id]==nil { order.append(id) }
            // A content-only checkpoint must not erase previously observed usage.
            if message.tokens != nil || messages[id]?.tokens == nil {messages[id]=message;locations[id]=location}
        }
        let lines=data.split(separator:10,omittingEmptySubsequences:false)
        // A non-newline-terminated tail may be an in-flight write; retry on append.
        var offset:UInt64=0
        for (index,line) in lines.dropLast().enumerated() {
            let location=GeminiSourceLocation(line:index+1,offset:offset,pointer:nil)
            defer {offset+=UInt64(line.count+1)}
            if line.isEmpty {continue}
            let row=try JSONDecoder().decode(GeminiStreamMetadata.self,from:Data(line))
            if let id=row.sessionId {session=id}
            if let set=row.set {
                if let id=set.sessionId {session=id}
                for (index,message) in (set.messages ?? []).enumerated() {
                    try remember(message,location:.init(line:location.line,offset:location.offset,pointer:"$set/messages/"+String(index)))
                }
            } else if row.rewind != nil {rewinds+=1}
            else if row.patch != nil {patches+=1}
            else if let type=row.type,let id=row.id {
                try remember(.init(id:id,timestamp:row.timestamp,type:type,tokens:row.tokens,model:row.model,provider:nil),location:location)
            } else if let checkpoint=row.messages {
                for (index,message) in checkpoint.enumerated() {
                    try remember(message,location:.init(line:location.line,offset:location.offset,pointer:"messages/"+String(index)))
                }
            } else if row.sessionId==nil {throw CoreError.invalid("Parser incompatible: unrecognized Gemini JSONL record")}
        }
        guard let session,!session.isEmpty else {throw CoreError.invalid("Gemini JSONL session metadata missing")}
        return (.init(sessionId:session,messages:order.compactMap{messages[$0]}),
                ["history_semantics":"all observed usage retained across rewind/patch/checkpoint; latest counters per message",
                 "rewind_records":String(rewinds),"patch_records":String(patches)],locations)
    }
    public func health() async -> CollectorHealth {currentHealth}
    public func detect() async -> DetectionResult {await detect(using:DiscoveryEngine(home:home))}
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult {discovery.detect(DiscoveryEngine.catalog.first{$0.id=="gemini"}!,sourceRoots:descriptor.sourceRoots)}
    public func collect(store:EventStore) async throws -> CollectionResult {try await collectSources(store:store,changes:nil)}
    public func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult {try await collectSources(store:store,changes:paths)}
    private func collectSources(store:EventStore,changes:[String]?) async throws -> CollectionResult {
        let run=try await store.beginRun(collectorID:descriptor.id);var health=CollectorHealth();health.status="healthy";health.compatibility="schema_verified_agent_version_unverified"
        let fm=FileManager.default;var files=Set<URL>()
        for root in descriptor.sourceRoots {
            let url=URL(fileURLWithPath:root)
            if ["json","jsonl"].contains(url.pathExtension) {files.insert(url);continue}
            var chats=[url]
            for project in (try? fm.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isSymbolicLinkKey],options:[.skipsHiddenFiles])) ?? [] {
                if (try? project.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true {continue}
                chats.append(project.appendingPathComponent("chats"))
            }
            for directory in chats {
                for file in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])) ?? [] where file.lastPathComponent.hasPrefix("session-") && ["json","jsonl"].contains(file.pathExtension) {
                    let properties=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                    if properties?.isRegularFile==true && properties?.isSymbolicLink != true {files.insert(file)}
                }
            }
        }
        // A migration creates the same stem with a new extension. Prefer the
        // stream and never let an obsolete JSON snapshot overwrite newer usage.
        files=Set(files.filter{file in file.pathExtension != "json" || !fm.fileExists(atPath:file.deletingPathExtension().appendingPathExtension("jsonl").path)})
        if let changes {
            let paths=changes.map{URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath().path}
            files=Set(files.filter{file in
                let path=file.standardizedFileURL.resolvingSymlinksInPath().path
                return paths.contains{path==$0 || path.hasPrefix($0+"/")}
            })
        }
        health.files=files.count
        if files.isEmpty && changes==nil {health.status="source_unavailable"}
        for file in files.sorted(by:{$0.path<$1.path}) {
            do {
                let attrs=try fm.attributesOfItem(atPath:file.path),size=(attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let modified=(attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let identity="\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
                var cursor=try await store.cursor(path:file.path) ?? SourceCursor(path:file.path,identity:identity,parserVersion:parserVersion)
                if cursor.identity==identity,cursor.modified==modified,cursor.observedSize==size,cursor.parserVersion==parserVersion {
                    if let error=cursor.lastError {health.errors.append(error)};continue
                }
                guard size<=64*1024*1024 else{throw CoreError.invalid("Gemini session exceeds supported size")}
                let data=try Data(contentsOf:file);health.bytesRead+=UInt64(data.count)
                // Decode only metadata. Irrelevant conversation strings need not be materialized.
                let document: GeminiSessionMetadata
                var streamNotes: [String:String]=[:]
                var streamLocations:[String:GeminiSourceLocation]=[:]
                if file.pathExtension=="jsonl" {
                    let replay=try Self.readStream(data)
                    document=replay.0;streamNotes=replay.1;streamLocations=replay.2
                } else {document=try JSONDecoder().decode(GeminiSessionMetadata.self,from:data)}
                var state=ParserState();state.sessionID=document.sessionId
                let rootFile=file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".project_root")
                if let metadata=try? Data(contentsOf:rootFile),metadata.count<=4096,let cwd=String(data:metadata,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),cwd.hasPrefix("/") {state.cwd=cwd}
                var events:[UsageEvent]=[]
                for (index,message) in document.messages.enumerated() {
                    guard message.type=="gemini",message.tokens != nil else{continue}
                    let location=streamLocations[message.id ?? ""]
                    let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,path:file.path,line:location?.line ?? 0,offset:location?.offset ?? 0)
                    let reader: any UsageParser = file.pathExtension=="jsonl" ? streamParser : parser
                    if var event=try reader.parse(JSONEncoder().encode(message),state:&state,context:context) {
                        event.sourceMetadata.merge(streamNotes){_,new in new}
                        event.collectorVersion=descriptor.version
                        if file.pathExtension=="json" {event.sourceMetadata["json_pointer"]="messages/"+String(index)}
                        else if let pointer=location?.pointer {event.sourceMetadata["json_pointer"]=pointer}
                        if state.cwd != nil {event.sourceMetadata["cwd_source"]="project_root_metadata"}
                        events.append(event)
                    }
                }
                cursor.identity=identity;cursor.parserVersion=parserVersion;cursor.modified=modified;cursor.observedSize=size;cursor.offset=size;cursor.lastError=nil
                let result=try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id,authoritativeAgent:descriptor.agentID);health.imported+=result.inserted;health.updated+=result.updated;health.duplicates+=result.duplicates
            }catch {if health.errors.count<12 {health.errors.append("\(file.lastPathComponent): \((error as? CoreError)?.localizedDescription ?? "Cannot read Gemini session metadata")")}}
        }
        if !health.errors.isEmpty {health.status="partial"};health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
    }
}

/// New stream format: prompt includes cache; output candidates and thoughts are separate.
public final class GeminiJSONLParserV1: UsageParser {
    public let version="gemini-session-jsonl-v1.0.1"
    public init() {}
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        guard let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              row["type"] as? String=="gemini",let tokens=row["tokens"] as? [String:Any] else{return nil}
        guard let id=row["id"] as? String,!id.isEmpty,state.sessionID != nil else{throw CoreError.invalid("Gemini JSONL request identity missing")}
        var raw:[String:Int64]=[:]
        for key in ["input","output","thoughts","cached","tool","total"] {raw[key]=try Utilities.token(tokens,key)}
        var metrics=TokenMetrics()
        metrics.input=Metric(raw["input"]);metrics.total=Metric(raw["total"])
        metrics.reasoning=Metric(raw["thoughts"]);metrics.cacheRead=Metric(raw["cached"])
        metrics.cacheWrite=Metric(state:.unsupported)
        if let output=raw["output"],let thoughts=raw["thoughts"] {metrics.output=Metric(output+thoughts)}
        // Missing thoughts does not establish zero reasoning or a complete output.
        guard metrics.input.value != nil || metrics.total.value != nil || raw["output"] != nil else{throw CoreError.invalid("Gemini JSONL counters missing")}
        let hasZero=raw.values.contains(0)
        if hasZero {
            if metrics.input.value==0 {metrics.input.state = .partial}
            if metrics.output.value==0 {metrics.output.state = .partial}
            if metrics.total.value==0 {metrics.total.state = .partial}
            if metrics.reasoning.value==0 {metrics.reasoning.state = .partial}
            if metrics.cacheRead.value==0 {metrics.cacheRead.state = .partial}
        }
        state.model=row["model"] as? String;state.provider=nil
        let matched=metrics.input.value.flatMap{i in metrics.output.value.map{i+$0}} == metrics.total.value && metrics.total.value != nil
        var event=try context.event(timestamp:row["timestamp"] as? String,identity:"message:"+id,metrics:metrics,state:state,parser:version,
            metadata:["reported_usage":try Utilities.json(raw),"counting_method":"session_message_usage","usage_scope":"request",
                      "input_semantics":"reported prompt; cache is a subset; tool bucket not added",
                      "output_semantics":"candidate output plus thoughts when both present",
                      "source_reliability":"upstream may substitute zero for absent provider counters",
                      "component_reconciliation":matched ? "matched":"incomplete_or_mismatch"],partial:hasZero || !matched)
        event.sourceType="local_session_jsonl";return event
    }
}
