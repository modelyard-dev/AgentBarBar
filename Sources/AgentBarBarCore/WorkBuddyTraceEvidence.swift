import Foundation

public struct WorkBuddyTraceSample:Codable,Sendable {
    public var sourcePath:String
    public var traceID:String
    public var sessionID:String?
    public var models:[String]
    public var totalTokens:Int64
    public var callCount:Int?
}
public struct WorkBuddyTraceEvidence:Codable,Sendable {
    public var parserVersion:String="workbuddy-trace-evidence-v1.0.0"
    public var checkedAt:String
    public var inspectedFiles:Int
    public var limited:Bool
    public var samples:[WorkBuddyTraceSample]
    public var mergedIntoTotals:Bool=false
    public static func read(_ root:URL) throws -> Self {
        struct Envelope:Decodable {var trace:Trace}
        struct Trace:Decodable {var traceId:String;var sessionId:String?;var totalTokens:Int64;var modelInfo:Info?}
        struct Info:Decodable {var models:[String]?;var callCount:Int?}
        var report=Self(checkedAt:Utilities.iso(),inspectedFiles:0,limited:false,samples:[])
        let fm=FileManager.default;let start=Date();var bytes=0
        let folders=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]).sorted{$0.lastPathComponent>$1.lastPathComponent}
        for folder in folders {
            let properties=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard properties.isDirectory==true,properties.isSymbolicLink != true else{continue}
            let paths=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey,.isSymbolicLinkKey]).filter{$0.lastPathComponent.hasPrefix("trace_") && $0.pathExtension=="json"}.sorted{$0.lastPathComponent>$1.lastPathComponent}
            for path in paths {
                if report.inspectedFiles>=256 || bytes>=16*1024*1024 || Date().timeIntervalSince(start)>3 {report.limited=true;return report}
                let p=try path.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
                guard p.isSymbolicLink != true,let size=p.fileSize,size<=2*1024*1024,bytes+size<=16*1024*1024 else{continue}
                bytes+=size;report.inspectedFiles+=1
                // Decoder ignores toolInput/toolOutput, metadata and all other content fields.
                guard let row=try? JSONDecoder().decode(Envelope.self,from:Data(contentsOf:path)),row.trace.totalTokens>0,row.trace.traceId.utf8.count<=512 else{continue}
                report.samples.append(WorkBuddyTraceSample(sourcePath:path.path,traceID:row.trace.traceId,sessionID:row.trace.sessionId,models:(row.trace.modelInfo?.models ?? []).filter{$0.utf8.count<=512},totalTokens:row.trace.totalTokens,callCount:row.trace.modelInfo?.callCount))
                if report.samples.count==3 {report.limited=true;return report}
            }
        }
        return report
    }
}
