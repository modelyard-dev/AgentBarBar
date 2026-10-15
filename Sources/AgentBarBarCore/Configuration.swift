import Foundation

public struct AppSettings: Codable, Sendable {
    public var language: String = "system"
    public var dashboardTheme: String = "forest"
    public var dashboardAppearance: String = "system"
    public var menuBarMode: String = "tokens"
    public var port: Int = 0
    public var reconciliationSeconds: Int = 120
    public var disabledCollectors: [String] = []
    public var sourceOverrides: [String: [String]] = [:]
    public var customAgents: [CustomAgent] = []
    public init() {}
    public var collectorConfiguration: String {
        var copy=self;copy.language="system";copy.dashboardTheme="forest";copy.dashboardAppearance="system";copy.menuBarMode="tokens";copy.port=0;copy.reconciliationSeconds=120
        return (try? Utilities.json(copy)) ?? ""
    }
    private enum CodingKeys: String, CodingKey { case language, dashboardTheme, dashboardAppearance, menuBarMode, port, reconciliationSeconds, disabledCollectors, sourceOverrides, customAgents }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "system"
        dashboardTheme = try c.decodeIfPresent(String.self, forKey: .dashboardTheme) ?? "forest"
        dashboardAppearance = try c.decodeIfPresent(String.self, forKey: .dashboardAppearance) ?? "system"
        menuBarMode = try c.decodeIfPresent(String.self, forKey: .menuBarMode) ?? "tokens"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        reconciliationSeconds = try c.decodeIfPresent(Int.self, forKey: .reconciliationSeconds) ?? 120
        disabledCollectors = try c.decodeIfPresent([String].self, forKey: .disabledCollectors) ?? []
        sourceOverrides = try c.decodeIfPresent([String: [String]].self, forKey: .sourceOverrides) ?? [:]
        customAgents = try c.decodeIfPresent([CustomAgent].self, forKey: .customAgents) ?? []
    }
    public func validated() throws -> AppSettings {
        guard ["forest", "paper", "ocean", "mono"].contains(dashboardTheme), ["system", "light", "dark"].contains(dashboardAppearance) else { throw CoreError.invalid("Invalid appearance settings") }
        guard ["system", "en", "zh-Hans"].contains(language), ["icon", "tokens", "agents", "cost"].contains(menuBarMode),port==0 || (1024...65535).contains(port),
              (60...3600).contains(reconciliationSeconds) else { throw CoreError.invalid("Invalid settings: port must be 0 or 1024–65535; reconciliation 60–3600 seconds") }
        let knownCollectors=Set(["codex-local","claude-local","pi-local","opencode-local","kimi-local","workbuddy-local","dsh-local","gemini-local","qwen-local","cline-local","antigravity-local","antigravity-ide-local"] + DiscoveryEngine.catalog.map{$0.id+"-inspection"})
        for (id,paths) in sourceOverrides {
            guard knownCollectors.contains(id),paths.count<=8 else { throw CoreError.invalid("Invalid collector source override") }
            for path in paths { try Self.validateRoot(path) }
        }
        guard customAgents.count<=32,Set(customAgents.map(\.id)).count==customAgents.count else { throw CoreError.invalid("Custom Agent IDs must be unique; maximum 32") }
        for agent in customAgents { try agent.validate() }
        return self
    }
    public static func validateRoot(_ path: String) throws {
        let url=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/"),!path.contains("\0"),url.path != "/",url.path != home,
              !["/Users","/Volumes","/System","/Library","/Applications","/private","/tmp"].contains(url.path) else {
            throw CoreError.invalid("Select a specific Agent data directory, not an entire home, disk, or system directory")
        }
    }
}

public struct CustomAgent: Codable, Sendable {
    public var id: String
    public var name: String
    public var executable: String?
    public var processName: String?
    public var logDirectory: String
    public var dataDirectory: String?
    public var mapping: [String:String]
    public var inputIncludesCache: Bool
    public var discoveryOnly: Bool?
    public init(id: String, name: String, executable: String? = nil, processName: String? = nil, logDirectory: String,
                dataDirectory: String? = nil, mapping: [String:String], inputIncludesCache: Bool = true, discoveryOnly:Bool=false) {
        self.id=id;self.name=name;self.executable=executable;self.processName=processName;self.logDirectory=logDirectory
        self.dataDirectory=dataDirectory;self.mapping=mapping;self.inputIncludesCache=inputIncludesCache;self.discoveryOnly=discoveryOnly
    }
    public func validate() throws {
        if discoveryOnly==true {
            guard id.range(of:"^[a-z][a-z0-9-]{0,47}$",options:.regularExpression) != nil,!name.isEmpty,name.count<=80,
                  executable?.isEmpty==false || processName?.isEmpty==false || dataDirectory != nil else{throw CoreError.invalid("Custom discovery requires a name and executable, process name or data directory")}
            if let dataDirectory {try AppSettings.validateRoot(dataDirectory)}
            return
        }
        guard id.range(of:"^[a-z][a-z0-9-]{0,47}$",options:.regularExpression) != nil,!name.isEmpty,name.count<=80,
              mapping["timestamp"] != nil,mapping["id"] != nil,mapping["total"] != nil || (mapping["input"] != nil && mapping["output"] != nil) else {
            throw CoreError.invalid("Custom Agent requires a name, stable event ID, ISO timestamp and token mapping")
        }
        try AppSettings.validateRoot(logDirectory)
        if let dataDirectory { try AppSettings.validateRoot(dataDirectory) }
        let allowed=Set(["id","timestamp","model","provider","session","cwd"]+TokenMetrics.names)
        guard mapping.allSatisfy({ allowed.contains($0.key) && !$0.value.isEmpty && $0.value.count<=160 && $0.value.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil }) else { throw CoreError.invalid("Mapping paths must be simple dot-separated JSON keys") }
    }
}

public enum AppPaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentBarBar",isDirectory:true)
    }
    public static var database: String { directory.appendingPathComponent("usage.sqlite").path }
    public static func prepare(_ directory: URL = directory) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
    }
}
