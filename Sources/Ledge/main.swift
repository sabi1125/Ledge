import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot") {
        let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
        Snapshot.render(to: dir)
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon, no menu bar menus
    app.run()
}
