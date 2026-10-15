import Foundation
import CoreServices

final class SourceWatcher {
    private var stream:FSEventStreamRef?
    private let changed:([String]?) -> Void
    init(paths:[String],changed:@escaping ([String]?) -> Void) {
        self.changed=changed
        let existing=Array(Set(paths.compactMap{ path -> String? in
            var p=URL(fileURLWithPath:path)
            for _ in 0..<3 {
                var directory:ObjCBool=false
                if FileManager.default.fileExists(atPath:p.path,isDirectory:&directory) {return directory.boolValue ? p.path:p.deletingLastPathComponent().path}
                p.deleteLastPathComponent()
            };return nil
        }.filter{$0 != FileManager.default.homeDirectoryForCurrentUser.path && $0 != "/"}))
        guard !existing.isEmpty else{return}
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let callback:FSEventStreamCallback={_,info,count,paths,flags,_ in
            guard let info else{return}
            let owner=Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue()
            let dropped=FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            if (0..<count).contains(where:{flags[$0]&dropped != 0}) {owner.changed(nil)}
            else {owner.changed(unsafeBitCast(paths,to:NSArray.self) as? [String])}
        }
        stream=FSEventStreamCreate(nil,callback,&context,existing as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),1,
                                  FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {FSEventStreamSetDispatchQueue(stream,DispatchQueue.main);FSEventStreamStart(stream)}
    }
    deinit {if let stream{FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream)}}
}
