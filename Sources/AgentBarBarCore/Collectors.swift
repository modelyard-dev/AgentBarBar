import Foundation
import Darwin

public protocol AgentCollector: AnyObject {
    var descriptor:CollectorDescriptor { get }
    func detect() async -> DetectionResult
    func detect(using discovery:DiscoveryEngine) async -> DetectionResult
    func collect(store:EventStore) async throws -> CollectionResult
    func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult
    func health() async -> CollectorHealth
}
public extension AgentCollector {
    func detect(using discovery:DiscoveryEngine) async -> DetectionResult {await detect()}
    func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult {try await collect(store:store)}
}

public final class JSONLCollector: AgentCollector {
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
    public func health() async -> CollectorHealth { currentHealth }
    public func collect(store:EventStore) async throws -> CollectionResult {
        try await collectSources(store:store,changedPaths:nil)
    }
    public func collectChanges(store:EventStore,paths:[String]) async throws -> CollectionResult {
        try await collectSources(store:store,changedPaths:paths)
    }
    private func collectSources(store:EventStore,changedPaths:[String]?) async throws -> CollectionResult {
        try parser.prepare()
        let started=try await store.beginRun(collectorID:descriptor.id)
        var health=CollectorHealth();health.status="healthy";health.compatibility="schema_verified_agent_version_unverified"
        if changedPaths != nil {health.errors=currentHealth.errors}
        let projects=ProjectDetector();let fm=FileManager.default
        var files:[URL]=[]
        let roots=changedPaths.map{changes in changes.filter{path in descriptor.sourceRoots.contains{path==$0 || path.hasPrefix($0+"/")}}} ?? descriptor.sourceRoots
        for path in Array(Set(roots)) {
            let root=URL(fileURLWithPath:path).standardizedFileURL
            var directory:ObjCBool=false
            guard fm.fileExists(atPath:root.path,isDirectory:&directory) else { continue }
            if !fm.isReadableFile(atPath:root.path) { health.errors.append("Permission denied: "+root.path);continue }
            if !directory.boolValue { if root.pathExtension=="jsonl" { files.append(root) };continue }
            guard let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey],options:[.skipsHiddenFiles],errorHandler:{url,_ in
                if health.errors.count<12 { health.errors.append("Cannot inspect data directory: "+url.path) };return true
            }) else { health.errors.append("Data source unavailable: "+root.path);continue }
            while let url=enumerator.nextObject() as? URL {
                let values=try? url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
                if values?.isSymbolicLink==true { enumerator.skipDescendants();continue }
                if values?.isRegularFile==true && url.pathExtension=="jsonl" && (descriptor.agentID != "codex" || url.lastPathComponent.hasPrefix("rollout-")) && (descriptor.agentID != "kimi-cli" || url.lastPathComponent=="wire.jsonl") && (descriptor.agentID != "qwen" || url.lastPathComponent.range(of:"^token-usage-[0-9]{4}-[0-9]{2}\\.jsonl$",options:.regularExpression) != nil) { files.append(url) }
            }
        }
        files=Array(Set(files)).sorted{$0.path<$1.path};health.files=files.count
        if files.isEmpty && health.errors.isEmpty && changedPaths==nil {health.status="source_unavailable";health.compatibility="unverified"}
        let adopted=try await store.setting("parser-adoption:"+descriptor.agentID,as:String.self)
        let hasOldRows = descriptor.agentID=="codex" && adopted != parser.version ? try await store.usesOldParserRows(agentID:descriptor.agentID,version:parser.version) : false
        let replacing=hasOldRows
        if replacing && changedPaths != nil { let result=try await collectSources(store:store,changedPaths:nil);try await store.finishRun(started,result:result);return result }
        var replacementFailed = !health.errors.isEmpty
        func save(_ events:[UsageEvent],_ cursor:SourceCursor) async throws -> CommitResult {
            if replacing { return try await store.stageReplacement(run:started,events:events,cursor:cursor) }
            return try await store.commit(events:events,cursor:cursor,collectorID:descriptor.id)
        }
        for url in files {
            if Task.isCancelled { break }
            do {
                let attrs=try fm.attributesOfItem(atPath:url.path)
                let size=(attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let modified=(attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let identity="\((attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0):\((attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)"
                var cursor=try await store.cursor(path:url.path) ?? SourceCursor(path:url.path,identity:identity,parserVersion:parser.version)
                if replacing {cursor=SourceCursor(path:url.path,identity:identity,parserVersion:parser.version)}
                if !replacing,cursor.identity==identity,cursor.parserVersion==parser.version,cursor.modified==modified,(cursor.observedSize ?? cursor.offset)==size {
                    for warning in cursor.state.warnings where !health.errors.contains(warning) && health.errors.count<12 {health.errors.append(warning)}
                    if let error=cursor.lastError,health.errors.count<12 {health.errors.append(error)}
                    continue
                }
                let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
                var reset=cursor.identity != identity || cursor.offset>size || cursor.parserVersion != parser.version
                if !reset,let expected=cursor.boundaryHash,cursor.offset>0 {
                    let length=min(cursor.offset,256);try file.seek(toOffset:cursor.offset-length)
                    let previous=try file.read(upToCount:Int(length)) ?? Data()
                    reset=Utilities.hash(previous.base64EncodedString()) != expected
                }
                if reset { cursor=SourceCursor(path:url.path,identity:identity,parserVersion:parser.version) }
                if cursor.offset==size && cursor.modified==modified {
                    for warning in cursor.state.warnings where !health.errors.contains(warning) && health.errors.count<12 {health.errors.append(warning)}
                    continue
                }
                if cursor.offset==size && cursor.modified != modified && size>0 {
                    // Same-length in-place rewrites need full reconciliation as well.
                    cursor=SourceCursor(path:url.path,identity:identity,parserVersion:parser.version)
                }
                try file.seek(toOffset:cursor.offset)
                cursor.lastError=nil;cursor.observedSize=size
                var lineData=Data();var events:[UsageEvent]=[];var batchLines=0;var readOffset=cursor.offset;var failed=false
                while readOffset<size {
                    let data=try file.read(upToCount:Int(min(UInt64(256*1024),size-readOffset))) ?? Data()
                    if data.isEmpty { break }
                    readOffset += UInt64(data.count);health.bytesRead += UInt64(data.count)
                    var begin=data.startIndex
                    for index in data.indices where data[index]==10 {
                        lineData.append(data[begin..<index]);begin=data.index(after:index)
                        let consumed=UInt64(lineData.count+1);let lineStart=cursor.offset
                        let previousState=cursor.state
                        do {
                            if !lineData.isEmpty {
                                let context=ParseContext(agentID:descriptor.agentID,agentName:descriptor.name,collectorID:descriptor.id,collectorVersion:descriptor.version,path:url.path,line:cursor.line+1,offset:lineStart,projects:projects)
                                let event=try autoreleasepool {try parser.parse(lineData,state:&cursor.state,context:context)}
                                if let event {events.append(event)}
                            }
                            cursor.offset += consumed;cursor.line += 1;batchLines += 1
                            lineData.removeAll(keepingCapacity:true)
                        } catch {
                            cursor.state=previousState
                            let description="\(url.lastPathComponent): line \(cursor.line+1) — \((error as? CoreError)?.localizedDescription ?? "Parser incompatible: malformed JSON")"
                            cursor.lastError=description
                            if health.errors.count<12 {health.errors.append(description)}
                            failed=true;break
                        }
                    }
                    if failed { break }
                    lineData.append(data[begin..<data.endIndex])
                    if lineData.count>64*1024*1024 {cursor.lastError="\(url.lastPathComponent): oversized JSONL record; source paused";health.errors.append(cursor.lastError!);failed=true;break}
                    if batchLines>=1000 || events.count>=200 {
                        let savedPosition=file.offsetInFile
                        if cursor.offset>0 {
                            let length=min(cursor.offset,256);try file.seek(toOffset:cursor.offset-length)
                            cursor.boundaryHash=Utilities.hash((try file.read(upToCount:Int(length)) ?? Data()).base64EncodedString());try file.seek(toOffset:savedPosition)
                        }
                        cursor.modified=modified
                        let r=try await save(events,cursor)
                        health.imported += r.inserted;health.updated += r.updated;health.duplicates += r.duplicates
                        events.removeAll(keepingCapacity:true);batchLines=0
                        await Task.yield()
                    }
                }
                cursor.modified=modified
                if cursor.offset>0 {
                    let length=min(cursor.offset,256);try file.seek(toOffset:cursor.offset-length)
                    cursor.boundaryHash=Utilities.hash((try file.read(upToCount:Int(length)) ?? Data()).base64EncodedString())
                }
                let result=try await save(events,cursor)
                health.imported += result.inserted;health.updated += result.updated;health.duplicates += result.duplicates
                if failed {replacementFailed=true}
                for warning in cursor.state.warnings where !health.errors.contains(warning) && health.errors.count<12 { health.errors.append(warning) }
            } catch {
                replacementFailed=true
                if health.errors.count<12 { health.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        if replacing {
            if replacementFailed || files.isEmpty || Task.isCancelled {
                try await store.discardReplacement(run:started);health.imported=0;health.updated=0
                if !files.isEmpty {health.errors.append("Parser upgrade paused; previous usage remains active")}
            } else {try await store.preserveMissingHistory(run:started,agentID:descriptor.agentID);try await store.finishReplacement(run:started,agentID:descriptor.agentID,collectorID:descriptor.id,parserVersion:parser.version)}
        }
        if descriptor.agentID=="codex" && !replacing {try await store.setSetting("parser-adoption:"+descriptor.agentID,value:parser.version)}
        if !health.errors.isEmpty { health.status="partial" }
        if descriptor.agentID=="workbuddy",changedPaths==nil,let projectsRoot=descriptor.sourceRoots.first(where:{$0.hasSuffix("/.workbuddy/projects")}) {
            let traces=URL(fileURLWithPath:projectsRoot).deletingLastPathComponent().appendingPathComponent("traces")
            if fm.fileExists(atPath:traces.path) {
                if let evidence=try? WorkBuddyTraceEvidence.read(traces) {try await store.setSetting("workbuddy-trace-evidence",value:evidence)}
                else {health.errors.append("WorkBuddy trace evidence cannot be inspected")}
            }
        }
        if !health.errors.isEmpty {health.status="partial"}
        health.lastCollection=Utilities.iso();currentHealth=health
        let result=CollectionResult(collectorID:descriptor.id,health:health)
        try await store.updateHealth(descriptor.id,health);try await store.finishRun(started,result:result)
        if health.bytesRead>32*1024*1024 {malloc_zone_pressure_relief(nil,0)}
        return result
    }
}

public actor CollectorEngine {
    public let store:EventStore
    private let home:String
    private var registry:[any AgentCollector]=[]
    private var collectorAgentIDs=Set<String>()
    private var customDiscoveryRules:[AgentDiscoveryRule]=[]
    public private(set) var collecting=false
    public private(set) var lastResults:[CollectionResult]=[]
    public init(store:EventStore,home:String=FileManager.default.homeDirectoryForCurrentUser.path) { self.store=store;self.home=home }
    public func configure(_ settings:AppSettings) async throws {
        let settings=try settings.validated()
        let discovery=DiscoveryEngine(home:home)
        customDiscoveryRules=[]
        collectorAgentIDs=[]
        var collectors:[any AgentCollector]=[]
        for (id,agent,name,rel,parser) in [
            ("codex-local","codex","Codex",[".codex/sessions",".codex/archived_sessions"],CodexParserV1() as any UsageParser),
            ("claude-local","claude-code","Claude Code",[".claude/projects"],ClaudeParserV1() as any UsageParser),
            ("pi-local","pi","Pi",[".pi/agent/sessions"],PiParserV1() as any UsageParser),
            ("kimi-local","kimi-cli","Kimi CLI",[".kimi/sessions"],KimiParserV1(home:home) as any UsageParser),
            ("workbuddy-local","workbuddy","WorkBuddy",[".workbuddy/projects"],WorkBuddyParserV1() as any UsageParser)
        ] {
            let roots=settings.sourceOverrides[id] ?? rel.map{home+"/"+$0}
            var descriptor=CollectorDescriptor(id:id,agentID:agent,name:name,version:"1.0.1",parserVersion:parser.version,
                supportedAgentVersions:agent=="pi" ? ["0.87.1 (session format 3)"] : agent=="claude-code" ? ["2.1.261 source fixture"] : agent=="kimi-cli" ? ["1.30.0 / Wire protocol 1.x source fixture"] : ["0.125.0 legacy fixture","0.159.0 legacy fixture","0.160.0 request fixture"],
                capabilities:["input":.supported,"output":.supported,"cacheRead":.supported,"cacheWrite":.supported,"cachedOutput":.unsupported,"reasoning":.conditional,"total":.supported,"model":.conditional,"session":.supported,"project":.conditional,"cost":.unsupported],
                sourceRoots:roots,sourceDescription:agent=="codex" ? "Codex local rollout JSONL" : agent=="pi" ? "Pi local session format 3 JSONL" : agent=="kimi-cli" ? "Kimi CLI local Wire request usage JSONL":"Claude Code local project JSONL")
            if agent=="codex" || agent=="pi" {descriptor.version="1.1.0"}
            if agent=="kimi-cli" {descriptor.capabilities["model"] = .unsupported;descriptor.capabilities["provider"] = .unsupported;descriptor.capabilities["reasoning"] = .unsupported;descriptor.capabilities["total"] = .derived}
            if agent=="workbuddy" {
                descriptor.version="1.0.0";descriptor.supportedAgentVersions=["5.6.2 persisted SDK usage fixture"]
                descriptor.sourceDescription="WorkBuddy local SDK project JSONL";descriptor.capabilities["cacheWrite"] = .unsupported
            }
            let collector=JSONLCollector(descriptor:descriptor,parser:parser,rule:DiscoveryEngine.catalog.first{$0.id==agent}!,home:home)
            var health=CollectorHealth();health.status=settings.disabledCollectors.contains(id) ? "disabled":"waiting"
            try await store.registerCollector(descriptor,detection:await collector.detect(using:discovery),health:health)
            collectorAgentIDs.insert(agent)
            if !settings.disabledCollectors.contains(id) { collectors.append(collector) }
        }
        let openCode=OpenCodeCollector(roots:settings.sourceOverrides["opencode-local"] ?? [home+"/.local/share/opencode"],home:home)
        var openCodeHealth=CollectorHealth();openCodeHealth.status=settings.disabledCollectors.contains(openCode.descriptor.id) ? "disabled":"waiting"
        try await store.registerCollector(openCode.descriptor,detection:await openCode.detect(using:discovery),health:openCodeHealth)
        collectorAgentIDs.insert(openCode.descriptor.agentID)
        if !settings.disabledCollectors.contains(openCode.descriptor.id) {collectors.append(openCode)}
        let dshLedgerPath=home+"/.dsh/storages/dsh_token_usage_sidebar.sqlite"
        let previousDSH=try await store.collectors().first { $0.descriptor.id=="dsh-local" }
        let useLedger=FileManager.default.fileExists(atPath:dshLedgerPath) || previousDSH?.descriptor.parserVersion.hasPrefix("dsh-canonical-ledger")==true
        let dsh: any AgentCollector
        if useLedger {
            dsh=DeepSeekLedgerCollector(roots:settings.sourceOverrides["dsh-local"] ?? [home+"/.dsh/storages"],home:home)
        } else {
            let dshParser=DeepSeekParserV1()
            let dshDescriptor=CollectorDescriptor(id:"dsh-local",agentID:"deepseek-harness",name:"DeepSeek Harness",version:"1.0.0",parserVersion:dshParser.version,
                supportedAgentVersions:["0.2.0-rc.2 desktop / persisted session formats 0, 3 and 4"],
                capabilities:["input":.derived,"output":.supported,"total":.conditional,"cacheRead":.conditional,"cacheWrite":.unsupported,"cachedOutput":.unsupported,"reasoning":.unsupported,"model":.conditional,"session":.supported,"project":.conditional,"cost":.unsupported],
                sourceRoots:settings.sourceOverrides["dsh-local"] ?? [home+"/.dsh/sessions"],sourceDescription:"DeepSeek Harness local Zstandard session JSONL")
            dsh=ZstdJSONLCollector(descriptor:dshDescriptor,parser:dshParser,rule:DiscoveryEngine.catalog.first{$0.id=="deepseek-harness"}!,home:home)
        }
        var dshHealth=CollectorHealth();dshHealth.status=settings.disabledCollectors.contains(dsh.descriptor.id) ? "disabled":"waiting"
        try await store.registerCollector(dsh.descriptor,detection:await dsh.detect(using:discovery),health:dshHealth)
        collectorAgentIDs.insert(dsh.descriptor.agentID)
        if !settings.disabledCollectors.contains(dsh.descriptor.id) {collectors.append(dsh)}
        let cline=ClineCollector(roots:settings.sourceOverrides["cline-local"] ?? [home+"/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"],home:home)
        let qwen=QwenCollector.make(roots:settings.sourceOverrides["qwen-local"] ?? [home+"/.qwen/usage"],home:home)
        let gemini=GeminiCollector(roots:settings.sourceOverrides["gemini-local"] ?? [home+"/.gemini/tmp"],home:home)
        let antigravity=AntigravityCollector(agentID:"antigravity",name:"Antigravity",roots:settings.sourceOverrides["antigravity-local"] ?? [home+"/.gemini/antigravity-cli/conversations"],home:home)
        let ide=AntigravityCollector(agentID:"antigravity-ide",name:"Antigravity IDE",roots:settings.sourceOverrides["antigravity-ide-local"] ?? [home+"/.gemini/antigravity/conversations"],home:home)
        for collector in [cline as any AgentCollector,qwen as any AgentCollector,gemini as any AgentCollector,antigravity as any AgentCollector,ide as any AgentCollector] {
            var health=CollectorHealth();health.status=settings.disabledCollectors.contains(collector.descriptor.id) ? "disabled":"waiting"
            try await store.registerCollector(collector.descriptor,detection:await collector.detect(using:discovery),health:health)
            collectorAgentIDs.insert(collector.descriptor.agentID)
            if !settings.disabledCollectors.contains(collector.descriptor.id) {collectors.append(collector)}
        }
        for rule in DiscoveryEngine.catalog where !collectorAgentIDs.contains(rule.id) {
            let roots=settings.sourceOverrides[rule.id+"-inspection"] ?? SourceInspectionCollector.roots(for:rule.id,home:home);let detection=discovery.detect(rule)
            guard !roots.isEmpty,(home==FileManager.default.homeDirectoryForCurrentUser.path || roots.contains(where:{FileManager.default.fileExists(atPath:$0)})),(detection.installed || !detection.evidence.isEmpty || roots.contains(where:{FileManager.default.fileExists(atPath:$0)})) else{continue}
            let collector=SourceInspectionCollector(rule:rule,roots:roots,home:home)
            var health=CollectorHealth();health.status=settings.disabledCollectors.contains(collector.descriptor.id) ? "disabled":"waiting"
            try await store.registerCollector(collector.descriptor,detection:detection,health:health);collectorAgentIDs.insert(rule.id)
            if !settings.disabledCollectors.contains(collector.descriptor.id) {collectors.append(collector)}
        }
        for c in settings.customAgents {
            if c.discoveryOnly==true {
                let rule=AgentDiscoveryRule(id:"custom-"+c.id,name:c.name,binaries:c.executable.map{[$0]} ?? [],directories:c.dataDirectory.map{[$0]} ?? [],processes:c.processName.map{[$0]} ?? [])
                customDiscoveryRules.append(rule)
                try await store.registerAgent(id:rule.id,name:rule.name,detection:discovery.detect(rule))
                continue
            }
            let parser=CustomJSONLParserV1(c);let id="custom-"+c.id
            let descriptor=CollectorDescriptor(id:id,agentID:id,name:c.name,version:"1.0.1",parserVersion:parser.version,supportedAgentVersions:["User-defined JSONL mapping"],
                capabilities:Dictionary(uniqueKeysWithValues:TokenMetrics.names.map{($0,c.mapping[$0] != nil ? Capability.supported:Capability.unsupported)}),
                sourceRoots:[c.logDirectory],sourceDescription:"Explicit custom JSONL mapping")
            let rule=AgentDiscoveryRule(id:id,name:c.name,binaries:c.executable.map{[$0]} ?? [],directories:c.dataDirectory.map{[$0]} ?? [],processes:c.processName.map{[$0]} ?? [])
            let collector=JSONLCollector(descriptor:descriptor,parser:parser,rule:rule,home:home)
            var health=CollectorHealth();health.status=settings.disabledCollectors.contains(id) ? "disabled":"waiting"
            try await store.registerCollector(descriptor,detection:await collector.detect(using:discovery),health:health)
            if !settings.disabledCollectors.contains(id) { collectors.append(collector) }
        }
        try await store.retireCustomCollectors(active:settings.customAgents.filter{$0.discoveryOnly != true}.map{"custom-"+$0.id})
        registry=collectors
        try await refreshDiscovery(using:discovery)
    }
    public func refreshDiscovery() async throws {
        try await refreshDiscovery(using:DiscoveryEngine(home:home))
    }
    private func refreshDiscovery(using discovery:DiscoveryEngine) async throws {
        for rule in DiscoveryEngine.catalog where !collectorAgentIDs.contains(rule.id) {
            let detection=discovery.detect(rule)
            if detection.installed || !detection.evidence.isEmpty {try await store.registerAgent(id:rule.id,name:rule.name,detection:detection)}
            else {try await store.updateAgentDetection(id:rule.id,detection:detection)}
        }
        for rule in customDiscoveryRules {try await store.registerAgent(id:rule.id,name:rule.name,detection:discovery.detect(rule))}
    }
    private var surveying = Set<String>()
    public func surveyTokenSources(agentID: String) async throws -> TokenSourceSurvey {
        guard !surveying.contains(agentID) else { throw CoreError.invalid("Survey already running for this Agent") }
        surveying.insert(agentID); defer { surveying.remove(agentID) }
        let records = try await store.collectors()
        let record = records.first { $0.descriptor.agentID == agentID }
        let rule = DiscoveryEngine.catalog.first { $0.id == agentID } ?? customDiscoveryRules.first { $0.id == agentID }
        guard record != nil || rule != nil else { throw CoreError.invalid("Unknown Agent") }
        var roots = record?.descriptor.sourceRoots ?? []
        if let rule {
            roots += rule.directories.map { $0.hasPrefix("/") ? $0 : home + "/" + $0 }
            roots += SourceInspectionCollector.roots(for: agentID, home: home)
        }
        let scope = roots
        var report = await Task.detached(priority: .utility) { TokenSourceSurvey.inspect(agentID: agentID, roots: scope) }.value
        if let collector = registry.first(where: { $0.descriptor.agentID == agentID }), !collecting {
            collecting = true
            do {
                let result = try await collector.collect(store: store)
                report.collectionStatus = result.health.status
            } catch {
                report.collectionStatus = "error"; report.errors.append(error.localizedDescription)
                var health = CollectorHealth(); health.status = "error"; health.errors = [error.localizedDescription]; health.lastCollection = Utilities.iso()
                try? await store.updateHealth(collector.descriptor.id, health)
            }
            collecting = false
        } else { report.collectionStatus = collecting ? "collection_busy" : "not_collected" }
        if let record, record.descriptor.mode != "inspection" {
            report.verifiedParser = record.descriptor.parserVersion
            report.knownEvents = try await store.summary(QueryFilter(agent: agentID)).events
        }
        try await store.setSetting("token-survey:" + agentID, value: report)
        return report
    }
    public func sourceRoots() -> [String] { registry.flatMap{$0.descriptor.sourceRoots} }
    public func synchronize(changedPaths:[String]?=nil) async -> [CollectionResult] {
        guard !collecting else { return lastResults }
        collecting=true;defer { collecting=false };var results:[CollectionResult]=[]
        let discovery=changedPaths==nil ? DiscoveryEngine(home:home):nil
        if let discovery {try? await refreshDiscovery(using:discovery)}
        for collector in registry {
            if let changedPaths,!changedPaths.contains(where:{path in collector.descriptor.sourceRoots.contains{path==$0 || path.hasPrefix($0+"/")}}) {continue}
            do {
                if let discovery {try await store.registerCollector(collector.descriptor,detection:await collector.detect(using:discovery),health:await collector.health())}
                if let changedPaths {results.append(try await collector.collectChanges(store:store,paths:changedPaths))}
                else {results.append(try await collector.collect(store:store))}
            }
            catch {
                var health=CollectorHealth();health.status="error";health.errors=[error.localizedDescription];health.lastCollection=Utilities.iso()
                try? await store.updateHealth(collector.descriptor.id,health);results.append(.init(collectorID:collector.descriptor.id,health:health))
            }
        };lastResults=results;return results
    }
}
