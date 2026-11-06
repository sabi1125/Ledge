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
            ("17-settings", .settings, nil, false, .music),
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
                ? "Buy oat milk\nCall the landlord about the heater\nIdea: notch timer for pomodoros"
                : "")
            let model = IslandModel()
            let floating = name.hasPrefix("f")
            model.style = floating ? .floating : .notch
            model.notch = floating ? .floatingPill(menuBarHeight: name.contains("menubar") ? 25 : (name.contains("music") ? 0 : 25)) : notch
            var media = NowPlayingState()
            media.title = name.hasPrefix("f2c") ? "The Fall" : (name.hasPrefix("f2") ? "Tom's Diner" : "Golden Hour Drive")
            media.artist = name.hasPrefix("f2c") ? "Gregory Alan Isakov" : (name.hasPrefix("f2") ? "AnnenMayKantereit, Giant Rooks" : "Sunline")
            media.duration = 228
            media.elapsed = 96
            media.isPlaying = playing
            media.timestamp = Date()
            model.media = media
            model.timerTitle = timerStore.live?.title ?? "Timer"
            model.timerActive = timerStore.live != nil
            let art = sampleArtwork()
            model.setArtwork(image: art, tint: ArtworkColor.tint(for: art) ?? Theme.defaultTint)
            model.forceShape(shape, hud: hud, page: page)

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

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
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
