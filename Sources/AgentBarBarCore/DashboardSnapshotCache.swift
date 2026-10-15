import Foundation

/// Metadata-only dashboard snapshots. Credentials, settings and live status are excluded.
public actor DashboardSnapshotCache {
    public struct Entry:Codable,Sendable {public var key:String;public var body:Data;public var savedAt:Double;var tag:String}
    private struct Envelope:Codable {var version:Int;var namespace:String;var entries:[Entry]}
    public let namespace:String
    private let file:URL
    private var entries:[String:Entry]=[:]
    private var saveTask:Task<Void,Never>?
    public init(databasePath:String) {
        let absolute=URL(fileURLWithPath:databasePath).standardizedFileURL
        namespace=Utilities.hash(absolute.path)
        file=absolute.deletingLastPathComponent().appendingPathComponent("dashboard-cache-"+String(namespace.prefix(16))+".json")
        if let attributes=try? FileManager.default.attributesOfItem(atPath:file.path),(attributes[.size] as? NSNumber)?.intValue ?? Int.max<8*1024*1024,
           let data=try? Data(contentsOf:file),let envelope=try? JSONDecoder().decode(Envelope.self,from:data),envelope.version==1,envelope.namespace==namespace {
            for entry in envelope.entries where Self.allowed(entry.key) && Date().timeIntervalSince1970-entry.savedAt<7*86400 {entries[entry.key]=entry}
        }
    }
    public static func allowed(_ key:String) -> Bool {
        ["overview","summary","agents","models","projects","sessions","filters","collectors","events"].contains(String(key.split(separator:"?",maxSplits:1)[0]))
    }
    public static func key(_ path:String,items:[URLQueryItem] = []) -> String {
        var values:[String:String]=[:];for item in items where values[item.name]==nil {values[item.name]=item.value ?? ""}
        let allowed=CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._*"))
        func encode(_ value:String) -> String {value.addingPercentEncoding(withAllowedCharacters:allowed)?.replacingOccurrences(of:"%20",with:"+") ?? ""}
        let query=values.keys.sorted().map{encode($0)+"="+encode(values[$0]!)}.joined(separator:"&")
        return String(path.replacingOccurrences(of:"/api/",with:""))+(query.isEmpty ? "":"?"+query)
    }
    public func fresh(_ key:String,tag:String) -> Data? {
        guard let entry=entries[key],entry.tag==tag,Date().timeIntervalSince1970-entry.savedAt<10 else{return nil};return entry.body
    }
    public func record(_ key:String,body:Data,tag:String) {
        guard Self.allowed(key),body.count<=2*1024*1024 else{return}
        entries[key]=Entry(key:key,body:body,savedAt:Date().timeIntervalSince1970,tag:tag)
        var ordered=entries.values.sorted{$0.savedAt>$1.savedAt};var bytes=ordered.reduce(0){$0+$1.body.count}
        while ordered.count>24 || bytes>4*1024*1024 {if let removed=ordered.popLast(){entries.removeValue(forKey:removed.key);bytes-=removed.body.count}else{break}}
        if saveTask==nil {saveTask=Task{try? await Task.sleep(nanoseconds:1_000_000_000);persist()}}
    }
    private func persist() {
        saveTask=nil
        do {
            let payload=Envelope(version:1,namespace:namespace,entries:Array(entries.values))
            try JSONEncoder().encode(payload).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }catch{ /* In-memory snapshots remain usable if disk caching is unavailable. */ }
    }
    public func bootstrap(language:String) throws -> String {
        struct Bootstrap:Encodable {var namespace:String;var language:String;var entries:[Entry]}
        return try Utilities.json(Bootstrap(namespace:namespace,language:language,entries:Array(entries.values))).replacingOccurrences(of:"<",with:"\\u003c")
    }
}
