import AppKit
import SwiftUI
import ServiceManagement
import AgentBarBarCore

@MainActor final class AppController:ObservableObject {
    let appUpdater = AppUpdater()
    @Published var snapshot:MenuSnapshot?
    @Published var surveys: [String: TokenSourceSurvey] = [:]
    @Published var surveyingAgents = Set<String>()
    @Published var surveyErrors: [String: String] = [:]
    @Published var collectors:[CollectorRecord]=[]
    @Published var settings=AppSettings()
    @Published var collecting=false
    @Published var error:String?
    @Published var dashboardURL:String?
    @Published var loginEnabled=SMAppService.mainApp.status == .enabled
    var changed:(() -> Void)?
    var nativeInspection:(() -> NativeUIStatus)?
    private(set) var store:EventStore?
    private var engine:CollectorEngine?
    private var server:LocalAPIServer?
    private var watcher:SourceWatcher?
    private var timer:Timer?
    private var pending:DispatchWorkItem?
    private var resyncNeeded=false
    private var dirtyPaths=Set<String>()
    private var fullReconciliationRequested=false
    private var day=Calendar.current.startOfDay(for:Date())
    private var lastSavedConfiguration=""
    private var settingsWindow:NSWindow?
    private var agentImages:[String:NSImage]=[:]
    private var cachedAgentIcons:[String:String]=[:]
    var localizer:Localizer {Localizer(settings.language)}
    func updateWindowLanguage() {appUpdater.language=settings.language;settingsWindow?.title=localizer.text("AgentBarBar Settings")}
    var iconState:String {if error != nil{return "error"};if collecting{return "collecting"};if collectors.contains(where: { $0.enabled && ($0.health.status == "error" || $0.health.status == "permission_denied" || $0.health.diagnostics.contains { $0.severity == .error }) }) { return "error" }
        if collectors.contains(where: { $0.enabled && $0.health.diagnostics.contains { $0.severity == .warning } }) { return "warning" };return "normal"}
    var title:String {
        switch settings.menuBarMode {
        case "icon":return ""
        case "agents":return "\(snapshot?.today.activeAgents ?? 0)"
        case "cost":return snapshot?.today.cost.map{String(format:"$%.2f",$0)} ?? "—"
        default:return Self.compact(snapshot?.today.metrics["total"]?.value)
        }
    }
    static func compact(_ value:Int64?) -> String {
        guard let value else{return "—"}
        if value>=1_000_000_000{return String(format:"%.2fB",Double(value)/1e9)}
        if value>=1_000_000{return String(format:"%.2fM",Double(value)/1e6)}
        if value>=1_000{return String(format:"%.1fK",Double(value)/1e3)}
        return String(value)
    }
    func start() {
        Task {
            do {
                try AppPaths.prepare()
                let store=try EventStore(path:AppPaths.database);self.store=store
                let engine=CollectorEngine(store:store);self.engine=engine
                settings=try await store.setting("app",as:AppSettings.self) ?? AppSettings()
                try await engine.configure(settings);lastSavedConfiguration=try Utilities.json(settings)
                let icons=AppPaths.directory.appendingPathComponent("agent-icons",isDirectory:true)
                try FileManager.default.createDirectory(at:icons,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let dashboard=Bundle.main.resourceURL?.appendingPathComponent("Dashboard")
                let fallback=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Dashboard/dist")
                let server=LocalAPIServer(store:store,engine:engine,dashboard:dashboard.flatMap{FileManager.default.fileExists(atPath:$0.path) ? $0:nil} ?? fallback,icons:icons)
                server.nativeSettingsHandler={[weak self] in Task{@MainActor in self?.showSettings()}}
                server.settingsChangedHandler={[weak self] value in Task{@MainActor in await self?.applyWebSettings(value)}}
                server.nativeStatusHandler={[weak self] in await MainActor.run{self?.nativeInspection?() ?? NativeUIStatus(statusItemVisible:false,templateIcon:false,statusTitle:"",popoverShown:false,lastPopoverShowSucceeded:false,popoverWindowID:nil,popoverWidth:0,popoverHeight:0)}}
                await server.warmDashboard()
                _=try await server.start(port:settings.port);try server.saveRuntime(in:AppPaths.directory);self.server=server;dashboardURL=server.baseURL
                await updateSnapshot();await cacheAgentIcons(in:icons)
                await resetMonitoring();await synchronize()
            }catch{self.error=error.localizedDescription;changed?()}
        }
    }
    func synchronize(changedPaths:[String]?=nil) async {
        guard let engine,let store else{return}
        if collecting {resyncNeeded=true;if let changedPaths{dirtyPaths.formUnion(changedPaths)}else{fullReconciliationRequested=true};return}
        collecting=true;changed?()
        let results=await engine.synchronize(changedPaths:changedPaths);collecting=false
        if changedPaths==nil {await cacheAgentIcons(in:AppPaths.directory.appendingPathComponent("agent-icons",isDirectory:true))}
        collectors=(try? await store.collectors()) ?? collectors
        let currentDay=Calendar.current.startOfDay(for:Date())
        if snapshot==nil || results.contains(where:{$0.health.imported>0 || $0.health.updated>0}) || currentDay != day || (changedPaths==nil && (snapshot?.today.activeAgents ?? 0)>0) {day=currentDay;await updateSnapshot()}
        if let saved=try? await store.setting("app",as:AppSettings.self),let signature=try? Utilities.json(saved),signature != lastSavedConfiguration {
            settings=saved;try? await engine.configure(saved);lastSavedConfiguration=signature;await resetMonitoring();resyncNeeded=true
        }
        error=nil;changed?()
        if resyncNeeded {resyncNeeded=false;scheduleSync(paths:fullReconciliationRequested ? nil:Array(dirtyPaths))}
    }
    private func updateSnapshot() async {
        guard let store else{return}
        do {snapshot=try await store.menuSnapshot();collectors=try await store.collectors();changed?()}catch{self.error=error.localizedDescription;changed?()}
    }
    func scheduleSync(paths:[String]?=nil) {
        if let paths{dirtyPaths.formUnion(paths)}else{fullReconciliationRequested=true}
        guard pending==nil else{return}
        let item=DispatchWorkItem{[weak self] in
            guard let self else{return};self.pending=nil
            let paths=self.fullReconciliationRequested ? nil:Array(self.dirtyPaths)
            self.dirtyPaths.removeAll();self.fullReconciliationRequested=false
            Task{await self.synchronize(changedPaths:paths)}
        };pending=item;DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:item)
    }
    private func resetMonitoring() async {
        guard let engine else{return}
        watcher=SourceWatcher(paths:await engine.sourceRoots()){[weak self] paths in self?.scheduleSync(paths:paths)}
        timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:Double(settings.reconciliationSeconds),repeats:true){[weak self] _ in
            Task{@MainActor in await self?.synchronize()}
        };timer?.tolerance=15
    }
    func surveyTokenSources(agentID: String) {
        guard let engine, !surveyingAgents.contains(agentID) else { return }
        surveyingAgents.insert(agentID); surveyErrors[agentID] = nil
        Task {
            defer { surveyingAgents.remove(agentID) }
            do { surveys[agentID] = try await engine.surveyTokenSources(agentID: agentID); await updateSnapshot() }
            catch { surveyErrors[agentID] = error.localizedDescription }
        }
    }
    func refreshPopover() {Task{await updateSnapshot()}}
    func openDashboard(path:String="/") {if let dashboardURL,let url=URL(string:dashboardURL+path){NSWorkspace.shared.open(url)}}
    func showSettings() {
        if let settingsWindow {settingsWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:440),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title=localizer.text("AgentBarBar Settings");window.contentView=NSHostingView(rootView:NativeSettingsView(controller:self));window.isReleasedWhenClosed=false;window.center()
        settingsWindow=window;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func saveSettings(_ value:AppSettings) {
        Task {
            do {
                guard let store,let engine else{return}
                let value=try value.validated();let changesSources=settings.collectorConfiguration != value.collectorConfiguration
                let changesTimer=settings.reconciliationSeconds != value.reconciliationSeconds
                try await store.setSetting("app",value:value);settings=value;updateWindowLanguage()
                if changesSources && !collecting{try await engine.configure(value)}
                if !changesSources || !collecting{lastSavedConfiguration=try Utilities.json(value)}
                if changesSources || changesTimer {await resetMonitoring()}
                changed?();if changesSources {scheduleSync()}
            }catch{self.error=error.localizedDescription;changed?()}
        }
    }
    private func applyWebSettings(_ value:AppSettings) async {
        let changesSources=settings.collectorConfiguration != value.collectorConfiguration
        let changesTimer=settings.reconciliationSeconds != value.reconciliationSeconds
        settings=value;updateWindowLanguage();lastSavedConfiguration=(try? Utilities.json(value)) ?? ""
        if changesSources || changesTimer {await resetMonitoring()}
        changed?();if changesSources {scheduleSync()}
    }
    func chooseSource(for collector:String) {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        panel.prompt=localizer.text("Select");panel.message=localizer.text("Select an Agent usage directory. AgentBarBar reads it without changing Agent files.")
        if panel.runModal() == .OK,let url=panel.url {var s=settings;s.sourceOverrides[collector]=[url.path];saveSettings(s)}
    }
    func setLogin(_ enabled:Bool) {
        do {if enabled{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()};loginEnabled=SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {SMAppService.openSystemSettingsLoginItems()}
        }catch{self.error="Launch at login: "+error.localizedDescription}
    }
    func revealDatabase() {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:AppPaths.database)])}
    func stop() {pending?.cancel();timer?.invalidate();watcher=nil;server?.stop()}
    func agentImage(_ id:String) -> NSImage? {agentImages[id]}
    private func cacheAgentIcons(in directory:URL) async {
        guard let store,let agents=try? await store.agentIdentities() else{return}
        for agent in agents {
            guard let path=agent.detection.applicationPath else{continue}
            let signature=path+"|"+(agent.detection.version ?? "")
            if cachedAgentIcons[agent.id]==signature {continue}
            cachedAgentIcons[agent.id]=signature
            let image=NSWorkspace.shared.icon(forFile:path);agentImages[agent.id]=image
            let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            image.draw(in:NSRect(x:0,y:0,width:64,height:64));NSGraphicsContext.restoreGraphicsState()
            if let data=rep.representation(using:.png,properties:[:]) {try? data.write(to:directory.appendingPathComponent(agent.id+".png"),options:.atomic)}
        }
    }
}
