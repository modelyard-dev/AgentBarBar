import Foundation
import CSQLite

/// Research adapters report their evidence and limitations; they never manufacture usage events.
public final class SourceInspectionCollector:AgentCollector {
    public let descriptor:CollectorDescriptor
    private let rule:AgentDiscoveryRule
    private let home:String
    private var currentHealth=CollectorHealth()
    public init(rule:AgentDiscoveryRule,roots:[String],home:String) {
        self.rule=rule;self.home=home
        var descriptor=CollectorDescriptor(id:rule.id+"-inspection",agentID:rule.id,name:rule.name,version:"1.0.0",parserVersion:"source-inspection-v1.0.0",supportedAgentVersions:["Bounded metadata/schema inspection only"],capabilities:Dictionary(uniqueKeysWithValues:TokenMetrics.names.map{($0,Capability.unsupported)}),sourceRoots:roots,sourceDescription:"Local source inspection; no validated Token-producing schema")
        descriptor.mode="inspection";self.descriptor=descriptor
    }
    public func detect() async -> DetectionResult {await detect(using:DiscoveryEngine(home:home))}
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult {discovery.detect(rule)}
    public func health() async -> CollectorHealth {currentHealth}
    public func collect(store:EventStore) async throws -> CollectionResult {
        let run=try await store.beginRun(collectorID:descriptor.id);var health=CollectorHealth();health.status="no_token_records";health.compatibility="no_usage_parser_verified"
        let fm=FileManager.default;var directories=0;var candidates=0
        let excluded=["auth","credential","secret","cookie","preferences","config","settings","local state","trust tokens"]
        for root in descriptor.sourceRoots {
            guard fm.fileExists(atPath:root) else{continue}
            directories+=1
            guard fm.isReadableFile(atPath:root) else{health.status="permission_denied";health.errors.append("Permission denied: "+root);continue}
            guard let iterator=fm.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else{continue}
            var visited=0
            while let file=iterator.nextObject() as? URL {
                if iterator.level>3 {iterator.skipDescendants();continue}
                let properties=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                if properties?.isSymbolicLink==true {iterator.skipDescendants();continue}
                if excluded.contains(where:{file.lastPathComponent.lowercased().contains($0)}) {iterator.skipDescendants();continue}
                if ["Cache","Code Cache","GPUCache","WebKit","node_modules"].contains(file.lastPathComponent) {iterator.skipDescendants();continue}
                guard properties?.isRegularFile==true else{continue}
                visited+=1;if visited>96 {break}
                if ["log","jsonl"].contains(file.pathExtension) {
                    let attrs=try? fm.attributesOfItem(atPath:file.path)
                    guard (attrs?[.size] as? NSNumber)?.intValue ?? Int.max<=2*1024*1024 else{continue}
                    let signature="\(attrs?[.size] ?? 0):\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                    let old=try await store.cursor(path:file.path)
                    if old?.boundaryHash==signature {candidates+=old?.state.counters?["candidate"]==1 ? 1:0;health.files+=1;continue}
                    let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
                    let data=try handle.readToEnd() ?? Data();health.bytesRead+=UInt64(data.count);health.files+=1
                    let keys=["\"input_tokens\"","\"output_tokens\"","\"prompt_tokens\"","\"completion_tokens\"","\"total_tokens\"","\"usageMetadata\"","\"tokenUsage\""]
                    let found=keys.contains{data.range(of:Data($0.utf8)) != nil}
                    if found {candidates+=1}
                    var cursor=SourceCursor(path:file.path,identity:"inspection",parserVersion:descriptor.parserVersion);cursor.boundaryHash=signature;cursor.state.counters=["candidate":found ? 1:0]
                    _=try await store.commit(events:[],cursor:cursor,collectorID:descriptor.id)
                } else if ["sqlite","db","vscdb"].contains(file.pathExtension) {
                    health.files+=1
                    // Read schema only, never message bodies, login stores or encrypted files.
                    if let db=try? ReadOnlySourceDatabase(path:file.path),let statement=try? db.prepare("SELECT sql FROM sqlite_master WHERE type='table'") {
                        while sqlite3_step(statement)==SQLITE_ROW {
                            let schema=db.string(statement,0)?.lowercased() ?? ""
                            if ["input_tokens","output_tokens","prompt_tokens","completion_tokens","total_tokens"].contains(where:{schema.contains($0)}) {candidates+=1}
                        };sqlite3_finalize(statement)
                    }
                }
            }
        }
        if candidates>0 {health.status="candidate_source";health.errors.append("Candidate usage fields found; request identity, timestamps and semantics require validation")}
        else if directories==0 {health.status="source_unavailable";health.errors.append("No readable local usage directory was found in the checked rules")}
        else {health.errors.append("Checked local log/schema metadata; no validated Token records. Conversation text, credits and quotas are not Token counts")}
        health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health);try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
    }
    public static func roots(for id:String,home:String) -> [String] {
        let paths:[String:[String]]=[
            "chatgpt":["Library/Containers/com.openai.chat/Data/Library/Application Support","Library/Application Support/com.openai.chat"],
            "claude-desktop":["Library/Logs/Claude","Library/Application Support/Claude"],
            "kimi-desktop":["Library/Application Support/kimi/logs"],
            "minimax":["Library/Logs/MiniMax",".minimax-agent-cn"],
            "manus":["Library/Logs/Manus","Library/Application Support/Manus"],
            "doubao":["Library/Application Support/Doubao"],
            "yuanbao":["Library/Containers/com.tencent.yuanbao/Data/Library/Users","Library/Application Support/com.tencent.yuanbao"],
            "copilot":[".copilot/session-state",".copilot"]]
        return (paths[id] ?? []).map{home+"/"+$0}
    }
}
