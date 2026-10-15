import Foundation
import CZstd

/// Concatenated Zstandard frames are independent checkpoints; partial final frames wait for append.
enum ZstdFrames {
    static let maximumBytes=64*1024*1024
    static func decodeFirst(_ data:Data) throws -> (consumed:Int,decoded:Data)? {
        guard !data.isEmpty else{return nil}
        let size=data.withUnsafeBytes{ZSTD_findFrameCompressedSize($0.baseAddress,$0.count)}
        if ZSTD_isError(size) != 0 {
            if ZSTD_getErrorCode(size)==ZSTD_error_srcSize_wrong {return nil}
            throw CoreError.invalid("Parser incompatible: invalid Zstandard frame")
        }
        guard size<=maximumBytes,let stream=ZSTD_createDStream() else{throw CoreError.invalid("Zstandard frame exceeds supported limits")}
        defer{ZSTD_freeDStream(stream)}
        guard ZSTD_isError(ZSTD_DCtx_setParameter(stream,ZSTD_d_windowLogMax,26))==0 else{throw CoreError.invalid("Cannot initialize Zstandard decoder")}
        var decoded=Data();var buffer=[UInt8](repeating:0,count:128*1024)
        try data.withUnsafeBytes{inputBytes in
            var input=ZSTD_inBuffer(src:inputBytes.baseAddress,size:size,pos:0)
            try buffer.withUnsafeMutableBytes{outputBytes in
                while true {
                    var output=ZSTD_outBuffer(dst:outputBytes.baseAddress,size:outputBytes.count,pos:0)
                    let result=ZSTD_decompressStream(stream,&output,&input)
                    guard ZSTD_isError(result)==0 else{throw CoreError.invalid("Parser incompatible: corrupt Zstandard frame")}
                    guard decoded.count+output.pos<=maximumBytes else{throw CoreError.invalid("Zstandard record exceeds supported limits")}
                    decoded.append(outputBytes.bindMemory(to:UInt8.self).baseAddress!,count:output.pos)
                    if result==0 {break}
                    if output.pos==0 && input.pos==input.size {throw CoreError.invalid("Parser incompatible: truncated Zstandard frame")}
                }
            }
        }
        return (size,decoded)
    }
}

public final class ZstdJSONLCollector:AgentCollector {
    public let descriptor:CollectorDescriptor
    private let parser:UsageParser
    private let rule:AgentDiscoveryRule
    private let home:String
    private var currentHealth=CollectorHealth()
    public init(descriptor:CollectorDescriptor,parser:UsageParser,rule:AgentDiscoveryRule,home:String=FileManager.default.homeDirectoryForCurrentUser.path) {
        self.descriptor=descriptor;self.parser=parser;self.rule=rule;self.home=home
    }
    public func detect() async -> DetectionResult {await detect(using:DiscoveryEngine(home:home))}
    public func detect(using discovery:DiscoveryEngine) async -> DetectionResult {discovery.detect(rule,sourceRoots:descriptor.sourceRoots)}
    public func health() async -> CollectorHealth {currentHealth}
    public func collect(store:EventStore) async throws -> CollectionResult {try await collectSources(store:store,changedPaths:nil)}
    public func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult {try await collectSources(store:store,changedPaths:paths)}
    private func collectSources(store:EventStore,changedPaths:[String]?) async throws -> CollectionResult {
        let run=try await store.beginRun(collectorID:descriptor.id)
        var health=CollectorHealth();health.status="healthy";health.compatibility="schema_verified_agent_version_unverified"
        if changedPaths != nil {health.errors=currentHealth.errors}
        let fm=FileManager.default;var files=Set<URL>()
        let roots=changedPaths.map{$0.filter{path in descriptor.sourceRoots.contains{path==$0 || path.hasPrefix($0+"/")}}} ?? descriptor.sourceRoots
        for path in Set(roots) {
            var directory:ObjCBool=false
            guard fm.fileExists(atPath:path,isDirectory:&directory) else{continue}
            guard fm.isReadableFile(atPath:path) else{health.errors.append("Permission denied: "+path);continue}
            let root=URL(fileURLWithPath:path)
            if !directory.boolValue {if root.lastPathComponent.hasSuffix(".jsonl.zstd"){files.insert(root)};continue}
            guard let iterator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles],errorHandler:{url,_ in
                if health.errors.count<12 {health.errors.append("Cannot inspect data directory: "+url.path)};return true
            }) else{health.errors.append("Cannot inspect data directory: "+path);continue}
            while let url=iterator.nextObject() as? URL {
                let properties=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                if properties?.isSymbolicLink==true {iterator.skipDescendants();continue}
                if properties?.isRegularFile==true && url.lastPathComponent.hasSuffix(".jsonl.zstd") {files.insert(url)}
            }
        }
        health.files=files.count
        if files.isEmpty && health.errors.isEmpty && changedPaths==nil {health.status="source_unavailable";health.compatibility="unverified"}
        let projects=ProjectDetector();let cursorVersion=parser.version+":zstd-1.5.7"
        for url in files.sorted(by:{$0.path<$1.path}) {
            if Task.isCancelled {break}
            let sourceName=url.deletingLastPathComponent().lastPathComponent+"/"+url.lastPathComponent
            do {
                let attributes=try fm.attributesOfItem(atPath:url.path)
                let size=(attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified=(attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let identity="\(attributes[.systemNumber] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
                var cursor=try await store.cursor(path:url.path) ?? SourceCursor(path:url.path,identity:identity,parserVersion:cursorVersion)
                if cursor.identity==identity,cursor.parserVersion==cursorVersion,cursor.modified==modified,cursor.observedSize==size {
                    if let error=cursor.lastError,health.errors.count<12 {health.errors.append(error)}
                    for warning in cursor.state.warnings where !health.errors.contains(warning) && health.errors.count<12 {health.errors.append(warning)}
                    continue
                }
                let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
                var reset=cursor.identity != identity || cursor.parserVersion != cursorVersion || cursor.offset>size
                if !reset,let expected=cursor.boundaryHash,cursor.offset>0 {
                    let count=min(cursor.offset,256);try file.seek(toOffset:cursor.offset-count)
                    reset=Utilities.hash((try file.read(upToCount:Int(count)) ?? Data()).base64EncodedString()) != expected
                }
                if reset || (cursor.offset==size && cursor.modified != modified) {cursor=SourceCursor(path:url.path,identity:identity,parserVersion:cursorVersion)}
                try file.seek(toOffset:cursor.offset)
                cursor.lastError=nil;cursor.observedSize=size;cursor.modified=modified
                var readPosition=cursor.offset;var pending=Data();var events:[UsageEvent]=[];var frames=0;var failed=false
                func checkpoint() throws {
                    if cursor.offset>0 {
                        let count=min(cursor.offset,256);try file.seek(toOffset:cursor.offset-count)
                        cursor.boundaryHash=Utilities.hash((try file.read(upToCount:Int(count)) ?? Data()).base64EncodedString())
                        try file.seek(toOffset:readPosition)
                    }
                }
                while readPosition<size && !Task.isCancelled {
                    let chunk=try file.read(upToCount:Int(min(UInt64(128*1024),size-readPosition))) ?? Data()
                    if chunk.isEmpty {break}
                    readPosition+=UInt64(chunk.count);health.bytesRead+=UInt64(chunk.count);pending.append(chunk)
                    while !pending.isEmpty {
                        let previousState=cursor.state;let previousLine=cursor.line
                        do {
                            guard let frame=try autoreleasepool(invoking:{try ZstdFrames.decodeFirst(pending)}) else{break}
                            guard frame.decoded.isEmpty || frame.decoded.last==10 else{throw CoreError.invalid("Parser incompatible: Zstandard frame lacks a complete JSONL record")}
                            var frameEvents:[UsageEvent]=[]
                            for (index,line) in frame.decoded.split(separator:10,omittingEmptySubsequences:false).dropLast().enumerated() {
                                cursor.line+=1
                                let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,collectorVersion:descriptor.version,path:url.path,line:cursor.line,offset:cursor.offset,projects:projects)
                                if !line.isEmpty,var event=try autoreleasepool(invoking:{try parser.parse(Data(line),state:&cursor.state,context:context)}) {
                                    event.sourceMetadata["compression"]="zstd";event.sourceMetadata["frame_line_index"]=String(index);event.sourceMetadata["decoder_version"]="1.5.7"
                                    frameEvents.append(event)
                                }
                            }
                            events+=frameEvents;cursor.offset+=UInt64(frame.consumed);pending.removeFirst(frame.consumed);frames+=1
                        } catch {
                            let failedLine=max(cursor.line,previousLine+1)
                            cursor.state=previousState;cursor.line=previousLine
                            cursor.lastError="\(sourceName): line \(failedLine) — \((error as? CoreError)?.localizedDescription ?? "Parser incompatible: metadata record")"
                            if health.errors.count<12 {health.errors.append(cursor.lastError!)};failed=true;break
                        }
                        if events.count>=200 || frames>=256 {
                            try checkpoint();let result=try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id)
                            health.imported+=result.inserted;health.updated+=result.updated;health.duplicates+=result.duplicates
                            events.removeAll(keepingCapacity:true);frames=0;await Task.yield()
                        }
                    }
                    if failed {break}
                    if pending.count>ZstdFrames.maximumBytes {cursor.lastError="Zstandard frame exceeds supported limits";health.errors.append(cursor.lastError!);break}
                }
                try checkpoint();let result=try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id)
                health.imported+=result.inserted;health.updated+=result.updated;health.duplicates+=result.duplicates
                for warning in cursor.state.warnings where !health.errors.contains(warning) && health.errors.count<12 {health.errors.append(warning)}
            } catch {if health.errors.count<12 {health.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")}}
        }
        if !health.errors.isEmpty {health.status="partial"}
        health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health)
        try await store.updateHealth(descriptor.id,health);try await store.finishRun(run,result:result);return result
    }
}
