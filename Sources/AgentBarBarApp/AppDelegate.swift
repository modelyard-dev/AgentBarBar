import AppKit
import SwiftUI
import AgentBarBarCore

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    private let controller=AppController()
    private var item:NSStatusItem?
    private let popover=NSPopover()
    private var lastPopoverShowSucceeded=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        if let id=Bundle.main.bundleIdentifier,NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {NSApp.terminate(nil);return}
        NSApp.applicationIconImage=BrandAssets.applicationIcon
        controller.appUpdater.start()
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength);item.autosaveName="AgentBarBar";self.item=item
        item.button?.image=MenuIcon.image();item.button?.imagePosition = .imageLeading
        item.button?.target=self;item.button?.action=#selector(togglePopover)
        item.button?.setAccessibilityLabel(controller.localizer.text("AgentBarBar usage"))
        popover.behavior = .transient;popover.animates=false
        let hosting=NSHostingController(rootView:PopoverView(controller:controller,close:{[weak self] in self?.popover.performClose(nil)}))
        hosting.sizingOptions=[.preferredContentSize]
        popover.contentViewController=hosting
        sizePopover()
        controller.changed={[weak self] in self?.updateItem()};updateItem();controller.start()
        controller.nativeInspection={[weak self] in
            let p=self?.popover
            return NativeUIStatus(statusItemVisible:self?.item?.isVisible ?? false,templateIcon:self?.item?.button?.image?.isTemplate ?? false,
                statusTitle:self?.item?.button?.title ?? "",popoverShown:p?.isShown ?? false,lastPopoverShowSucceeded:self?.lastPopoverShowSucceeded ?? false,
                popoverWindowID:p?.contentViewController?.view.window?.windowNumber,popoverWidth:Double(p?.contentSize.width ?? 0),popoverHeight:Double(p?.contentSize.height ?? 0))
        }
        let menu=NSMenu();let appItem=NSMenuItem();menu.addItem(appItem)
        let applicationMenu=NSMenu(title:"AgentBarBar")
        applicationMenu.addItem(withTitle:"About AgentBarBar",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        let updates=applicationMenu.addItem(withTitle:"Check for Updates…",action:#selector(checkForUpdates),keyEquivalent:"");updates.target=self
        let settings=applicationMenu.addItem(withTitle:"Settings…",action:#selector(openSettings),keyEquivalent:",");settings.target=self
        let usage=applicationMenu.addItem(withTitle:"Show Usage",action:#selector(togglePopover),keyEquivalent:"u");usage.target=self;usage.keyEquivalentModifierMask=[.command,.shift]
        applicationMenu.addItem(.separator());applicationMenu.addItem(withTitle:"Quit AgentBarBar",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=applicationMenu;NSApp.mainMenu=menu;updateItem()
    }
    private func updateItem() {
        item?.button?.image=MenuIcon.image(state:controller.iconState)
        item?.button?.title=controller.title.isEmpty ? "":" "+controller.title
        item?.button?.font=NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium)
        let l=controller.localizer
        item?.button?.toolTip=l.text("AgentBarBar · Local agent usage")+" · "+controller.title
        item?.button?.setAccessibilityLabel(l.text("AgentBarBar usage"))
        let menuTitles=["About AgentBarBar","Check for Updates…","Settings…","Show Usage","","Quit AgentBarBar"]
        if let menu=NSApp.mainMenu?.items.first?.submenu {
            for (index,key) in menuTitles.enumerated() where index<menu.items.count && !key.isEmpty {menu.items[index].title=l.text(key)}
        }
        controller.updateWindowLanguage()
        popover.contentViewController?.view.window?.title=l.text("AgentBarBar Usage")
        if popover.isShown {DispatchQueue.main.async{[weak self] in self?.sizePopover()}}
    }
    private func sizePopover() {
        guard let hosting=popover.contentViewController as? NSHostingController<PopoverView> else{return}
        let ideal=hosting.sizeThatFits(in:CGSize(width:330,height:1000))
        popover.contentSize=NSSize(width:330,height:min(max(ideal.height,220),720))
    }
    @objc private func togglePopover() {
        guard let button=item?.button else{return}
        if popover.isShown{popover.performClose(nil)}else{
            sizePopover();NSApp.activate(ignoringOtherApps:true);popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
            lastPopoverShowSucceeded=popover.isShown
            popover.contentViewController?.view.window?.title=controller.localizer.text("AgentBarBar Usage")
        }
    }
    @objc private func openSettings() {popover.performClose(nil);controller.showSettings()}
    @objc private func checkForUpdates() {popover.performClose(nil);controller.appUpdater.check()}
    func applicationWillTerminate(_ notification:Notification) {controller.stop()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {if !hasVisibleWindows{controller.showSettings()};return true}
}
