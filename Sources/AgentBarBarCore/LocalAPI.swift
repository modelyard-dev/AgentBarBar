import Foundation
import Network

public final class LocalAPIServer: @unchecked Sendable {
    private let store:EventStore
    private let snapshots:DashboardSnapshotCache
    private let cacheBoot=UUID().uuidString
    private let engine:CollectorEngine
    private let dashboard:URL?
    private let icons:URL?
    private let queue=DispatchQueue(label:"app.agentbarbar.http",qos:.utility)
    private var listener:NWListener?
    public private(set) var port:UInt16=0
    public let credential:String
    public var nativeSettingsHandler:(() -> Void)?
    public var settingsChangedHandler:((AppSettings) -> Void)?
    public var nativeStatusHandler:(() async -> NativeUIStatus)?
    public var baseURL:String { "http://127.0.0.1:\(port)" }
    public init(store:EventStore,engine:CollectorEngine,dashboard:URL?,icons:URL?=nil) {
        self.store=store;self.engine=engine;self.dashboard=dashboard;self.icons=icons;snapshots=DashboardSnapshotCache(databasePath:store.path)
        var random=SystemRandomNumberGenerator();credential=(0..<32).map{_ in String(format:"%02x",UInt8.random(in:0...255,using:&random))}.joined()
    }
    public func start(port:Int=0) async throws -> UInt16 {
        guard (0...65535).contains(port) else { throw CoreError.invalid("Invalid local API port") }
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(port))!)
        let listener=try NWListener(using:parameters);self.listener=listener
        return try await withCheckedThrowingContinuation { continuation in
            let resolved=OnceFlag()
            listener.stateUpdateHandler={ [weak self] state in
                switch state {
                case .ready:
                    if let p=listener.port?.rawValue,resolved.take() {self?.port=p;continuation.resume(returning:p)}
                case .failed(let error):if resolved.take() {continuation.resume(throwing:CoreError.io("Local API failed: \(error.localizedDescription)"))}
                default:break
                }
            }
            listener.newConnectionHandler={ [weak self] connection in self?.accept(connection) }
            listener.start(queue:queue)
        }
    }
    public func stop() { listener?.cancel() }
    private func accept(_ connection:NWConnection) {
        connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+15) { connection.cancel() }
        receive(connection,buffer:Data())
    }
    private func receive(_ connection:NWConnection,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16*1024) { [weak self] data,_,complete,error in
            guard let self,error==nil else {connection.cancel();return}
            var buffer=buffer;if let data {buffer.append(data)}
            guard buffer.count<=140*1024 else {self.send(connection,status:413,body:Data("Request too large".utf8));return}
            guard let boundary=buffer.range(of:Data("\r\n\r\n".utf8)) else {
                if buffer.count>8192 || complete {self.send(connection,status:400,body:Data("Invalid headers".utf8));return}
                self.receive(connection,buffer:buffer);return
            }
            guard boundary.lowerBound<=8192,let head=String(data:buffer[..<boundary.lowerBound],encoding:.utf8) else {self.send(connection,status:400,body:Data("Invalid headers".utf8));return}
            let lines=head.components(separatedBy:"\r\n");let first=(lines.first ?? "").split(separator:" ")
            guard first.count==3,first[2]=="HTTP/1.1" || first[2]=="HTTP/1.0" else {self.send(connection,status:400,body:Data("Invalid request".utf8));return}
            var headers:[String:String]=[:]
            for line in lines.dropFirst() {
                guard let colon=line.firstIndex(of:":") else {continue}
                let key=line[..<colon].lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
                if headers[key] != nil {self.send(connection,status:400,body:Data("Duplicate headers".utf8));return};headers[key]=value
            }
            guard headers["transfer-encoding"]==nil else {self.send(connection,status:400,body:Data("Chunked requests unsupported".utf8));return}
            let length=Int(headers["content-length"] ?? "0") ?? -1
            guard (0...131072).contains(length) else {self.send(connection,status:413,body:Data("Invalid body size".utf8));return}
            let bodyStart=boundary.upperBound
            if buffer.count-bodyStart<length {
                if complete {self.send(connection,status:400,body:Data("Incomplete body".utf8));return};self.receive(connection,buffer:buffer);return
            }
            let request=HTTPRequest(method:String(first[0]),target:String(first[1]),headers:headers,body:Data(buffer[bodyStart..<bodyStart+length]))
            Task {let response=await self.route(request);self.send(connection,status:response.status,body:response.body,type:response.type,extra:response.headers)}
        }
    }
    private func send(_ c:NWConnection,status:Int,body:Data,type:String="text/plain; charset=utf-8",extra:[String:String]=[:]) {
        let names=[200:"OK",202:"Accepted",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",409:"Conflict",413:"Payload Too Large",500:"Internal Server Error"]
        var head="HTTP/1.1 \(status) \(names[status] ?? "Error")\r\nContent-Length: \(body.count)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n"
        for (k,v) in extra {head += "\(k): \(v)\r\n"};head += "\r\n"
        var bytes=Data(head.utf8);bytes.append(body)
        c.send(content:bytes,completion:.contentProcessed{_ in c.cancel()})
    }
    private func authorized(_ request:HTTPRequest) -> Bool {
        let authorization=request.headers["authorization"]
        let cookie=request.headers["cookie"]?.components(separatedBy:";").map{$0.trimmingCharacters(in:.whitespaces)}.first{$0.hasPrefix("abb_session=")}?.dropFirst("abb_session=".count)
        return authorization=="Bearer "+credential || cookie.map(String.init)==credential
    }
    private func filter(_ c:URLComponents) throws -> QueryFilter {
        let values=Dictionary(c.queryItems?.map{($0.name,$0.value ?? "")} ?? [],uniquingKeysWith:{first,_ in first})
        func date(_ key:String) throws -> Double? {
            guard let s=values[key],!s.isEmpty else {return nil}
            guard let d=Utilities.date(s) else {throw CoreError.invalid("Invalid \(key) ISO date")};return d.timeIntervalSince1970
        }
        let start=try date("start"),end=try date("end")
        guard start==nil || end==nil || start!<end! else {throw CoreError.invalid("start must precede exclusive end")}
        let zone=values["tz"] ?? TimeZone.current.identifier
        guard TimeZone(identifier:zone) != nil else {throw CoreError.invalid("Unknown time zone")}
        return QueryFilter(start:start,end:end,agent:values["agent"],model:values["model"],project:values["project"],provider:values["provider"],session:values["session"],timeZone:zone)
    }
    private func json<T:Encodable>(_ value:T,status:Int=200) throws -> HTTPResponse {
        HTTPResponse(status:status,body:Data(try Utilities.json(value).utf8),type:"application/json; charset=utf-8")
    }
    private func route(_ r:HTTPRequest) async -> HTTPResponse {
        guard r.headers["host"]=="127.0.0.1:\(port)",r.target.hasPrefix("/"),!r.target.hasPrefix("//"),let c=URLComponents(string:baseURL+r.target) else {return .error(403,"Invalid local host")}
        if let origin=r.headers["origin"],origin != baseURL {return .error(403,"Cross-origin access denied")}
        do {
            if c.path=="/health" && r.method=="GET" {return try json(["status":"ok","service":"AgentBarBar"])}
            if !c.path.hasPrefix("/api/") {
                guard r.method=="GET" else {return .error(405,"Method not allowed")}
                return await staticFile(c.path)
            }
            guard authorized(r) else {return .error(401,"Open the dashboard from AgentBarBar to create a local session")}
            if r.method != "GET" {
                let bearer=r.headers["authorization"]=="Bearer "+credential
                guard bearer || (r.headers["origin"]==baseURL && r.headers["x-agentbarbar"]=="1") else {return .error(403,"Local mutation authorization required")}
                guard r.method=="POST" else {return .error(405,"Method not allowed")}
            }
            let f=try filter(c)
            let query=Dictionary(c.queryItems?.map{($0.name,$0.value ?? "")} ?? [],uniquingKeysWith:{first,_ in first})
            let cacheKey=DashboardSnapshotCache.key(c.path,items:c.queryItems ?? [])
            let cacheTag=cacheBoot+":"+String(await store.cacheRevision())
            if r.method=="GET",DashboardSnapshotCache.allowed(cacheKey),let body=await snapshots.fresh(cacheKey,tag:cacheTag) {return HTTPResponse(status:200,body:body,type:"application/json; charset=utf-8")}
            switch (r.method,c.path) {
            case ("GET","/api/overview"):return try await cachedJSON(store.overview(f),key:cacheKey,tag:cacheTag)
            case ("GET","/api/summary"):return try await cachedJSON(store.summary(f),key:cacheKey,tag:cacheTag)
            case ("GET","/api/agents"):return try await cachedJSON(store.agents(f),key:cacheKey,tag:cacheTag)
            case ("GET","/api/models"):return try await cachedJSON(store.groups("models",filter:f),key:cacheKey,tag:cacheTag)
            case ("GET","/api/projects"):return try await cachedJSON(store.groups("projects",filter:f),key:cacheKey,tag:cacheTag)
            case ("GET","/api/sessions"):return try await cachedJSON(store.groups("sessions",filter:f),key:cacheKey,tag:cacheTag)
            case ("GET","/api/events"):return try await cachedJSON(store.events(f,limit:Int(query["limit"] ?? "100") ?? 100,offset:Int(query["offset"] ?? "0") ?? 0,id:query["id"]),key:cacheKey,tag:cacheTag)
            case ("GET","/api/filters"):return try await cachedJSON(store.filterOptions(),key:cacheKey,tag:cacheTag)
            case ("GET","/api/collectors"):return try await cachedJSON(store.collectors(),key:cacheKey,tag:cacheTag)
            case ("GET","/api/settings"):return try json(await store.setting("app",as:AppSettings.self) ?? AppSettings())
            case ("GET","/api/status"):
                return try json(APIStatus(schemaVersion:try await store.migrationVersion(),databasePath:store.path,collecting:await engine.collecting,timeZone:TimeZone.current.identifier,supportsNativeSettings:nativeSettingsHandler != nil))
            case ("GET","/api/native-status"):
                guard let handler=nativeStatusHandler else{return .error(404,"Native diagnostics require the macOS app")}
                return try json(await handler())
            case ("POST","/api/native-settings"):
                guard let handler=nativeSettingsHandler else {return .error(404,"Native settings require the running macOS app")}
                handler();return try json(["status":"opened"],status:202)
            case ("POST","/api/settings"):
                let settings=try JSONDecoder().decode(AppSettings.self,from:r.body).validated()
                let old=try await store.setting("app",as:AppSettings.self) ?? AppSettings()
                let changesSources=old.collectorConfiguration != settings.collectorConfiguration
                let collecting=await engine.collecting
                guard !changesSources || !collecting else {return .error(409,"Wait for the current collection to finish before changing sources")}
                try await store.setSetting("app",value:settings)
                if changesSources {try await engine.configure(settings)}
                settingsChangedHandler?(settings)
                if changesSources {Task {_=await engine.synchronize()}}
                return try json(settings)
            case ("POST","/api/token-survey"):
                struct SurveyRequest: Decodable { var agentID: String }
                let request = try JSONDecoder().decode(SurveyRequest.self, from: r.body)
                return try json(await engine.surveyTokenSources(agentID: request.agentID))
            case ("GET","/api/token-survey"):
                guard let agent = c.queryItems?.first(where: { $0.name == "agent" })?.value else { return .error(400,"Agent is required") }
                return try json(await store.setting("token-survey:" + agent, as: TokenSourceSurvey.self))
            case ("POST","/api/sync"):
                if await engine.collecting {return try json(["status":"collecting"],status:202)}
                Task {_=await engine.synchronize()};return try json(["status":"scheduled"],status:202)
            default:return .error(404,"API route not found")
            }
        } catch let error as CoreError {return .error(400,error.localizedDescription)}
        catch is DecodingError {return .error(400,"Invalid settings JSON or field mapping")}
        catch {return .error(500,"Unable to complete local request; check collector health and settings")}
    }
    private func cachedJSON<T:Encodable>(_ value:T,key:String,tag:String) async throws -> HTTPResponse {
        let response=try json(value);await snapshots.record(key,body:response.body,tag:tag);return response
    }
    public func warmDashboard() async {
        let calendar=Calendar.current;let day=calendar.startOfDay(for:Date());let zone=calendar.timeZone.identifier
        let end=calendar.date(byAdding:.day,value:1,to:day)!,start=calendar.date(byAdding:.day,value:-6,to:day)!
        let scopes=[QueryFilter(timeZone:zone),QueryFilter(start:start.timeIntervalSince1970,end:end.timeIntervalSince1970,timeZone:zone)]
        for scope in scopes {
            let items=[URLQueryItem(name:"tz",value:zone)]+(scope.start.map{[URLQueryItem(name:"start",value:Utilities.iso(Date(timeIntervalSince1970:$0))),URLQueryItem(name:"end",value:Utilities.iso(end))]} ?? [])
            let tag=cacheBoot+":"+String(await store.cacheRevision())
            if let body=try? await json(store.overview(scope)).body {await snapshots.record(DashboardSnapshotCache.key("overview",items:items),body:body,tag:tag)}
        }
        let tag=cacheBoot+":"+String(await store.cacheRevision())
        if let body=try? await json(store.agents(QueryFilter(timeZone:zone))).body {await snapshots.record(DashboardSnapshotCache.key("agents",items:[URLQueryItem(name:"tz",value:zone)]),body:body,tag:tag)}
    }
    private func staticFile(_ path:String) async -> HTTPResponse {
        if path.hasPrefix("/agent-icons/"),let icons {
            let name=String(path.dropFirst("/agent-icons/".count))
            guard name.range(of:"^[a-z0-9-]+\\.png$",options:.regularExpression) != nil,let data=try? Data(contentsOf:icons.appendingPathComponent(name)) else {return .error(404,"Agent icon unavailable")}
            return HTTPResponse(status:200,body:data,type:"image/png")
        }
        guard let dashboard else {return .error(404,"Dashboard assets not found. Build with scripts/build_release_app.sh")}
        let root=dashboard.standardizedFileURL
        let file:URL
        if path=="/" || (!path.contains(".") && !path.hasPrefix("/assets/")) {file=root.appendingPathComponent("index.html")}
        else {file=root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL}
        guard file.path.hasPrefix(root.path+"/"),!path.contains(".."),let data=try? Data(contentsOf:file) else {return .error(404,"Asset not found")}
        let types=["html":"text/html; charset=utf-8","js":"text/javascript; charset=utf-8","css":"text/css; charset=utf-8","svg":"image/svg+xml","png":"image/png","ico":"image/x-icon","woff2":"font/woff2","json":"application/json"]
        var responseData=data
        if file.lastPathComponent=="index.html" {
            let stored=(try? await store.setting("app",as:AppSettings.self)) ?? AppSettings()
            let settings=(try? stored.validated()) ?? AppSettings()
            let language=settings.language
            if let boot=try? await snapshots.bootstrap(language:language),let html=String(data:data,encoding:.utf8) {
                let themedHTML=html.replacingOccurrences(of:"<html lang=\"en\">",with:"<html lang=\"en\" data-theme=\"\(settings.dashboardTheme)\" data-appearance=\"\(settings.dashboardAppearance)\">")
                responseData=Data(themedHTML.replacingOccurrences(of:"</head>",with:"<script id=\"agentbarbar-cache\" type=\"application/json\">"+boot+"</script></head>").utf8)
            }
        }
        let header=file.lastPathComponent=="index.html" ? ["Set-Cookie":"abb_session=\(credential); HttpOnly; SameSite=Strict; Path=/"] : [:]
        return HTTPResponse(status:200,body:responseData,type:types[file.pathExtension] ?? "application/octet-stream",headers:header)
    }
    public func saveRuntime(in directory:URL) throws {
        try AppPaths.prepare(directory)
        let runtime=RuntimeInfo(url:baseURL,token:credential,pid:ProcessInfo.processInfo.processIdentifier,database:store.path,startedAt:Utilities.iso())
        let path=directory.appendingPathComponent("runtime.json")
        try Data(Utilities.json(runtime).utf8).write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
}
private struct HTTPRequest {var method:String;var target:String;var headers:[String:String];var body:Data}
private final class OnceFlag:@unchecked Sendable {
    private let lock=NSLock();private var used=false
    func take() -> Bool {lock.lock();defer{lock.unlock()};guard !used else{return false};used=true;return true}
}
private struct HTTPResponse {
    var status:Int;var body:Data;var type:String;var headers:[String:String]=[:]
    static func error(_ status:Int,_ message:String) -> HTTPResponse {
        HTTPResponse(status:status,body:Data(((try? Utilities.json(["error":message])) ?? "{}").utf8),type:"application/json; charset=utf-8")
    }
}
public struct RuntimeInfo:Codable,Sendable {public var url:String;public var token:String;public var pid:Int32;public var database:String;public var startedAt:String}
public struct APIStatus:Codable,Sendable {public var schemaVersion:Int;public var databasePath:String;public var collecting:Bool;public var timeZone:String;public var supportsNativeSettings:Bool}
public struct NativeUIStatus:Codable,Sendable {
    public var statusItemVisible:Bool
    public var templateIcon:Bool
    public var statusTitle:String
    public var popoverShown:Bool
    public var lastPopoverShowSucceeded:Bool
    public var popoverWindowID:Int?
    public var popoverWidth:Double
    public var popoverHeight:Double
    public init(statusItemVisible:Bool,templateIcon:Bool,statusTitle:String,popoverShown:Bool,lastPopoverShowSucceeded:Bool,popoverWindowID:Int?,popoverWidth:Double,popoverHeight:Double) {
        self.statusItemVisible=statusItemVisible;self.templateIcon=templateIcon;self.statusTitle=statusTitle;self.popoverShown=popoverShown
        self.lastPopoverShowSucceeded=lastPopoverShowSucceeded;self.popoverWindowID=popoverWindowID;self.popoverWidth=popoverWidth;self.popoverHeight=popoverHeight
    }
}
