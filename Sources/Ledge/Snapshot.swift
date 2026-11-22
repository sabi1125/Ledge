import AppKit
import LedgeCore
import SwiftUI

/// `Ledge --snapshot DIR` draws every island state to PNGs, so the look can be
/// checked without screen recording. Uses sample data, not your real music.
@MainActor
enum Snapshot {
    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Pref.registerDefaults()
        SettingsPanel.scrolls = false
        RightClickCatcher.enabled = false
        IslandRootView.drawingSnapshot = true
        let notch = NotchMetrics(width: 185, height: 32)
        let cases: [(String, IslandShape, HUD?, Bool, IslandPage)] = [
            ("f1-pill-idle", .idle, nil, false, .music),
            ("f2-pill-music", .compact, nil, true, .music),
            ("f2b-pill-music-menubar", .compact, nil, true, .music),
            ("f2c-pill-music-short", .compact, nil, true, .music),
            ("f3-pill-volume", .hud, .volume(level: 0.62, muted: false), false, .music),
            ("f4-pill-charging", .hud, .charging(percent: 82), false, .music),
            ("f5-pill-open", .expanded, nil, true, .music),
            ("f6-pill-calendar", .expanded, nil, true, .calendar),
            ("1-idle", .idle, nil, false, .music),
            ("2-compact", .compact, nil, true, .music),
            ("3-expanded", .expanded, nil, true, .music),
            ("4-expanded-paused", .expanded, nil, false, .music),
            ("5-volume", .hud, .volume(level: 0.62, muted: false), false, .music),
            ("6-brightness", .hud, .brightness(level: 0.8), false, .music),
            ("7-charging", .hud, .charging(percent: 82), false, .music),
            ("8-low-battery", .hud, .lowBattery(percent: 10), false, .music),
            ("9-calendar", .expanded, nil, true, .calendar),
            ("18-awake-on", .expanded, nil, true, .music),
            ("19-awake-menu", .expanded, nil, true, .music),
            ("20-awake-pop-on", .hud, .awakeOn(minutes: 60), false, .music),
            ("21-awake-pop-off", .hud, .awakeOff, false, .music),
            ("17-settings-pages", .settings, nil, false, .music),
            ("17-settings-indicators", .settings, nil, false, .music),
            ("17-settings-animation", .settings, nil, false, .music),
            ("17-settings-pomodoro", .settings, nil, false, .music),
            ("17-settings-awake", .settings, nil, false, .music),
            ("17-settings-switcher", .settings, nil, false, .music),
            ("17-settings-general", .settings, nil, false, .music),
            ("f9-pill-settings", .settings, nil, false, .music),
            ("12-timer-page-idle", .expanded, nil, false, .timer),
            ("22-pomo-focus", .expanded, nil, false, .timer),
            ("23-pomo-break", .expanded, nil, false, .timer),
            ("24-pomo-compact", .compact, nil, false, .music),
            ("25-pomo-pop", .hud, .pomodoro(ended: .focus, next: .shortBreak, minutes: 5), false, .music),
            ("13-timer-page-running", .expanded, nil, false, .timer),
            ("14-timer-compact", .compact, nil, false, .music),
            ("15-timer-compact-music", .compact, nil, true, .music),
            ("16-timer-done", .hud, .timerDone(duration: 1500), false, .music),
            ("f7-pill-timer", .compact, nil, false, .music),
            ("f8-pill-timer-music", .compact, nil, true, .music),
            ("26-meeting-countdown", .compact, nil, true, .music),
            ("27-meeting-pill", .meeting, nil, true, .music),
            ("28-meeting-pill-nolink", .meeting, nil, false, .music),
            ("f10-pill-meeting-countdown", .compact, nil, true, .music),
            ("f11-pill-meeting", .meeting, nil, true, .music),
            ("29-switcher", .switcher, nil, false, .music),
            ("30-switcher-grid", .switcher, nil, false, .music),
            ("10-notes", .expanded, nil, true, .notes),
            ("11-notes-empty", .expanded, nil, true, .notes),
        ]
        let now = Date()
        let cal = Calendar.current
        let at = { (h: Int, m: Int, day: Int) -> Date in
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: day, to: now)!)!
        }
        let sampleEvents = [
            CalendarItem(id: "1", title: "Design review", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200),
                         isAllDay: false, color: .orange, joinURL: URL(string: "https://meet.google.com/abc-defg-hij")),
            CalendarItem(id: "2", title: "Lunch with Mina", start: now.addingTimeInterval(1500), end: now.addingTimeInterval(4800),
                         isAllDay: false, color: .green, joinURL: nil),
            CalendarItem(id: "3", title: "Team standup", start: at(9, 30, 1), end: at(9, 45, 1),
                         isAllDay: false, color: .blue, joinURL: URL(string: "https://acme.zoom.us/j/123")),
            CalendarItem(id: "4", title: "Dentist", start: at(16, 0, 1), end: at(17, 0, 1),
                         isAllDay: false, color: .purple, joinURL: nil),
        ]
        for (name, shape, hud, playing, page) in cases {
            let awakeStore = AwakeStore()
            if name.contains("awake-on") { awakeStore.start(minutes: 60) }
            ExpandedView.snapshotMenu = name.contains("awake-menu")
            SettingsPanel.startSection = SettingsPanel.Section.allCases.first { name.hasSuffix("settings-\($0.rawValue)") } ?? .pages
            let timerStore = TimerStore()
            if name.contains("pomo") {
                timerStore.mode = .pomodoro
                if name.contains("break") { timerStore.skipPomodoro() }
                if !name.contains("pop") { timerStore.startPomodoro() }
            }
            if name.contains("timer") {
                timerStore.choose(minutes: 25)
                if !name.contains("idle") { timerStore.start() }
            }
            let calendarStore = CalendarStore()
            calendarStore.useSample(sampleEvents)
            let notesStore = NotesStore(sample: name == "10-notes"
                ? "## This week\n- [x] Call the landlord about the heater\n- [ ] Buy oat milk\n- [ ] Try **pomodoros** with the notch timer\n> Run `swift test` before pushing"
                : "")
            let model = IslandModel()
            let floating = name.hasPrefix("f")
            model.style = floating ? .floating : .notch
            model.notch = floating ? .floatingPill(menuBarHeight: name.contains("menubar") ? 25 : (name.contains("music") ? 0 : 25)) : notch
            var media = NowPlayingState()
            // Made-up songs: a short one, and a long one that has to be cut off in the floating pill.
            media.title = name.hasPrefix("f2c") ? "Fall" : (name.hasPrefix("f2") ? "Golden Hour Drive" : "Golden Hour Drive")
            media.artist = name.hasPrefix("f2c") ? "Lowtide" : (name.hasPrefix("f2") ? "Sunline and the Harbor Lights Orchestra" : "Sunline")
            media.duration = 228
            media.elapsed = 96
            media.isPlaying = playing
            media.timestamp = Date()
            model.media = media
            model.timerTitle = timerStore.live?.title ?? "Timer"
            model.timerActive = timerStore.live != nil
            let art = sampleArtwork()
            model.setArtwork(image: art, tint: ArtworkColor.tint(for: art) ?? Theme.defaultTint)
            if name.contains("meeting") {
                let link = !name.contains("nolink")
                model.meeting = .init(id: "m", title: link ? "Design review" : "Lunch with Mina",
                                      start: Date().addingTimeInterval(name.contains("countdown") ? 263 : 43),
                                      color: link ? Color(red: 0.88, green: 0.35, blue: 0.61) : .green,
                                      joinURL: link ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                                      eventID: nil, phase: name.contains("countdown") ? .countdown : .alert)
            }
            if shape == .switcher { model.showSwitcher(sampleWindows(), style: name.contains("grid") ? .grid : .strip) }
            model.forceShape(shape, hud: hud, page: page)
            model.shapeFrozen = true

            let panel = IslandLayout.panelSize(notch: model.notch, style: model.style)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.14, green: 0.11, blue: 0.31), Color(red: 0.42, green: 0.29, blue: 0.66)],
                               startPoint: .top, endPoint: .bottom)
                // Menu bar strip, for context.
                Color.white.opacity(0.06).frame(height: floating ? 25 : notch.height)
                IslandRootView(model: model, calendar: calendarStore, notes: notesStore, timer: timerStore, awake: awakeStore,
                               settings: SettingsState(), updater: Updater(), openSettings: {})
            }
            .frame(width: panel.width, height: panel.height)

            // Drawn in a real (off-screen) window, so AppKit-backed parts (text fields, the waveform,
            // scrolling lists) come out as they look on screen; SwiftUI's ImageRenderer can't draw those.
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: panel)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Let lists, previews and the first layout pass settle.
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(panel.width * scale), pixelsHigh: Int(panel.height * scale),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = panel
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
            }
        }
    }

    /// Made-up windows for the switcher: Apple's own apps, with drawn previews and invented titles.
    private static func sampleWindows() -> [SwitcherWindow] {
        let apps: [(String, String, String, NSColor)] = [
            ("Safari", "com.apple.Safari", "Ledge · GitHub", .systemBlue),
            ("Safari", "com.apple.Safari", "Swift documentation", .systemTeal),
            ("Notes", "com.apple.Notes", "Trip ideas", .systemYellow),
            ("Calendar", "com.apple.iCal", "November", .systemRed),
            ("Music", "com.apple.Music", "Golden Hour Drive", .systemPink),
        ]
        var windows: [SwitcherWindow] = []
        var icons: [pid_t: NSImage] = [:]
        var previews: [CGWindowID: CGImage] = [:]
        for (i, app) in apps.enumerated() {
            let pid = pid_t(90_000 + (app.0 == "Safari" ? 0 : i))
            let id = CGWindowID(80_000 + i)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.1) {
                icons[pid] = NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
            }
            previews[id] = samplePreview(accent: app.3)
            windows.append(SwitcherWindow(id: id, pid: pid, appName: app.0, title: app.2,
                                          bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), isOnScreen: true))
        }
        WindowCatalog.shared.useSample(icons: icons, previews: previews)
        return windows
    }

    /// A simple drawing of a window: a title bar, a sidebar and some blocks of "content".
    private static func samplePreview(accent: NSColor) -> CGImage? {
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size, flipped: true) { r in
            NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: r.width, height: 28).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 16, y: 9, width: 10, height: 10)).fill()
            }
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 28, width: 120, height: r.height - 28).fill()
            accent.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: NSRect(x: 140, y: 48, width: 200, height: 18), xRadius: 4, yRadius: 4).fill()
            NSColor(white: 0.82, alpha: 1).setFill()
            for row in 0..<5 { NSBezierPath(roundedRect: NSRect(x: 140, y: 84 + CGFloat(row) * 22, width: CGFloat(300 - row * 28), height: 10), xRadius: 3, yRadius: 3).fill() }
            accent.withAlphaComponent(0.25).setFill(); NSBezierPath(roundedRect: NSRect(x: 140, y: 205, width: 310, height: 72), xRadius: 8, yRadius: 8).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func sampleArtwork() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.75, blue: 0.54, alpha: 1),
                                NSColor(srgbRed: 0.89, green: 0.45, blue: 0.48, alpha: 1),
                                NSColor(srgbRed: 0.48, green: 0.25, blue: 0.56, alpha: 1)])!
                .draw(in: rect, angle: -45)
            return true
        }
    }
}
