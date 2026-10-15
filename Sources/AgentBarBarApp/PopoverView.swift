import SwiftUI
import AgentBarBarCore

struct PopoverView:View {
    @ObservedObject var controller:AppController
    var close:() -> Void
    private var l:Localizer {controller.localizer}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Image(nsImage:BrandAssets.applicationIcon).resizable().frame(width:25,height:25);Text("AgentBarBar").font(.system(size:14,weight:.semibold));Spacer()}
            VStack(alignment:.leading,spacing:5) {
                Text(l.text("Today tokens")).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                HStack(alignment:.firstTextBaseline,spacing:7){Text(AppController.compact(controller.snapshot?.today.metrics["total"]?.value)).font(.system(size:40,weight:.semibold,design:.rounded)).monospacedDigit();Text(l.text("Tokens")).font(.system(size:12)).foregroundStyle(.secondary)}
                if let change=controller.snapshot?.changePercent {Text(l.format("%@ %.1f%% vs yesterday",change>=0 ? "↑":"↓",abs(change))).font(.system(size:10)).foregroundStyle(.secondary)}
                else{Text(l.text(controller.collecting ? "Collecting local usage…":"Source reported usage")).font(.system(size:10)).foregroundStyle(.secondary)}
            }
            if let snapshot=controller.snapshot {
                Divider()
                VStack(spacing:10){ForEach(snapshot.agents.prefix(3),id:\.id){group in
                    HStack(spacing:8){if let image=controller.agentImage(group.id){Image(nsImage:image).resizable().frame(width:17,height:17)}else{Text(String(group.name.prefix(1))).font(.system(size:11,weight:.semibold)).frame(width:17,height:17).background(.quaternary,in:RoundedRectangle(cornerRadius:3))};Text(group.name).font(.system(size:12));Spacer();Text(AppController.compact(group.summary.metrics["total"]?.value)).font(.system(size:12,design:.monospaced)).foregroundStyle(.secondary)}
                }}
            }
            if let error=controller.error {Text(l.diagnostic(error)).font(.system(size:10)).foregroundStyle(.red).lineLimit(3)}
            Divider()
            Button {close();controller.openDashboard()} label:{HStack{Text(l.text("Open Dashboard"));Spacer();Image(systemName:"arrow.up.right")}.font(.system(size:12,weight:.semibold)).padding(11).frame(maxWidth:.infinity).background(Color.accentColor.opacity(0.12),in:RoundedRectangle(cornerRadius:9))}.buttonStyle(.plain).disabled(controller.dashboardURL==nil)
            HStack {Spacer();Menu {Button(l.text("Settings…")){close();controller.showSettings()};Button(l.text("Quit")){NSApplication.shared.terminate(nil)}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width:28,height:24).accessibilityLabel(l.text("More"))}
        }.padding(20).frame(width:320).onAppear{controller.refreshPopover()}
    }
}
