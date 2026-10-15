import Foundation

/// Qwen's independent monthly ledger, not its overlapping chat transcripts.
public final class QwenLedgerParserV1: UsageParser {
    public let version = "qwen-token-ledger-v1.0.0"
    public init() {}
    public func parse(_ data: Data, state: inout ParserState, context: ParseContext) throws -> UsageEvent? {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              try Utilities.token(row, "schemaVersion") == 1 else {
            throw CoreError.invalid("Parser incompatible: Qwen ledger schemaVersion")
        }
        guard let id = row["id"] as? String, !id.isEmpty,
              let session = row["sessionId"] as? String, !session.isEmpty else {
            throw CoreError.invalid("Parser incompatible: Qwen ledger identity")
        }
        var metrics = TokenMetrics()
        metrics.input = Metric(try Utilities.token(row, "inputTokens"))
        let output = try Utilities.token(row, "outputTokens")
        let thoughts = try Utilities.token(row, "thoughtsTokens")
        if let output, let thoughts { metrics.output = Metric(output + thoughts) }
        metrics.reasoning = Metric(thoughts)
        metrics.cacheRead = Metric(try Utilities.token(row, "cachedTokens"))
        metrics.cacheWrite = Metric(state: .unsupported)
        metrics.total = Metric(try Utilities.token(row, "totalTokens"))
        guard metrics.total.value != nil || metrics.input.value != nil || output != nil else {
            throw CoreError.invalid("Parser incompatible: Qwen ledger counters missing")
        }
        // The writer substitutes 0 for absent/invalid provider usage. Retain the
        // source value but disclose lost reliability, including input lower bounds.
        for key in TokenMetrics.names {
            switch key {
            case "input": if metrics.input.value != nil { metrics.input.state = .partial }
            case "output": if metrics.output.value != nil { metrics.output.state = .partial }
            case "total": if metrics.total.value != nil { metrics.total.state = .partial }
            case "reasoning": if metrics.reasoning.value != nil { metrics.reasoning.state = .partial }
            case "cacheRead": if metrics.cacheRead.value != nil { metrics.cacheRead.state = .partial }
            default: break
            }
        }
        state.sessionID = session
        let model = row["model"] as? String
        state.model = model == "unknown" || model?.isEmpty == true ? nil : model
        state.provider = nil // authType is an authentication mode, not a provider.
        state.cwd = nil
        var raw: [String: Int64] = [:]
        for key in ["inputTokens", "outputTokens", "cachedTokens", "thoughtsTokens", "totalTokens"] {
            raw[key] = try Utilities.token(row, key)
        }
        var metadata = ["reported_usage": try Utilities.json(raw),
                        "counting_method": "independent_request_ledger", "usage_scope": "request",
                        "input_semantics": "cached tokens included; input may be a lower bound",
                        "output_semantics": "candidate output plus thoughts",
                        "source_reliability": "upstream normalized; missing/invalid counters may become zero",
                        "total_semantics": "upstream reported or derived; origin not retained"]
        for key in ["localDate", "localMonth"] {
            if let value = row[key] as? String,
               value.range(of: key == "localDate" ? "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" : "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil {
                metadata[key] = value
            }
        }
        // Arbitrary subagent names can contain user content; persist scope only.
        if let source = row["source"] as? String { metadata["agent_scope"] = source == "main" ? "main" : "subagent" }
        if let input = metrics.input.value, let output = metrics.output.value, let total = metrics.total.value {
            metadata["component_reconciliation"] = input + output == total ? "matched" : "mismatch"
        }
        var event = try context.event(timestamp: row["timestamp"] as? String, identity: "ledger:" + id,
                                      metrics: metrics, state: state, parser: version, metadata: metadata, partial: true)
        event.sourceType = "local_token_ledger_jsonl"
        return event
    }
}

public enum QwenCollector {
    public static func make(roots: [String], home: String) -> JSONLCollector {
        let parser = QwenLedgerParserV1()
        let descriptor = CollectorDescriptor(id: "qwen-local", agentID: "qwen", name: "Qwen Code", version: "1.0.0",
            parserVersion: parser.version, supportedAgentVersions: ["Qwen monthly usage ledger schema 1; pinned 9cdb0f3"],
            capabilities: ["input": .conditional, "output": .conditional, "total": .conditional,
                           "cacheRead": .conditional, "cacheWrite": .unsupported, "reasoning": .conditional,
                           "cachedOutput": .unsupported, "model": .conditional, "session": .supported,
                           "project": .unsupported, "cost": .unsupported],
            sourceRoots: roots, sourceDescription: "Qwen Code independent monthly Token ledger (upstream normalized counters)")
        return JSONLCollector(descriptor: descriptor, parser: parser, rule: DiscoveryEngine.catalog.first { $0.id == "qwen" }!, home: home)
    }
}
