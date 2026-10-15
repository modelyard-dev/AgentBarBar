import Foundation

/// WorkBuddy's persisted SDK records attach usage to assistant messages or tool-call items.
/// A provider message ID identifies the LLM request; trace/conversation IDs span many requests.
public final class WorkBuddyParserV1: UsageParser {
    public let version="workbuddy-jsonl-v1.0.1"
    public init() {}
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        guard data.range(of:Data("\"usage\"".utf8)) != nil else{return nil}
        guard let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let message=row["message"] as? [String:Any],let usage=message["usage"] as? [String:Any] else{return nil}
        let type=row["type"] as? String
        guard type=="function_call" || (type=="message" && row["role"] as? String=="assistant") else{return nil}
        guard let providerData=row["providerData"] as? [String:Any],let id=providerData["messageId"] as? String,!id.isEmpty,
              let session=row["sessionId"] as? String,!session.isEmpty,let timestamp=row["timestamp"] else{
            throw CoreError.invalid("Parser incompatible: WorkBuddy request/session identity missing")
        }
        var metrics=TokenMetrics()
        metrics.input=Metric(try Utilities.token(usage,"input_tokens"));metrics.output=Metric(try Utilities.token(usage,"output_tokens"))
        metrics.total=Metric(try Utilities.token(usage,"total_tokens"));metrics.cacheRead=Metric(try Utilities.token(usage,"cache_read_input_tokens"))
        metrics.cacheWrite=Metric(state:.unsupported)
        let raw=providerData["rawUsage"] as? [String:Any] ?? [:]
        if let detail=raw["completion_tokens_details"] as? [String:Any] {metrics.reasoning=Metric(try Utilities.token(detail,"reasoning_tokens"))}
        guard let input=metrics.input.value,let output=metrics.output.value,let total=metrics.total.value else{
            throw CoreError.invalid("Parser incompatible: WorkBuddy request counters missing")
        }
        let partial=input+output != total || (metrics.cacheRead.value ?? 0)>input || (metrics.reasoning.value ?? 0)>output
        if partial {state.warn("WorkBuddy source counters are inconsistent; reported values retained")}
        let reportedReasoning=metrics.reasoning.value
        if let reasoning=reportedReasoning,reasoning>output {metrics.reasoning=Metric(state:.unknown)}
        if let cached=metrics.cacheRead.value,cached>input {metrics.cacheRead=Metric(state:.unknown)}
        state.sessionID=session;state.cwd=row["cwd"] as? String
        state.model=providerData["model"] as? String;state.provider=providerData["provider"] as? String
        var metadata=["reported_usage":Utilities.sourceUsage(usage),"counting_method":"provider_message_usage","input_semantics":"reported input includes cache reads"]
        if let reasoning=reportedReasoning {metadata["reported_reasoning_tokens"]=String(reasoning)}
        if let requested=providerData["requestModelId"] as? String {metadata["requested_model"]=requested}
        return try context.event(timestamp:Utilities.iso(sourceDate(timestamp,scale:1000)),identity:"message:"+id,
            metrics:metrics,state:state,parser:version,metadata:metadata,partial:partial)
    }
}

/// DeepSeek Harness wraps pi-ai responses in its own versioned, compressed session envelope.
public final class DeepSeekParserV1: UsageParser {
    public let version="dsh-session-v0-v3-v4.0.1"
    public init() {}
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        guard ["session","request/header","request\\/header","assistant/message","assistant\\/message"].contains(where:{data.range(of:Data(("\""+$0+"\"").utf8)) != nil}) else{return nil}
        guard let row=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CoreError.invalid("Parser incompatible: DeepSeek session object")}
        if row["type"] as? String=="session" {
            guard let version=row["version"] as? Int,[0,3,4].contains(version),let id=row["id"] as? String,!id.isEmpty else{
                throw CoreError.invalid("Parser incompatible: DeepSeek requires session format 0, 3 or 4")
            }
            state.sessionID=id;state.cwd=row["cwd"] as? String;state.agentVersion="session-format-"+String(version)
            return nil
        }
        let payload=row["data"] as? [String:Any] ?? [:]
        if row["type"] as? String=="request/header" {
            let header=payload["header"] as? [String:Any] ?? [:];let config=header["config"] as? [String:Any] ?? [:]
            state.model=config["model"] as? String;state.provider=config["provider"] as? String;return nil
        }
        guard row["type"] as? String=="assistant/message",let usage=payload["usage"] as? [String:Any],
              let message=payload["message"] as? [String:Any],message["role"] as? String=="assistant" else{return nil}
        let source=message["source"] as? [String:Any] ?? [:]
        guard source["kind"] as? String=="model" else{return nil}
        guard let id=message["id"] as? String,!id.isEmpty,state.sessionID != nil,let timestamp=row["time"] else{
            throw CoreError.invalid("Parser incompatible: DeepSeek request identity/timestamp missing")
        }
        var metrics=TokenMetrics();let uncached=try Utilities.token(usage,"inputTokens")
        metrics.output=Metric(try Utilities.token(usage,"outputTokens"));metrics.total=Metric(try Utilities.token(usage,"totalTokens"))
        metrics.cacheRead=Metric(try Utilities.token(usage,"cacheReadTokens"));metrics.cacheWrite=Metric(state:.unsupported);metrics.reasoning=Metric(state:.unsupported)
        guard let output=metrics.output.value else{throw CoreError.invalid("Parser incompatible: DeepSeek output counter missing")}
        // Upgraded sessions retain older component-only requests inside newer headers.
        let legacy=metrics.total.value==nil
        var partial=legacy
        if legacy {
            guard let uncached else{throw CoreError.invalid("Parser incompatible: DeepSeek legacy input counter missing")}
            if let cache=metrics.cacheRead.value {
                metrics.input=Metric(uncached+cache);metrics.total=Metric(uncached+cache+output)
            } else {
                metrics.input=Metric(state:.unknown);metrics.total=Metric(state:.unknown)
                state.warn("DeepSeek legacy cache counter is missing; input and total are Unknown")
            }
        } else {
            guard let total=metrics.total.value,total>=output else{throw CoreError.invalid("Parser incompatible: DeepSeek total/output counters")}
            // Reported total covers cached components even when the optional breakdown is absent.
            metrics.input=Metric(total-output)
            partial=uncached.map{$0+(metrics.cacheRead.value ?? 0) != total-output} ?? true
            if partial {state.warn("DeepSeek component coverage differs from reported total; total retained")}
        }
        var attribution=state;attribution.model=source["model"] as? String ?? state.model;attribution.provider=source["provider"] as? String ?? state.provider
        let response=(source["replayState"] as? [String:Any])?["response"] as? [String:Any] ?? [:]
        if response["stopReason"] as? String=="error" && (metrics.total.value==0 || (legacy && metrics.total.value==nil && uncached==0 && output==0)) {return nil}
        let responseID=response["responseId"] as? String
        let identity=responseID.map{"response:"+(attribution.provider ?? "unknown")+":"+$0} ?? "message:"+id
        var counters:[String:Int64]=[:]
        for key in ["inputTokens","outputTokens","totalTokens","cacheReadTokens"] {counters[key]=try Utilities.token(usage,key)}
        var metadata=["reported_usage":try Utilities.json(counters),"source_message_id":id,"counting_method":"completed_model_message",
                      "input_semantics":"reported total minus reported output","session_format":state.agentVersion ?? "unknown"]
        if legacy {
            metadata["counting_method"]="legacy_recorded_components";metadata["input_semantics"]="reported uncached input plus explicitly reported cache reads"
            metadata["coverage_notes"]="Legacy source has no reported total; missing cache counts remain Unknown"
        }
        if let responseID {metadata["provider_response_id"]=responseID}
        var event=try context.event(timestamp:Utilities.iso(sourceDate(timestamp,scale:1000)),identity:identity,
            metrics:metrics,state:attribution,parser:version,metadata:metadata,partial:partial)
        event.sourceType="local_zstd_jsonl";return event
    }
}
