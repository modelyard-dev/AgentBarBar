import SwiftUI
import AgentBarBarCore

struct NativeSettingsView:View {
    @ObservedObject var controller:AppController
    private var l:Localizer {controller.localizer}
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12){Image(nsImage:BrandAssets.applicationIcon).resizable().frame(width:48,height:48);VStack(alignment:.leading,spacing:4){Text("AgentBarBar").font(.system(size:18,weight:.semibold));Text(l.format("Version %@ · Local AI usage monitor",Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? l.text("development"))).font(.system(size:11)).foregroundStyle(.secondary)};Spacer()}.padding(22)
            Form {

                Section(l.text("Language")) {
                    Picker(l.text("Language"),selection:Binding(get:{controller.settings.language},set:{language in var s=controller.settings;s.language=language;controller.saveSettings(s)})) {
                        Text(l.text("Follow system")).tag("system");Text("简体中文").tag("zh-Hans");Text("English").tag("en")
                    }
                }
                Section(l.text("Menu bar")) {
                    Picker(l.text("Display"),selection:Binding(get:{controller.settings.menuBarMode},set:{mode in var s=controller.settings;s.menuBarMode=mode;controller.saveSettings(s)})) {Text(l.text("Icon only")).tag("icon");Text(l.text("Today tokens")).tag("tokens");Text(l.text("Active agents")).tag("agents");Text(l.text("Estimated cost")).tag("cost")}
                    Toggle(l.text("Launch at login"),isOn:Binding(get:{controller.loginEnabled},set:controller.setLogin))
                }
                DisclosureGroup(l.text("Manage connections & advanced tools")) {
                Section(l.text("Connected agents")) {
                    ForEach(controller.collectors,id:\.descriptor.id) {c in
                        VStack(alignment:.leading,spacing:5) {
                            HStack{Text(c.descriptor.name).font(.system(size:12,weight:.medium));Spacer();Text(l.text(c.health.status == "partial" ? "Partial usage" : c.health.status == "healthy" ? "Connected" : c.health.status == "error" ? "Needs attention" : c.health.status == "disabled" ? "Disabled" : "No usage yet")).font(.system(size:10)).foregroundStyle(.secondary);if !c.descriptor.id.hasPrefix("custom-"){Button(l.text("Choose folder…")){controller.chooseSource(for:c.descriptor.id)}.font(.system(size:10))}}
                            DisclosureGroup(l.text("Connection details")) {
                            Button(l.text(controller.surveyingAgents.contains(c.descriptor.agentID) ? "Surveying Token sources…" : "Find Token sources")) { controller.surveyTokenSources(agentID:c.descriptor.agentID) }
                                .font(.system(size:10)).disabled(controller.surveyingAgents.contains(c.descriptor.agentID))
                            if let report = controller.surveys[c.descriptor.agentID] {
                                DisclosureGroup(l.text("Survey results")) {
                                    Text(l.format("Checked %d files · %d candidates",report.filesChecked,report.findings.count))
                                    if let parser = report.verifiedParser {
                                        Text(l.text("Verified parser") + ": " + parser)
                                        Text(l.text("Stored usage events") + ": " + (report.knownEvents.map(String.init) ?? l.text("Unknown")))
                                    }
                                    Text(l.text("Collection result") + ": " + l.text(report.collectionStatus))
                                    Text(l.text("Candidate fields need a verified parser before they can count as usage."))
                                    if report.limited { Text(l.text("Bounded search reached a limit; absence of findings is not proof that no Token records exist.")) }
                                    ForEach(report.findings,id:\.path) { finding in
                                        Text(finding.path).textSelection(.enabled)
                                        Text(finding.fields.joined(separator:", ")).textSelection(.enabled)
                                    }
                                    ForEach(report.errors,id:\.self) { Text(l.diagnostic($0)).foregroundStyle(.red) }
                                }.font(.system(size:10)).foregroundStyle(.secondary)
                            }
                            if let issue = controller.surveyErrors[c.descriptor.agentID] { Text(l.diagnostic(issue)).font(.system(size:10)).foregroundStyle(.red) }
                            if let coverage=c.coverage {
                                DisclosureGroup(l.text("History coverage") + ": " + l.text(coverage.status)) {
                                    Text(l.text("Observed records") + ": " + String(coverage.records))
                                    Text((coverage.earliest ?? l.text("Unknown")) + " — " + (coverage.latest ?? l.text("Unknown")))
                                    ForEach(coverage.notes,id:\.self) {Text(l.text($0))}
                                    if let rec=coverage.reconciliation {Text(l.text("Reconciliation") + ": " + l.text(rec.status) + " · " + rec.checkedAt)}
                                    if let history=coverage.historical {
                                        Text(l.text("Historical cache evidence (not merged)"))
                                        Text((history.startDate ?? l.text("Unknown")) + " — " + (history.endDate ?? l.text("Unknown")))
                                        Text(l.text("Reported sessions") + ": " + (history.reportedSessions.map(String.init) ?? l.text("Unknown")))
                                        ForEach(history.models,id:\.model) { model in Text(model.model).textSelection(.enabled) }
                                    }
                                    ForEach(coverage.errors,id:\.self) {Text(l.text($0)).foregroundStyle(.red)}
                                }.font(.system(size:10)).foregroundStyle(.secondary)
                            }
                            ForEach(c.descriptor.sourceRoots,id:\.self){Text($0).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)}
                            if !c.health.diagnostics.isEmpty {
                                DisclosureGroup(l.format("Source notes (%d)", c.health.diagnostics.count)) {
                                    ForEach(c.health.diagnostics, id: \.message) { item in
                                        Text(l.diagnostic(item.message)).font(.system(size:10))
                                            .foregroundStyle(item.severity == .info ? Color.secondary : item.severity == .warning ? Color.orange : Color.red)
                                            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                                    }
                                }.font(.system(size:10)).foregroundStyle(.secondary)

                            }
                            }
                        }.padding(.vertical,8)
                    }
                }

                Section(l.text("Privacy")) {
                    Text(l.text("Only usage metadata is stored on this Mac. Prompts, responses, code and credentials are excluded. No telemetry is uploaded.")).font(.system(size:11)).foregroundStyle(.secondary)
                    HStack{Button(l.text("Show database")){controller.revealDatabase()};Spacer();Button(l.text("Dashboard settings")){controller.openDashboard(path:"/settings")}}
                }
                }
                if let error=controller.error{Section{Text(l.diagnostic(error)).font(.system(size:11)).foregroundStyle(.red)}}
                AppUpdateSettings(updater: controller.appUpdater, localizer: l)
            }.formStyle(.grouped)
            HStack{Text(l.text("Updates automatically")).font(.system(size:9)).foregroundStyle(.secondary);Spacer();Button(l.text(controller.collecting ? "Collecting…":"Sync now")){Task{await controller.synchronize()}}.disabled(controller.collecting)}.padding(15)
        }.frame(width:520,height:440)
    }
}
