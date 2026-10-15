import Foundation

public struct Reconciliation: Codable, Sendable {
    public var status:String
    public var checkedAt:String
    public var sourceCount:Int
    public var collectedCount:Int
    public var sourceTotal:Int64?
    public var collectedTotal:Int64?
    public var scope:String
}
public struct HistoricalModelUsage:Codable,Sendable {
    public var model:String
    public var input:Metric
    public var output:Metric
    public var cacheRead:Metric
    public var cacheWrite:Metric
}
public struct HistoricalUsageEvidence:Codable,Sendable {
    public var sourcePath:String
    public var parserVersion:String="claude-stats-cache-v1-v3.1.1"
    public var lastComputedDate:String?
    public var startDate:String?
    public var endDate:String?
    public var reportedSessions:Int?
    public var models:[HistoricalModelUsage]
}
public struct SourceCoverage:Codable,Sendable {
    public var status:String
    public var scope:String
    public var earliest:String?
    public var latest:String?
    public var records:Int
    public var completeHistoryVerified:Bool=false
    public var reconciliation:Reconciliation?
    public var historical:HistoricalUsageEvidence?
    public var traceEvidence:WorkBuddyTraceEvidence?
    public var notes:[String]
    public var errors:[String]=[]
    public static func make(descriptor:CollectorDescriptor,health:CollectorHealth,earliest:String?,latest:String?,records:Int) -> Self {
        var value=Self(status:descriptor.mode=="inspection" ? "source_unverified":"retained_records",scope:"Coverage refers to all collected records for this Agent, independent of dashboard filters.",earliest:earliest,latest:latest,records:records,reconciliation:health.reconciliation,notes:["Collector health describes parsing, not complete history.","Deleted and remote history may be absent."])
        if health.reconciliation?.status=="matched" {value.status="local_reconciled"}
        if health.reconciliation?.status=="mismatch" {value.status="local_mismatch"}
        if descriptor.agentID=="gemini" {value.notes.append("Gemini CLI may automatically delete old sessions; imported metadata is retained.")}
        if descriptor.agentID=="qwen" {value.notes.append("Qwen ledger counters are upstream normalized; zero may mean missing usage and input may be a lower bound. Chat transcripts are not added.")}
        if descriptor.agentID=="cline" {value.notes.append("Only historical task request carriers are collected; deleted/subagent aggregates and new SDK session totals are excluded. Missing cache counters prevent a complete total.")}
        if descriptor.agentID=="codex" {value.notes.append("Thread cumulative totals and copied fork history are not added to request usage.")}
        if descriptor.agentID=="deepseek-harness" {value.notes.append("The local ledger matches the installed UI; upstream format identity is unverified.")}
        if descriptor.agentID=="workbuddy" {value.notes.append("Workflow traces can overlap transcript requests; unmatched trace totals are not added.")}
        if descriptor.agentID=="claude-desktop" {value.notes.append("Claude Desktop chats and Cowork are inspection-only until a local request-level Token source is verified. Desktop Code-tab requests share Claude Code logs; their entrypoint is shown when reported, while legacy records remain unattributed.")}
        if descriptor.agentID=="claude-code",let root=descriptor.sourceRoots.first(where:{$0.hasSuffix("/.claude/projects")}) {
            let path=URL(fileURLWithPath:root).deletingLastPathComponent().appendingPathComponent("stats-cache.json")
            if FileManager.default.fileExists(atPath:path.path) {
                do {
                    value.historical=try ClaudeHistoricalUsageReader.read(path)
                    value.status="historical_aggregate_available"
                    if let last=value.historical?.endDate,let earliest, String(earliest.prefix(10))>last {value.status="historical_gap"}
                    value.notes.append("Historical cache has no request identities and is not included in usage totals.")
                } catch {value.errors.append("Historical usage cache cannot be verified")}
            }
        }
        return value
    }
}
public enum ClaudeHistoricalUsageReader {
    private struct Cache:Decodable {
        var version:Int
        var lastComputedDate:String?
        var totalSessions:Int?
        var dailyModelTokens:[Day]?
        var modelUsage:[String:Model]?
    }
    private struct Day:Decodable {var date:String}
    private struct Model:Decodable {var inputTokens:Int64?;var outputTokens:Int64?;var cacheReadInputTokens:Int64?;var cacheCreationInputTokens:Int64?}
    public static func read(_ path:URL) throws -> HistoricalUsageEvidence {
        let attrs=try FileManager.default.attributesOfItem(atPath:path.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max<=2*1024*1024 else {throw CoreError.invalid("Historical cache exceeds metadata limits")}
        let cache=try JSONDecoder().decode(Cache.self,from:Data(contentsOf:path))
        guard [1,2,3].contains(cache.version) else {throw CoreError.invalid("Parser incompatible: Claude historical cache version")}
        func date(_ value:String?) -> String? {guard let value,value.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil else{return nil};return value}
        func metric(_ value:Int64?) throws -> Metric {guard value==nil || value!>=0 else{throw CoreError.invalid("Invalid historical cache counter")};return Metric(value,state:.unknown)}
        let dates=(cache.dailyModelTokens ?? []).compactMap{date($0.date)}.sorted()
        let models=try (cache.modelUsage ?? [:]).sorted{$0.key<$1.key}.map { model,usage in
            guard model.utf8.count<=512 else{throw CoreError.invalid("Invalid historical model identifier")}
            return HistoricalModelUsage(model:model,input:try metric(usage.inputTokens),output:try metric(usage.outputTokens),cacheRead:try metric(usage.cacheReadInputTokens),cacheWrite:try metric(usage.cacheCreationInputTokens))
        }
        return HistoricalUsageEvidence(sourcePath:path.path,lastComputedDate:date(cache.lastComputedDate),startDate:dates.first,endDate:dates.last,reportedSessions:cache.totalSessions.flatMap{$0>=0 ? $0:nil},models:models)
    }
}
