import AppKit

/// Read the current signed bundle rather than an IconServices cache from an older installation.
enum BrandAssets {
    static let applicationIcon:NSImage = {
        let name=Bundle.main.infoDictionary?["CFBundleIconFile"] as? String ?? "AgentBarBar"
        let filename=name.hasSuffix(".icns") ? name : name+".icns"
        if let url=Bundle.main.resourceURL?.appendingPathComponent(filename),let image=NSImage(contentsOf:url) {return image}
        return MenuIcon.image()
    }()
}
