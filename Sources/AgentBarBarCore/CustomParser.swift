import Foundation

public final class CustomJSONLParserV1: UsageParser {
    public let version="custom-jsonl-v1.0.0"
    private let configuration:CustomAgent
    public init(_ configuration:CustomAgent) { self.configuration=configuration }
    private func get(_ obj:[String:Any],_ name:String) -> Any? {
        guard let path=configuration.mapping[name] else { return nil }
        return path.split(separator:".").reduce(obj as Any?) { current,key in (current as? [String:Any])?[String(key)] }
    }
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        guard let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any],let id=get(obj,"id") as? String,!id.isEmpty else {
            throw CoreError.invalid("Parser incompatible: custom event ID missing")
        }
        state.sessionID=get(obj,"session") as? String;state.cwd=get(obj,"cwd") as? String
        state.model=get(obj,"model") as? String;state.provider=get(obj,"provider") as? String
        var values:[String:Any]=[:]
        for key in TokenMetrics.names { values[key]=get(obj,key) }
        func metric(_ name:String) throws -> Metric { try Metric(Utilities.token(values,name),state:configuration.mapping[name]==nil ? .unsupported:.notAvailable) }
        var m=TokenMetrics();m.input=try metric("input");m.output=try metric("output");m.cacheRead=try metric("cacheRead")
        m.cacheWrite=try metric("cacheWrite");m.cachedOutput=try metric("cachedOutput");m.reasoning=try metric("reasoning");m.total=try metric("total")
        if !configuration.inputIncludesCache,let input=m.input.value {
            if let read=m.cacheRead.value,let write=m.cacheWrite.value { m.input=Metric(input+read+write) }
            else { m.input=Metric(state:.notAvailable) }
        }
        if configuration.mapping["total"]==nil { m.total=Metric(m.input.value.flatMap { i in m.output.value.map{i+$0} }) }
        guard m.total.value != nil || m.input.value != nil || m.output.value != nil else { throw CoreError.invalid("Parser incompatible: custom usage has no mapped counters") }
        return try context.event(timestamp:get(obj,"timestamp") as? String,identity:"custom:"+id,metrics:m,state:state,parser:version,
                                 metadata:["counting_method":"explicit_user_mapping","input_semantics":configuration.inputIncludesCache ? "includes_cache":"uncached_plus_cache_read_plus_cache_write"],partial:m.total.value==nil)
    }
}
