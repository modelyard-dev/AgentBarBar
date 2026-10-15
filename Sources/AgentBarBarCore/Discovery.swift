import Foundation

public struct AgentDiscoveryRule: Sendable {
    public var id:String
    public var name:String
    public var binaries:[String]
    public var directories:[String]
    public var applications:[String]
    public var bundleIDs:[String]
    public var extensionIDs:[String]
    public var processes:[String]
    public var npmPackages:[String]
    public var pythonPackages:[String]
    public init(id:String,name:String,binaries:[String]=[],directories:[String]=[],applications:[String]=[],bundleIDs:[String]=[],extensionIDs:[String]=[],processes:[String]=[],npmPackages:[String]=[],pythonPackages:[String]=[]) {
        self.id=id;self.name=name;self.binaries=binaries;self.directories=directories;self.applications=applications
        self.bundleIDs=bundleIDs;self.extensionIDs=extensionIDs;self.processes=processes;self.npmPackages=npmPackages;self.pythonPackages=pythonPackages
    }
}

/// A bounded metadata inventory, shared by every rule in one discovery pass.
/// Never traverses application contents, arbitrary home folders, conversation stores or credentials.
public struct DiscoveryEngine {
    private struct Application {var path:String;var filename:String;var bundleID:String?;var version:String?}
    private struct Extension {var id:String;var version:String?;var path:String}
    public let home:String
    private let pathDirectories:[String]
    private let applications:[Application]
    private let extensions:[Extension]
    private let runningProcesses:[String]
    private let npmRoots:[String]
    public init(home:String=FileManager.default.homeDirectoryForCurrentUser.path,applicationRoots:[String]?=nil,pathDirectories:[String]?=nil,extensionRoots:[String]?=nil,runningProcesses:[String]?=nil,npmRoots:[String]?=nil) {
        self.home=home
        self.pathDirectories=pathDirectories ?? (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init)+["/opt/homebrew/bin","/usr/local/bin",home+"/.local/bin",home+"/bin",home+"/.npm-global/bin"]
        let processes=runningProcesses ?? Self.processSnapshot()
        var apps=Self.inventoryApplications(applicationRoots ?? ["/Applications",home+"/Applications"])
        // A running bundle may live outside standard install folders; inspect its exact Info.plist without scanning that disk.
        for process in processes {
            guard let range=process.range(of:".app/Contents/") else{continue}
            let path=String(process[..<range.lowerBound])+".app"
            guard !apps.contains(where:{$0.path==path}),let app=Self.applicationMetadata(URL(fileURLWithPath:path)) else{continue}
            apps.append(app)
        }
        self.applications=apps
        self.extensions=Self.inventoryExtensions(extensionRoots ?? [".vscode/extensions",".vscode-insiders/extensions",".cursor/extensions",".windsurf/extensions",".antigravity/extensions"].map{home+"/"+$0})
        self.runningProcesses=processes
        self.npmRoots=npmRoots ?? ["/opt/homebrew/lib/node_modules","/usr/local/lib/node_modules",home+"/.npm-global/lib/node_modules"]
    }
    public static let catalog:[AgentDiscoveryRule]=[
        .init(id:"codex",name:"Codex",binaries:["codex"],directories:[".codex"],applications:["Codex.app"],bundleIDs:["com.openai.codex"],npmPackages:["@openai/codex"]),
        .init(id:"claude-code",name:"Claude Code",binaries:["claude"],directories:[".claude"],bundleIDs:["com.anthropic.claude-code-url-handler"],npmPackages:["@anthropic-ai/claude-code"]),
        .init(id:"pi",name:"Pi",binaries:["pi"],directories:[".pi/agent"],npmPackages:["@earendil-works/pi-coding-agent","@mariozechner/pi-coding-agent"]),
        .init(id:"claude-desktop",name:"Claude Desktop",applications:["Claude.app"],bundleIDs:["com.anthropic.claudefordesktop"]),
        .init(id:"gemini",name:"Gemini CLI",binaries:["gemini"],directories:[".gemini"],npmPackages:["@google/gemini-cli"]),
        .init(id:"cursor",name:"Cursor",binaries:["cursor"],applications:["Cursor.app"]),
        .init(id:"windsurf",name:"Windsurf",binaries:["windsurf"],applications:["Windsurf.app"]),
        .init(id:"vscode",name:"VS Code",applications:["Visual Studio Code.app","Visual Studio Code - Insiders.app"]),
        .init(id:"copilot",name:"GitHub Copilot",binaries:["copilot"],directories:[".copilot"],extensionIDs:["github.copilot","github.copilot-chat"],npmPackages:["@github/copilot"]),
        .init(id:"opencode",name:"OpenCode",binaries:["opencode"],directories:[".config/opencode"],applications:["OpenCode.app"],bundleIDs:["ai.opencode.desktop"],npmPackages:["opencode-ai"]),
        .init(id:"continue",name:"Continue",binaries:["cn"],extensionIDs:["continue.continue"],npmPackages:["@continuedev/cli"]),
        .init(id:"cline",name:"Cline",binaries:["cline"],extensionIDs:["saoudrizwan.claude-dev"],npmPackages:["cline"]),
        .init(id:"roo",name:"Roo Code",extensionIDs:["rooveterinaryinc.roo-cline"]),
        .init(id:"aider",name:"Aider",binaries:["aider"],pythonPackages:["aider-chat"]),
        .init(id:"local-llm",name:"Ollama",binaries:["ollama"],applications:["Ollama.app"]),
        .init(id:"antigravity",name:"Antigravity",applications:["Antigravity.app"],bundleIDs:["com.google.antigravity"]),
        .init(id:"antigravity-ide",name:"Antigravity IDE",applications:["Antigravity IDE.app"],bundleIDs:["com.google.antigravity-ide"]),
        .init(id:"workbuddy",name:"WorkBuddy",applications:["WorkBuddy.app"],bundleIDs:["com.tencent.workbuddy.mac"]),
        .init(id:"deepseek-harness",name:"DeepSeek Harness",applications:["DeepSeek Harness.app"],bundleIDs:["com.deepseek.dsh"]),
        .init(id:"kimi-cli",name:"Kimi CLI",binaries:["kimi"],directories:[".kimi/sessions"],pythonPackages:["kimi-cli"]),
        .init(id:"kimi-desktop",name:"Kimi",applications:["Kimi.app"],bundleIDs:["com.moonshot.kimichat"]),
        .init(id:"minimax",name:"MiniMax",applications:["MiniMax.app"],bundleIDs:["com.minimax.agent.cn"]),
        .init(id:"manus",name:"Manus",applications:["Manus.app"],bundleIDs:["im.manus.desktop"]),
        .init(id:"doubao",name:"Doubao",applications:["Doubao.app"],bundleIDs:["com.bot.pc.doubao"]),
        .init(id:"yuanbao",name:"Tencent Yuanbao",applications:["腾讯元宝.app"],bundleIDs:["com.tencent.yuanbao"]),
        .init(id:"chatgpt",name:"ChatGPT",bundleIDs:["com.openai.chat"]),
        .init(id:"trae",name:"Trae",applications:["Trae.app","Trae CN.app"]),
        .init(id:"kiro",name:"Kiro",binaries:["kiro-cli"],applications:["Kiro.app"]),
        .init(id:"qoder",name:"Qoder",applications:["Qoder.app"]),
        .init(id:"codebuddy",name:"CodeBuddy",binaries:["codebuddy"],applications:["CodeBuddy.app"],npmPackages:["@tencent-ai/codebuddy-code"]),
        .init(id:"zed",name:"Zed",binaries:["zed"],applications:["Zed.app","Zed Preview.app"]),
        .init(id:"lm-studio",name:"LM Studio",binaries:["lms"],applications:["LM Studio.app"]),
        .init(id:"jan",name:"Jan",applications:["Jan.app"]),
        .init(id:"cherry-studio",name:"Cherry Studio",applications:["Cherry Studio.app"]),
        .init(id:"goose",name:"Goose",binaries:["goose"],applications:["Goose.app"]),
        .init(id:"qwen",name:"Qwen Code",binaries:["qwen"],npmPackages:["@qwen-code/qwen-code"]),
        .init(id:"amp",name:"Amp",binaries:["amp"],extensionIDs:["sourcegraph.amp"],npmPackages:["@sourcegraph/amp"]),
        .init(id:"droid",name:"Factory Droid",binaries:["droid"]),
        .init(id:"augment",name:"Augment",binaries:["auggie"],extensionIDs:["augment.vscode-augment"],npmPackages:["@augmentcode/auggie"]),
        .init(id:"kilo",name:"Kilo Code",binaries:["kilo"],extensionIDs:["kilocode.kilo-code"]),
        .init(id:"openclaw",name:"OpenClaw",binaries:["openclaw"],npmPackages:["openclaw"]),
        .init(id:"rovo",name:"Rovo Dev",binaries:["rovodev"]),
        .init(id:"mistral-vibe",name:"Mistral Vibe",binaries:["vibe"]),
        .init(id:"crush",name:"Crush",binaries:["crush"])
    ]
    public func detect(_ rule:AgentDiscoveryRule,sourceRoots:[String]=[]) -> DetectionResult {
        let fm=FileManager.default
        var evidence:[String]=[];var installed=false;var version:String?;var applicationPath:String?
        // Identity takes precedence over filename: the Codex app can be named ChatGPT.app.
        let apps=applications.filter { app in
            if let id=app.bundleID,rule.bundleIDs.contains(id) {return true}
            return rule.applications.contains(app.filename)
        }.sorted { a,b in
            let am=rule.bundleIDs.contains(a.bundleID ?? ""),bm=rule.bundleIDs.contains(b.bundleID ?? "")
            return am != bm ? am : a.path<b.path
        }
        for app in apps { installed=true;evidence.append("application: "+app.path+" ["+(app.bundleID ?? "unknown")+"]");if applicationPath==nil {applicationPath=app.path;version=app.version} }
        for binary in rule.binaries {
            let candidates=binary.hasPrefix("/") ? [binary] : pathDirectories.map{$0+"/"+binary}
            if let path=candidates.first(where:{fm.isExecutableFile(atPath:$0)}) {
                installed=true;evidence.append("executable: "+path)
                let resolved=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
                if applicationPath==nil,let app=applications.first(where:{resolved.hasPrefix($0.path+"/")}) {
                    applicationPath=app.path;version=app.version;evidence.append("application: "+app.path+" ["+(app.bundleID ?? "unknown")+"]")
                }
                if version==nil {version=Self.executableVersion(path,pythonPackages:rule.pythonPackages)}
            }
        }
        for package in rule.npmPackages {
            for root in npmRoots {
                let path=root+"/"+package+"/package.json"
                guard let object=Self.jsonMetadata(path),object["name"] as? String==package else{continue}
                installed=true;evidence.append("npm_package: "+package+" ("+root+")");version=version ?? object["version"] as? String;break
            }
        }
        for ext in extensions where rule.extensionIDs.contains(ext.id) { installed=true;evidence.append("editor_extension: "+ext.id+" ("+ext.path+")");version=version ?? ext.version }
        for process in runningProcesses {
            let name=URL(fileURLWithPath:process).lastPathComponent
            let appMatch=apps.contains{process.hasPrefix($0.path+"/")}
            if appMatch || rule.processes.contains(name) || rule.binaries.contains(name) {
                installed=true;evidence.append("running_process: "+process)
                if evidence.filter({$0.hasPrefix("running_process:")}).count>=2 {break}
            }
        }
        for rel in rule.directories {
            let path=rel.hasPrefix("/") ? rel : home+"/"+rel
            if fm.fileExists(atPath:path) {evidence.append("configuration_directory: "+path)}
        }
        let sources=sourceRoots.filter{fm.fileExists(atPath:$0)}
        evidence += sources.map{"usage_directory: "+$0}
        return DetectionResult(installed:installed,evidence:Array(Set(evidence)).sorted(),sourceAvailable:!sources.isEmpty,version:version,applicationPath:applicationPath)
    }
    private static func inventoryApplications(_ roots:[String]) -> [Application] {
        var found:[Application]=[];let fm=FileManager.default
        func visit(_ root:String,depth:Int) {
            guard depth<=2,let entries=try? fm.contentsOfDirectory(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else{return}
            for url in entries.prefix(512) {
                let values=try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values?.isSymbolicLink != true,values?.isDirectory==true else{continue}
                if url.pathExtension=="app" {
                    if let app=applicationMetadata(url) {found.append(app)}
                } else if ![".bundle",".framework"].contains("."+url.pathExtension) {visit(url.path,depth:depth+1)}
            }
        }
        for root in roots {visit(root,depth:0)}
        return found
    }
    private static func applicationMetadata(_ url:URL) -> Application? {
        let path=url.appendingPathComponent("Contents/Info.plist")
        guard let data=try? Data(contentsOf:path),data.count<=2*1024*1024,
              let info=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any] else{return nil}
        return Application(path:url.path,filename:url.lastPathComponent,bundleID:info["CFBundleIdentifier"] as? String,version:info["CFBundleShortVersionString"] as? String)
    }
    private static func inventoryExtensions(_ roots:[String]) -> [Extension] {
        var found:[Extension]=[];let fm=FileManager.default
        for root in roots {
            guard let names=try? fm.contentsOfDirectory(atPath:root) else{continue}
            for name in names.prefix(512) where !name.hasPrefix(".") {
                let path=root+"/"+name
                guard let obj=jsonMetadata(path+"/package.json"),let publisher=obj["publisher"] as? String,let name=obj["name"] as? String else{continue}
                found.append(Extension(id:(publisher+"."+name).lowercased(),version:obj["version"] as? String,path:path))
            }
        };return found
    }
    private static func jsonMetadata(_ path:String) -> [String:Any]? {
        guard let attrs=try? FileManager.default.attributesOfItem(atPath:path),(attrs[.size] as? NSNumber)?.intValue ?? Int.max<=2*1024*1024,
              let data=try? Data(contentsOf:URL(fileURLWithPath:path)) else{return nil}
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }
    private static func executableVersion(_ path:String,pythonPackages:[String]) -> String? {
        var url=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        if url.lastPathComponent.range(of:"^[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.]+)?$",options:.regularExpression) != nil {return url.lastPathComponent}
        if !pythonPackages.isEmpty {
            let lib=url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
            for python in ((try? FileManager.default.contentsOfDirectory(atPath:lib.path)) ?? []).prefix(16) where python.hasPrefix("python") {
                let site=lib.appendingPathComponent(python+"/site-packages")
                for name in ((try? FileManager.default.contentsOfDirectory(atPath:site.path)) ?? []).prefix(512) where name.hasSuffix(".dist-info") {
                    guard pythonPackages.contains(where:{name.hasPrefix($0.replacingOccurrences(of:"-",with:"_")+"-")}) else{continue}
                    let file=site.appendingPathComponent(name+"/METADATA")
                    guard let handle=try? FileHandle(forReadingFrom:file) else{continue};defer{try? handle.close()}
                    let data=(try? handle.read(upToCount:16*1024)) ?? Data()
                    let lines=String(decoding:data,as:UTF8.self).components(separatedBy:"\n")
                    if let line=lines.first(where:{$0.hasPrefix("Version: ")}) {return String(line.dropFirst(9)).trimmingCharacters(in:.whitespaces)}
                }
            }
        }
        // Only executable-adjacent package manifests. Never launch an Agent to discover it.
        for _ in 0..<5 {
            url.deleteLastPathComponent()
            if let v=jsonMetadata(url.appendingPathComponent("package.json").path)?["version"] as? String {return v}
            if url.path=="/" {break}
        };return nil
    }
    private static func processSnapshot() -> [String] {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/ps");process.arguments=["-axo","comm"]
        let output=Pipe();process.standardOutput=output;process.standardError=FileHandle.nullDevice
        do {try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();return String(decoding:data,as:UTF8.self).split(separator:"\n").dropFirst().map{$0.trimmingCharacters(in:.whitespaces)}}catch{return []}
    }
}
