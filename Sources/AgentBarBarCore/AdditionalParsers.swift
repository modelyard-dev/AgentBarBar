import Foundation
import CryptoKit
import CoreFoundation

func sourceDate(_ raw:Any,scale:Double) throws -> Date {
    guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,
          n.doubleValue>0,n.doubleValue/scale<=253_402_300_799 else{throw CoreError.invalid("Parser incompatible: usage timestamp")}
    return Date(timeIntervalSince1970:n.doubleValue/scale)
}

/// OpenCode stores non-cached input and non-reasoning output separately.
/// SELECTs feeding this parser contain whitelisted metadata, never message bodies or parts.
public final class OpenCodeParserV1: UsageParser {
    public let version="opencode-sqlite-v1.0.0"
    public init() {}
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        guard let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],let id=row["id"] as? String,
              let session=row["session_id"] as? String else {throw CoreError.invalid("Parser incompatible: OpenCode message identity missing")}
        guard row["role"] as? String=="assistant" else{return nil}
        guard let completed=row["completed"],!(completed is NSNull) else{return nil} // In-flight placeholders are not requests.
        let completedDate=try sourceDate(completed,scale:1000)
        if row["parent_id"] is String {
            guard let created=row["created"],let sessionCreated=row["session_created"] else{throw CoreError.invalid("Parser incompatible: OpenCode fork metadata")}
            if try sourceDate(created,scale:1000)<sourceDate(sessionCreated,scale:1000) {return nil} // Forks copy the original message metadata.
        }
        guard let usage=row["tokens"] as? [String:Any] else{throw CoreError.invalid("Parser incompatible: OpenCode tokens missing")}
        let cache=usage["cache"] as? [String:Any] ?? [:]
        var invalid:[String]=[]
        func counter(_ object:[String:Any],_ key:String,_ label:String?=nil) -> Metric {
            do {return Metric(try Utilities.token(object,key))}
            catch {invalid.append(label ?? key);return Metric(state:.unknown)}
        }
        var m=TokenMetrics()
        let input=counter(usage,"input"),output=counter(usage,"output")
        m.cacheRead=counter(cache,"read","cache.read");m.cacheWrite=counter(cache,"write","cache.write");m.reasoning=counter(usage,"reasoning")
        if let i=input.value,let r=m.cacheRead.value,let w=m.cacheWrite.value {m.input=Metric(i+r+w)}
        else if input.state == .unknown || m.cacheRead.state == .unknown || m.cacheWrite.state == .unknown {m.input=Metric(state:.unknown)}
        if let o=output.value,let r=m.reasoning.value {m.output=Metric(o+r)}
        else if output.state == .unknown || m.reasoning.state == .unknown {m.output=Metric(state:.unknown)}
        m.total=counter(usage,"total")
        if m.total.value==nil,let input=m.input.value,let output=m.output.value {m.total=Metric(input+output)}
        if (row["has_error"] as? Int)==1 && m.total.value==0 {return nil} // Failed responses initialize counters to zero without reported usage.
        guard m.total.value != nil else{throw CoreError.invalid("Parser incompatible: OpenCode total and complete components unavailable")}
        state.sessionID=session;state.model=row["model"] as? String;state.provider=row["provider"] as? String;state.cwd=row["cwd"] as? String
        var reported:[String:Int64]=[:]
        for key in ["input","output","reasoning","total"] {
            if let n=usage[key] as? NSNumber,n.doubleValue.isFinite,abs(n.doubleValue)<=9_007_199_254_740_991,n.doubleValue.rounded()==n.doubleValue {reported[key]=n.int64Value}
        }
        if let r=m.cacheRead.value {reported["cache_read"]=r};if let w=m.cacheWrite.value {reported["cache_write"]=w}
        var metadata=["reported_usage":try Utilities.json(reported),"counting_method":"completed_assistant_message","source_table":"message","source_row_id":id,
                      "input_normalization":"source input + cache.read + cache.write","output_normalization":"source output + reasoning"]
        if let cost=row["cost"] as? NSNumber,cost.doubleValue.isFinite,cost.doubleValue>=0 {metadata["unverified_source_cost"]=cost.stringValue}
        if !invalid.isEmpty {metadata["invalid_source_metrics"]=invalid.joined(separator:", ");metadata["coverage_notes"]="Invalid source components are Unknown; valid reported total is retained"}
        var event=try context.event(timestamp:Utilities.iso(completedDate),identity:"message:"+id,metrics:m,state:state,parser:version,metadata:metadata,partial:!invalid.isEmpty)
        event.sourceType="local_sqlite";return event
    }
}

public final class KimiParserV1: UsageParser {
    public let version="kimi-wire-v1.0.0"
    private let metadataPath:String?
    private var directories:[String:String]
    public init(home:String?=nil,workDirectories:[String:String]=[:]) {metadataPath=home.map{$0+"/.kimi/kimi.json"};directories=workDirectories}
    public func prepare() throws {
        guard let metadataPath,FileManager.default.fileExists(atPath:metadataPath) else{return}
        let data=try Data(contentsOf:URL(fileURLWithPath:metadataPath))
        guard data.count<=2*1024*1024,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let rows=root["work_dirs"] as? [[String:Any]] else{throw CoreError.invalid("Parser incompatible: Kimi working directory metadata")}
        var result:[String:String]=[:]
        for row in rows {
            guard let path=row["path"] as? String,path.hasPrefix("/"),(row["kaos"] as? String ?? "local")=="local" else{continue}
            let hash=Insecure.MD5.hash(data:Data(path.utf8)).map{String(format:"%02x",$0)}.joined();result[hash]=path
        };directories=result
    }
    public func parse(_ data:Data,state:inout ParserState,context:ParseContext) throws -> UsageEvent? {
        let prefix=String(decoding:data.prefix(500),as:UTF8.self)
        guard prefix.contains("\"metadata\"") || prefix.contains("\"StatusUpdate\"") else{return nil}
        guard let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CoreError.invalid("Parser incompatible: Kimi wire object")}
        if obj["type"] as? String=="metadata" {
            guard let v=obj["protocol_version"] as? String,v.hasPrefix("1.") else{throw CoreError.invalid("Parser incompatible: Kimi wire protocol version")}
            state.agentVersion="wire-"+v;return nil
        }
        guard let message=obj["message"] as? [String:Any],message["type"] as? String=="StatusUpdate",let p=message["payload"] as? [String:Any],let usage=p["token_usage"] as? [String:Any] else{return nil}
        guard let id=p["message_id"] as? String,!id.isEmpty,let stamp=obj["timestamp"] else{throw CoreError.invalid("Parser incompatible: Kimi request ID/timestamp missing")}
        let timestamp=try sourceDate(stamp,scale:1)
        let url=URL(fileURLWithPath:context.path).deletingLastPathComponent()
        state.sessionID=url.lastPathComponent;state.cwd=directories[url.deletingLastPathComponent().lastPathComponent]
        // A current config cannot tell us the model/provider used by a historical request.
        state.model=nil;state.provider=nil
        var m=TokenMetrics();m.reasoning=Metric(state:.unsupported)
        m.output=Metric(try Utilities.token(usage,"output"));m.cacheRead=Metric(try Utilities.token(usage,"input_cache_read"));m.cacheWrite=Metric(try Utilities.token(usage,"input_cache_creation"))
        guard let other=try Utilities.token(usage,"input_other"),let read=m.cacheRead.value,let write=m.cacheWrite.value,let output=m.output.value else{throw CoreError.invalid("Parser incompatible: Kimi token components missing")}
        m.input=Metric(other+read+write);m.total=Metric(other+read+write+output)
        var reported:[String:Int64]=[:]
        for key in ["input_other","output","input_cache_read","input_cache_creation"] {reported[key]=try Utilities.token(usage,key)}
        return try context.event(timestamp:Utilities.iso(timestamp),identity:"message:"+id,metrics:m,state:state,parser:version,
            metadata:["reported_usage":try Utilities.json(reported),"counting_method":"wire_status_request_usage","wire_protocol":state.agentVersion ?? "unverified","model_availability":"historical wire does not report model","input_normalization":"input_other + input_cache_read + input_cache_creation"])
    }
}
