import AppKit
import SwiftUI
import AgentBarBarCore

/// Public GitHub metadata only. Installation is always performed by the user.
@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var canCheck = true
    @Published private(set) var automaticallyChecks: Bool
    @Published private(set) var downloading = false
    @Published private(set) var availableRelease: AppRelease?
    @Published private(set) var downloadedInstaller: URL?
    @Published private(set) var status = ""
    var language = "system"
    private var timer: Timer?
    private let defaults: UserDefaults
    private let session: URLSession
    private var l: Localizer { Localizer(language) }
    private var currentVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyChecks = defaults.object(forKey: "appUpdates.automatic") as? Bool ?? true
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    func start() {
        guard currentVersion != nil else { canCheck = false; return }
        Task { await scheduledCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scheduledCheck() }
        }
    }

    private func scheduledCheck() async {
        guard automaticallyChecks, canCheck, !downloading else { return }
        let last = defaults.object(forKey: "appUpdates.lastAttempt") as? Date ?? .distantPast
        let success = defaults.object(forKey: "appUpdates.lastSuccess") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 3600, Date().timeIntervalSince(success) >= 86400 else { return }
        await runCheck(manual: false)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        automaticallyChecks = enabled
        defaults.set(enabled, forKey: "appUpdates.automatic")
        if enabled { Task { await scheduledCheck() } }
    }

    func check() { Task { await runCheck(manual: true) } }

    private func runCheck(manual: Bool) async {
        guard canCheck, !downloading, let currentVersion else { return }
        canCheck = false
        status = l.text("Checking GitHub…")
        defaults.set(Date(), forKey: "appUpdates.lastAttempt")
        defer { canCheck = true }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/y2zyyr/AgentBarBar/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("AgentBarBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CoreError.invalid("Invalid GitHub response") }
            guard http.statusCode == 200 else { throw CoreError.invalid("GitHub HTTP \(http.statusCode)") }
            let release = try JSONDecoder().decode(AppRelease.self, from: data)
            guard AppRelease.versionParts(release.tagName) != nil, !release.draft, !release.prerelease else { throw CoreError.invalid("Invalid release metadata") }
            if release.isNewer(than: currentVersion) {
                _ = try release.installer()
                availableRelease = release
                defaults.set(Date(), forKey: "appUpdates.lastSuccess")
                status = l.format("Version %@ is available", release.version)
                let result = alert(title: l.format("AgentBarBar %@ is available", release.version), message: l.text("Download the installer to Downloads and open it. Drag AgentBarBar to Applications to replace your current version."), buttons: ["Download installer", "Later"])
                if result == .alertFirstButtonReturn { await download(release) }
            } else {
                defaults.set(Date(), forKey: "appUpdates.lastSuccess")
                availableRelease = nil
                status = l.format("You are up to date (%@)", currentVersion)
                if manual { _ = alert(title: l.text("You are up to date"), message: status, buttons: ["OK"]) }
            }
        } catch {
            status = l.text("Could not check for updates")
            if manual { _ = alert(title: status, message: error.localizedDescription, buttons: ["OK"]) }
        }
    }

    func downloadAvailable() {
        guard let release = availableRelease, !downloading else { return }
        Task { await download(release) }
    }

    private func download(_ release: AppRelease) async {
        guard !downloading else { return }
        downloading = true
        status = l.text("Downloading installer…")
        defer { downloading = false }
        do {
            let asset = try release.installer()
            let (temporary, response) = try await session.download(from: asset.browserDownloadURL)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CoreError.invalid("Installer download failed") }
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let destination = try await Task.detached { try AppRelease.saveInstaller(temporary, asset: asset, directory: downloads) }.value
            downloadedInstaller = destination
            status = l.text("Installer saved to Downloads. Drag the app to Applications to install.")
            guard NSWorkspace.shared.open(destination) else {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                _ = alert(title: l.text("Installer downloaded"), message: status, buttons: ["OK"])
                return
            }
        } catch {
            status = l.text("Could not download the installer")
            _ = alert(title: status, message: error.localizedDescription, buttons: ["OK"])
        }
    }

    func showDownloadedInstaller() {
        guard let downloadedInstaller else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedInstaller])
    }

    private func alert(title: String, message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: l.text($0)) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

struct AppUpdateSettings: View {
    @ObservedObject var updater: AppUpdater
    let localizer: Localizer
    var body: some View {
        Section(localizer.text("App updates")) {
            Toggle(localizer.text("Automatically check for app updates"), isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticallyChecks))
            Button(localizer.text("Check for Updates…"), action: updater.check).disabled(!updater.canCheck || updater.downloading)
            if updater.availableRelease != nil {
                Button(localizer.text("Download installer"), action: updater.downloadAvailable).disabled(updater.downloading || !updater.canCheck)
            }
            if updater.downloading { ProgressView().controlSize(.small) }
        }
    }
}
