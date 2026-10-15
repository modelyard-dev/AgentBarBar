import Foundation
import AgentBarBarCore
import Darwin

@main struct AgentBarBarCLI {
    static func main() async {
        do {
            let args=Array(CommandLine.arguments.dropFirst())
            if args.contains("--help") || args.isEmpty {
                print("agentbarbar-cli --collect|--summary|--serve [--db /path/usage.sqlite] [--home /test/home] [--dashboard /path/dist] [--port 0]")
                return
            }
            func value(_ flag:String) -> String? {guard let i=args.firstIndex(of:flag),i+1<args.count else{return nil};return args[i+1]}
            let path=value("--db") ?? AppPaths.database
            let store=try EventStore(path:path)
            let engine=CollectorEngine(store:store,home:value("--home") ?? FileManager.default.homeDirectoryForCurrentUser.path)
            let settings=try await store.setting("app",as:AppSettings.self) ?? AppSettings()
            try await engine.configure(settings)
            if args.contains("--collect") {print(try Utilities.json(await engine.synchronize()))}
            if args.contains("--summary") {print(try Utilities.json(await store.summary()))}
            if args.contains("--serve") {
                let dashboard=URL(fileURLWithPath:value("--dashboard") ?? FileManager.default.currentDirectoryPath+"/Dashboard/dist")
                let server=LocalAPIServer(store:store,engine:engine,dashboard:dashboard)
                await server.warmDashboard()
                _=try await server.start(port:Int(value("--port") ?? "0") ?? 0)
                try server.saveRuntime(in:URL(fileURLWithPath:path).deletingLastPathComponent())
                print("AgentBarBar local API: \(server.baseURL)");fflush(stdout)
                let sigterm=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global());let sigint=DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
                signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN)
                await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
                    let lock=NSLock();var finished=false
                    let stop={lock.lock();defer{lock.unlock()};if !finished{finished=true;continuation.resume()}}
                    sigterm.setEventHandler(handler:stop);sigint.setEventHandler(handler:stop);sigterm.resume();sigint.resume()
                }
                server.stop();sigterm.cancel();sigint.cancel()
            }
        } catch {fputs("AgentBarBar: \(error.localizedDescription)\n",stderr);exit(1)}
    }
}
