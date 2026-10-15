import Foundation

public protocol UsageParser: AnyObject {
    var version: String { get }
    func prepare() throws
    func parse(_ data: Data, state: inout ParserState, context: ParseContext) throws -> UsageEvent?
}
public extension UsageParser { func prepare() throws {} }

public struct ParseContext {
    public var agentID: String
    public var agentName: String
    public var collectorID: String
    public var collectorVersion: String
    public var path: String
    public var line: Int
    public var offset: UInt64
    public var projects: ProjectDetector
    public init(agentID: String, agentName: String, collectorID: String, collectorVersion: String = "1.0.0",
                path: String, line: Int = 1, offset: UInt64 = 0, projects: ProjectDetector = ProjectDetector()) {
        self.agentID = agentID; self.agentName = agentName; self.collectorID = collectorID
        self.collectorVersion = collectorVersion; self.path = path; self.line = line; self.offset = offset; self.projects = projects
    }
    func event(timestamp: String?, identity: String, metrics: TokenMetrics, state: ParserState,
               parser: String, metadata: [String: String] = [:], partial: Bool = false) throws -> UsageEvent {
        guard let timestamp, let d = Utilities.date(timestamp) else { throw CoreError.invalid("Parser incompatible: usage timestamp missing or invalid") }
        let sourceID = agentID + ":" + identity
        return UsageEvent(id: Utilities.hash(sourceID), timestamp: Utilities.iso(d), agentID: agentID, agentName: agentName,
                          provider: state.provider, model: state.model, rawModelName: state.model, sessionID: state.sessionID,
                          workingDirectory: state.cwd, project: projects.detect(cwd: state.cwd), metrics: metrics,
                          sourceType: "local_jsonl", sourcePath: path, sourceEventID: sourceID, sourceLine: line, sourceOffset: offset,
                          collectorID: collectorID, collectorVersion: collectorVersion, parserVersion: parser,
                          confidence: partial ? 0.8 : 1, quality: partial ? "partial" : "exact",
                          fingerprint: Utilities.hash(sourceID), sourceMetadata: metadata, createdAt: Utilities.iso())
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CoreError.invalid("Parser incompatible: expected JSON object")
    }
    return obj
}
private func count(_ obj: [String: Any], _ key: String, unsupported: Bool = false) throws -> Metric {
    Metric(try Utilities.token(obj, key), state: unsupported ? .unsupported : .notAvailable)
}
private func counters(_ obj: [String: Any]) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    for k in ["input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens", "total_tokens"] {
        if let v = try Utilities.token(obj, k) { result[k] = v }
    }
    guard result["total_tokens"] != nil else { throw CoreError.invalid("Parser incompatible: cumulative total_tokens missing") }
    return result
}
private func codexMetrics(_ usage: [String: Any]) throws -> TokenMetrics {
    var m = TokenMetrics()
    m.input = try count(usage, "input_tokens"); m.output = try count(usage, "output_tokens")
    m.cacheRead = try count(usage, "cached_input_tokens"); m.cacheWrite = try count(usage, "cache_write_input_tokens")
    m.reasoning = try count(usage, "reasoning_output_tokens"); m.total = try count(usage, "total_tokens")
    guard m.total.value != nil else { throw CoreError.invalid("Parser incompatible: request total_tokens missing") }
    return m
}

public final class CodexParserV1: UsageParser {
    public let version = "codex-jsonl-v1.2.0"
    public init() {}
    public func parse(_ data: Data, state: inout ParserState, context: ParseContext) throws -> UsageEvent? {
        // Type is in the first small prefix of Codex JSONL. Do not decode conversation payloads.
        let prefix = String(decoding: data.prefix(300), as: UTF8.self) + String(decoding: data.suffix(300), as: UTF8.self)
        guard ["session_meta", "turn_context", "thread_settings_applied", "token_usage_record", "token_count"].contains(where: { prefix.contains("\"" + $0 + "\"") }) else { return nil }
        let obj = try object(data); let type = obj["type"] as? String
        let p = obj["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" {
            state.sessionID = p["id"] as? String; state.rootSessionID = p["session_id"] as? String; state.cwd = p["cwd"] as? String
            state.provider = p["model_provider"] as? String; state.agentVersion = p["cli_version"] as? String
            state.forkedFrom = p["forked_from_id"] as? String
            state.sessionRecordTimestamp = obj["timestamp"] as? String
            state.historyStartOrdinal = p["forked_from_ordinal_exclusive"] as? Int ?? p["subagent_history_start_ordinal"] as? Int
            return nil
        }
        if type == "event_msg",p["type"] as? String=="thread_settings_applied",let owner=p["thread_id"] as? String,let settings=p["thread_settings"] as? [String:Any] {
            if state.threadContexts==nil {state.threadContexts=[:]}
            let context=SourceThreadContext(model:settings["model"] as? String,provider:settings["model_provider_id"] as? String,cwd:settings["cwd"] as? String)
            state.threadContexts?[owner]=context
            if owner==state.sessionID {state.model=context.model;state.provider=context.provider;state.cwd=context.cwd ?? state.cwd}
            return nil
        }
        if type == "turn_context" {
            state.model = p["model"] as? String; state.cwd = p["cwd"] as? String ?? state.cwd
            return nil
        }
        guard state.sessionID != nil else {
            if type == "token_usage_record" || p["type"] as? String == "token_count" { throw CoreError.invalid("Parser incompatible: Codex session metadata missing") }
            return nil
        }
        if type == "token_usage_record" {
            guard let u = p["usage"] as? [String: Any], let responseID = p["response_id"] as? String, !responseID.isEmpty else {
                throw CoreError.invalid("Parser incompatible: Codex request usage/response_id missing")
            }
            let m = try codexMetrics(u)
            let owner=p["thread_id"] as? String ?? state.sessionID!
            // Explicit logical ownership survives copies into another rollout file.
            // Unowned legacy copies still need the verified inheritance boundary.
            if isInherited(obj,state) && (p["thread_id"] == nil || owner == state.sessionID) { return nil }
            if owner == state.sessionID {
                if let c = p["thread_token_usage"] as? [String: Any] { state.counters = try counters(c) }
                state.preciseRequests = true
            }
            var attribution=state;attribution.sessionID=owner
            if owner != state.sessionID {
                let context=state.threadContexts?[owner]
                attribution.model=context?.model;attribution.provider=context?.provider;attribution.cwd=context?.cwd
            }
            var meta = ["reported_usage": Utilities.sourceUsage(u), "counting_method": "request_usage", "agent_version": state.agentVersion ?? "unknown", "thread_id":owner, "response_id":responseID,"physical_thread_id":state.sessionID ?? "unknown","owner_matches_file":owner==state.sessionID ? "true":"false"]
            for key in ["turn_id","root_turn_id","session_id"] { if let value=p[key] as? String {meta[key]=value} }
            if let root=state.rootSessionID {meta["root_session_id"]=p["session_id"] as? String ?? root}
            if owner != state.sessionID {
                meta["timestamp_semantics"]="Timestamp reported by copied rollout; original execution time is not independently verified"
                meta["attribution_quality"]="partial"
            }
            return try context.event(timestamp: obj["timestamp"] as? String, identity: "thread:"+owner+":response:"+responseID,
                                     metrics: m, state: attribution, parser: version, metadata: meta,partial:owner != state.sessionID)
        }
        guard type == "event_msg", p["type"] as? String == "token_count" else { return nil }
        // Once request records exist, legacy session/thread snapshots are redundant and can have a different scope.
        if state.preciseRequests == true { return nil }
        guard let info = p["info"] as? [String: Any] else { return nil } // Context/limit-only notifications.
        guard let raw = info["total_token_usage"] as? [String: Any] else { throw CoreError.invalid("Parser incompatible: Codex total_token_usage missing") }
        let next = try counters(raw)
        if isInherited(obj,state) { state.counters = next; return nil }
        if next == state.counters { return nil }
        let previousCounters=state.counters
        var delta = next; var partial = false;var method="cumulative_difference"
        if let previous = state.counters {
            if next["total_tokens"] == previous["total_tokens"] { state.counters = next; return nil }
            if next["total_tokens",default:0] < previous["total_tokens",default:0] {
                // Local fixtures demonstrate delayed/stale cumulative snapshots. Keep the high-water mark.
                state.warn("Out-of-order cumulative snapshot ignored; legacy attribution coverage is partial")
                return nil
            }
            for (k,v) in next {
                if let old = previous[k] {
                    if v < old {
                        delta.removeValue(forKey:k);partial = true
                        state.warn("Legacy cumulative component corrected by source; breakdown unavailable for this interval")
                    } else {delta[k] = v - old}
                } else { delta.removeValue(forKey: k); partial = true }
            }
        } else if let last = info["last_token_usage"] as? [String: Any] {
            let lastCounters = try counters(last)
            if lastCounters["total_tokens"] != next["total_tokens"] {
                delta = lastCounters; partial = true
                method="last_request_in_partial_history"
                state.warn("History baseline unavailable: first cumulative snapshot exceeds last request")
            }
        } else {
            throw CoreError.invalid("Parser incompatible: first Codex snapshot lacks last_token_usage")
        }
        state.counters = next
        let m = try codexMetrics(delta)
        guard m.total.value != 0 else { return nil }
        let signature = try Utilities.json(next)
        let identity = "counter:" + Utilities.hash((obj["timestamp"] as? String ?? "") + ":" + signature)
        var metadata=["reported_usage":Utilities.sourceUsage(raw),"counting_method":method,"agent_version":state.agentVersion ?? "unknown"]
        if let previousCounters{metadata["previous_cumulative_usage"]=try Utilities.json(previousCounters)}
        if let last=info["last_token_usage"] as? [String:Any]{metadata["last_request_usage"]=Utilities.sourceUsage(last)}
        if let root=state.rootSessionID {metadata["root_session_id"]=root}
        if let thread=state.sessionID {metadata["thread_id"]=thread}
        if !state.warnings.isEmpty{metadata["coverage_notes"]=state.warnings.joined(separator:"; ")}
        return try context.event(timestamp: obj["timestamp"] as? String, identity: identity, metrics: m, state: state, parser: version,
                                 metadata:metadata,partial:partial || !state.warnings.isEmpty)
    }
    private func isInherited(_ obj:[String:Any],_ state:ParserState) -> Bool {
        guard state.forkedFrom != nil else {return false}
        if let boundary=state.historyStartOrdinal,let ordinal=obj["ordinal"] as? Int {return ordinal<boundary}
        return obj["timestamp"] as? String == state.sessionRecordTimestamp
    }
}

public final class ClaudeParserV1: UsageParser {
    public let version = "claude-jsonl-v1.1.0"
    public init() {}
    public func parse(_ data: Data, state: inout ParserState, context: ParseContext) throws -> UsageEvent? {
        // Claude Desktop Code-tab sessions share the local project JSONL with Claude Code CLI.
        // Read only the top-level entrypoint field from user/assistant envelopes; never retain content.
        if data.range(of: Data("\"entrypoint\"".utf8)) != nil,
           let header = try? JSONDecoder().decode(ClaudeEntrypointHeader.self, from: data),
           ["user", "assistant", "system"].contains(header.type ?? ""),
           let entrypoint = header.entrypoint {
            state.sourceEntrypoint = ["cli", "claude-desktop", "sdk", "claude-code"].contains(entrypoint)
                ? entrypoint : "other"
        }
        // Avoid decoding known queue/user/tool records, including their content.
        let prefix = String(decoding: data.prefix(1500), as: UTF8.self)
        guard prefix.contains("\"assistant\"") else { return nil }
        let obj = try object(data)
        guard obj["type"] as? String == "assistant", let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any] else { return nil }
        if msg["model"] as? String == "<synthetic>" { return nil }
        guard let id = msg["id"] as? String, !id.isEmpty else { throw CoreError.invalid("Parser incompatible: Claude message.id missing") }
        state.sessionID = obj["sessionId"] as? String; state.cwd = obj["cwd"] as? String
        state.model = msg["model"] as? String
        state.provider = msg["provider"] as? String ?? obj["provider"] as? String
        state.agentVersion = obj["version"] as? String
        let input = try Utilities.token(u, "input_tokens"), read = try Utilities.token(u, "cache_read_input_tokens"), write = try Utilities.token(u, "cache_creation_input_tokens")
        var m = TokenMetrics()
        m.input = Metric(input.flatMap { i in read.flatMap { r in write.map { w in i + r + w } } })
        m.output = try count(u, "output_tokens"); m.cacheRead = Metric(read); m.cacheWrite = Metric(write)
        if let d = u["output_tokens_details"] as? [String: Any] { m.reasoning = try count(d, "thinking_tokens") }
        m.total = Metric(m.input.value.flatMap { i in m.output.value.map { i + $0 } })
        guard input != nil || m.output.value != nil else { throw CoreError.invalid("Parser incompatible: Claude usage lacks token counters") }
        let request = obj["requestId"] as? String
        return try context.event(timestamp: obj["timestamp"] as? String, identity: "message:" + (request.map { $0 + ":" } ?? "") + id,
                                 metrics: m, state: state, parser: version,
                                 metadata: ["reported_usage": Utilities.sourceUsage(u), "counting_method": "message_snapshot_upsert",
                                            "input_semantics": "uncached_plus_cache_read_plus_cache_write", "agent_version": state.agentVersion ?? "unknown",
                                            "entrypoint": state.sourceEntrypoint ?? "legacy_or_unknown"],
                                 partial: m.total.value == nil)
    }
}

private struct ClaudeEntrypointHeader: Decodable {
    var type: String?
    var entrypoint: String?
}
public final class PiParserV1: UsageParser {
    public let version = "pi-session-v3.1.0"
    public init() {}
    public func parse(_ data: Data, state: inout ParserState, context: ParseContext) throws -> UsageEvent? {
        let obj = try object(data); let type = obj["type"] as? String
        if type == "session" {
            guard let v = obj["version"] as? Int, v == 3 else { throw CoreError.invalid("Parser incompatible: Pi requires session format version 3") }
            state.sessionID = obj["id"] as? String; state.cwd = obj["cwd"] as? String; state.agentVersion = "session-format-3"
            return nil
        }
        if type == "model_change" { state.model = obj["modelId"] as? String; state.provider = obj["provider"] as? String; return nil }
        let msg = obj["message"] as? [String: Any] ?? [:]
        let summary = type == "compaction" || type == "branch_summary"
        guard (type == "message" && ["assistant","toolResult"].contains(msg["role"] as? String ?? "")) || type == "usage" || summary else { return nil }
        guard let u = (type == "message" ? msg["usage"] : obj["usage"]) as? [String: Any] else { return nil }
        guard let id = obj["id"] as? String, state.sessionID != nil else { throw CoreError.invalid("Parser incompatible: Pi entry/session ID missing") }
        var attribution = state
        attribution.model = (type == "message" ? (msg["responseModel"] ?? msg["model"]) : obj["model"]) as? String
        attribution.provider = (type == "message" ? msg["provider"] : obj["provider"]) as? String
        let input = try Utilities.token(u, "input"), read = try Utilities.token(u, "cacheRead"), write = try Utilities.token(u, "cacheWrite")
        var m = TokenMetrics()
        m.input = Metric(input.flatMap { i in read.flatMap { r in write.map { w in i + r + w } } })
        m.output = try count(u, "output"); m.cacheRead = Metric(read); m.cacheWrite = Metric(write)
        m.reasoning = try count(u, "reasoning"); m.total = try count(u, "totalTokens")
        guard input != nil || m.total.value != nil else { throw CoreError.invalid("Parser incompatible: Pi usage lacks token counters") }
        var meta = ["reported_usage": Utilities.sourceUsage(u), "counting_method": "entry_usage", "input_semantics": "uncached_plus_cache_read_plus_cache_write", "entry_type": type ?? "unknown", "usage_category": msg["role"] as? String == "toolResult" || summary ? "tool_summary":"model", "model_attribution": attribution.model == nil ? "unknown":"source_reported"]
        if let c = u["cost"] as? [String: Any], let v = c["total"] as? NSNumber { meta["unverified_reported_cost"] = v.stringValue }
        if msg["stopReason"] as? String == "error", m.total.value == 0 {
            m = TokenMetrics(); meta["availability_reason"] = "Error response has empty usage; actual consumption unavailable"
        }
        let totalParts = m.input.value.flatMap { i in m.output.value.map { i + $0 } }
        let partial = (totalParts != m.total.value) || (summary && attribution.model == nil) || m.total.value == nil
        if totalParts != nil && m.total.value != nil && totalParts != m.total.value { state.warn("Pi source total differs from component sum; source total preserved") }
        let identity = "entry:" + id + ":" + (obj["timestamp"] as? String ?? "")
        return try context.event(timestamp: obj["timestamp"] as? String, identity: identity, metrics: m, state: attribution,
                                 parser: version, metadata: meta, partial: partial)
    }
}
