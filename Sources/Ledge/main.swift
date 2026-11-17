import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot") {
        let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
        Snapshot.render(to: dir)
        exit(0)
    }
    #if DEBUG
    if args.contains("--bench-notes") { NotesBench.run(); exit(0) }
    if args.contains("--try-lists") { ListTrial.run(); exit(0) }
    if let i = args.firstIndex(of: "--render-notes"), i + 1 < args.count { NotesRender.run(to: args[i + 1]); exit(0) }
    #endif

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon, no menu bar menus
    app.run()
}
