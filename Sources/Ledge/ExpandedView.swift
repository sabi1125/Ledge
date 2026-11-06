import AppKit
import LedgeCore
import SwiftUI

/// The open island: a top bar beside the notch (page name and dots), then the current page.
/// Swipe with two fingers to move between pages.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var notes: NotesStore
    @ObservedObject var timer: TimerStore
    @ObservedObject var awake: AwakeStore
    @State private var showAwakeMenu = ExpandedView.snapshotMenu
    /// For the snapshot tool only.
    static var snapshotMenu = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            pages
            if showAwakeMenu {
                // A click anywhere else in the island closes the menu.
                Color.black.opacity(0.001)
                    .onTapGesture { withAnimation(Theme.quick) { showAwakeMenu = false } }
                AwakeMenu(awake: awake) { withAnimation(Theme.quick) { showAwakeMenu = false } }
                    .padding(.top, (model.style == .notch ? model.notch.height : IslandLayout.floatingTopBar) - 2)
                    .padding(.trailing, 14)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    private var pages: some View {
        VStack(spacing: 0) {
            TopBar(model: model, awake: awake) { withAnimation(Theme.quick) { showAwakeMenu.toggle() } }
            // A carousel: every page sits side by side and the row slides to the current one,
            // so the motion always follows your swipe.
            GeometryReader { geo in
                let pages = model.pages
                let index = CGFloat(pages.firstIndex(of: model.page) ?? 0)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(pages, id: \.self) { p in
                        pageView(p)
                            // Hidden pages stop their clocks (no wasted redraws).
                            .environment(\.isVisiblePage, p == model.page)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .opacity(p == model.page ? 1 : 0.35)
                    }
                }
                .offset(x: -index * geo.size.width)
                .animation(Theme.spring, value: model.page)
            }
            .clipped()
        }
    }

    @ViewBuilder private func pageView(_ page: IslandPage) -> some View {
        switch page {
        case .music: PlayerView(model: model)
        case .calendar: CalendarPage(calendar: calendar)
        case .timer: TimerPage(timer: timer)
        case .notes: NotesPage(notes: notes, model: model)
        }
    }
}

/// Sits beside the notch: page name on the left; the stay-awake cup and page dots on the right.
struct TopBar: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var awake: AwakeStore
    var showAwakeMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Label(model.page.title, systemImage: model.page.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .labelStyle(.titleAndIcon)
                .contentTransition(.opacity)
            Spacer(minLength: model.style == .notch ? model.notch.width + 12 : 12)
            AwakeCup(awake: awake, showMenu: showAwakeMenu)
                .fixedSize()
                .padding(.trailing, 8)
            HStack(spacing: 6) {
                ForEach(model.pages, id: \.self) { p in
                    Circle()
                        .fill(p == model.page ? Color.white : Color(white: 0.32))
                        .frame(width: 6, height: 6)
                        .padding(3)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Theme.spring) { model.show(page: p) } }
                        .help(p.title)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: model.style == .notch ? model.notch.height : IslandLayout.floatingTopBar)
        .padding(.top, model.style == .notch ? 0 : 2)
    }
}

// MARK: - Calendar

struct CalendarPage: View {
    @ObservedObject var calendar: CalendarStore

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            DateBadge(date: Date())
            Group {
                switch calendar.access {
                case .granted: EventList(events: calendar.events)
                case .notAsked:
                    Message(title: "See your upcoming events here",
                            detail: "Ledge reads the calendars you've added to the Calendar app.",
                            button: "Show my calendar") { calendar.requestAccess() }
                case .denied:
                    Message(title: "Calendar access is off",
                            detail: "Turn on Ledge in Privacy & Security → Calendars.",
                            button: "Open Settings") { calendar.openCalendarPrivacySettings() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .onAppear { calendar.refresh() }
    }
}

private struct DateBadge: View {
    var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.calendarRed)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 38, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(date.formatted(.dateTime.month(.wide)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(width: 70, alignment: .leading)
    }
}

private struct EventList: View {
    var events: [CalendarItem]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let upcoming = events.filter { $0.end > context.date }
            if upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing coming up")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Your calendar is clear for today and tomorrow.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(upcoming.prefix(3)) { EventRow(event: $0, now: context.date) }
                    if upcoming.count > 3 {
                        Text("+\(upcoming.count - 3) more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

private struct EventRow: View {
    var event: CalendarItem
    var now: Date

    var body: some View {
        HStack(spacing: 9) {
            Capsule().fill(event.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(event.isOngoing(at: now) ? Theme.green : Theme.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if let url = event.joinURL {
                Button("Join") { NSWorkspace.shared.open(url) }
                    .buttonStyle(JoinButtonStyle())
            }
        }
    }

    private var timeText: String {
        let cal = Calendar.current
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let tomorrow = !cal.isDateInToday(event.start) && event.start > now
        if event.isAllDay { return tomorrow ? "Tomorrow · All day" : "All day" }
        if event.isOngoing(at: now) { return "Now · until \(time(event.end))" }
        if tomorrow { return "Tomorrow \(time(event.start))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        let range = "\(time(event.start)) – \(time(event.end))"
        return minutes <= 60 ? "\(range) · in \(max(1, minutes)) min" : range
    }
}

private struct Message: View {
    var title: String
    var detail: String
    var button: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(JoinButtonStyle())
                .padding(.top, 4)
        }
        .padding(.top, 4)
    }
}

struct JoinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.joinBlue.opacity(configuration.isPressed ? 0.7 : 1)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

// MARK: - Notes

struct NotesPage: View {
    @ObservedObject var notes: NotesStore
    @ObservedObject var model: IslandModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
            if notes.text.isEmpty {
                Text("Jot something down… it saves automatically")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.42))
                    .padding(.leading, 12)
                    .padding(.top, 7)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.1)))
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .onChange(of: focused) { _, now in model.isTyping = now }
        .onChange(of: model.isTyping) { _, now in if !now { focused = false } }
        .onDisappear { notes.saveNow() }
    }
}

// MARK: - Timer

struct TimerPage: View {
    @ObservedObject var timer: TimerStore
    @Environment(\.isVisiblePage) private var visible

    var body: some View {
        // Ticks only while it's on screen and something is counting down.
        TimelineView(.animation(minimumInterval: 0.5, paused: !(visible && timer.liveIsRunning))) { context in
            HStack(alignment: .center, spacing: 16) {
                if timer.mode == .timer { timerLeft(now: context.date) } else { pomodoroLeft(now: context.date) }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 10) {
                    ModeSwitch(mode: $timer.mode)
                    if timer.mode == .timer { presets(timer.countdown) } else { nextUp }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: Timer

    private func timerLeft(now: Date) -> some View {
        let c = timer.countdown
        return VStack(alignment: .leading, spacing: 6) {
            Text(formatCountdown(c.remaining(at: now)))
                .font(.system(size: 50, weight: .semibold).monospacedDigit())
                .foregroundStyle(c.phase == .finished ? Theme.timerOrange : .white)
                .contentTransition(.numericText(countsDown: true))
            Text(timerStatus(c))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                switch c.phase {
                case .running:
                    Button { timer.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(TimerButtonStyle(primary: true))
                case .paused:
                    Button { timer.start() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(TimerButtonStyle(primary: true))
                case .idle, .finished:
                    Button { timer.start() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(TimerButtonStyle(primary: true))
                }
                if c.isActive || c.phase == .finished {
                    Button("Reset") { timer.reset() }.buttonStyle(TimerButtonStyle(primary: false))
                }
                Button("+1 min") { timer.addMinute() }.buttonStyle(TimerButtonStyle(primary: false))
            }
            .padding(.top, 2)
        }
    }

    private func presets(_ c: Countdown) -> some View {
        let columns = Array(repeating: GridItem(.fixed(58), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TimerStore.presets, id: \.self) { minutes in
                let selected = !c.isActive && Int(c.duration) == minutes * 60
                Button("\(minutes)m") { timer.choose(minutes: minutes) }
                    .buttonStyle(PresetButtonStyle(selected: selected))
                    .disabled(c.isActive)
                    .opacity(c.isActive ? 0.35 : 1)
            }
        }
        .frame(width: 58 * 3 + 16)
    }

    private func timerStatus(_ c: Countdown) -> String {
        switch c.phase {
        case .idle: return "Pick a length, then Start"
        case .running:
            let end = Date().addingTimeInterval(c.remaining(at: Date()))
            return "Ends at \(end.formatted(date: .omitted, time: .shortened))"
        case .paused: return "Paused"
        case .finished: return "Done"
        }
    }

    // MARK: Pomodoro

    private func pomodoroLeft(now: Date) -> some View {
        let p = timer.pomodoro
        let color = p.phase.isBreak ? Theme.breakGreen : Theme.focusRed
        return VStack(alignment: .leading, spacing: 4) {
            Text(p.phase == .focus ? "Focus · \(p.sessionNumber) of \(p.plan.sessions)" : p.phase.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
            Text(formatCountdown(p.countdown.remaining(at: now)))
                .font(.system(size: 46, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
            SessionDots(total: p.plan.sessions, done: p.completedFocus, current: p.phase == .focus)
            HStack(spacing: 8) {
                if p.countdown.isRunning {
                    Button { timer.pausePomodoro() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(TimerButtonStyle(primary: true, color: color))
                } else {
                    Button { timer.startPomodoro() } label: {
                        Label(p.countdown.isActive ? "Resume" : "Start", systemImage: "play.fill")
                    }
                    .buttonStyle(TimerButtonStyle(primary: true, color: color))
                }
                Button("Skip") { timer.skipPomodoro() }.buttonStyle(TimerButtonStyle(primary: false))
                Button("Reset") { timer.resetPomodoro() }.buttonStyle(TimerButtonStyle(primary: false))
            }
            .padding(.top, 4)
        }
    }

    private var nextUp: some View {
        let p = timer.pomodoro
        let next = p.nextPhase
        let minutes = Int(p.plan.length(of: next) / 60)
        let label = next == .focus ? "Focus · \(min(p.completedFocus + 1, p.plan.sessions)) of \(p.plan.sessions)"
                                   : "\(next.title) · \(minutes) min"
        return VStack(alignment: .trailing, spacing: 2) {
            Text("Next").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondaryText)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 58 * 3 + 16, alignment: .trailing)
    }
}

/// Timer / Pomodoro switch.
struct ModeSwitch: View {
    @Binding var mode: TimerStore.Mode

    var body: some View {
        HStack(spacing: 2) {
            option("Timer", .timer)
            option("Pomodoro", .pomodoro)
        }
        .padding(2)
        .background(Capsule().fill(Color(white: 0.12)))
    }

    private func option(_ title: String, _ value: TimerStore.Mode) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(mode == value ? Color.white : Theme.secondaryText)
            .padding(.horizontal, 11)
            .frame(height: 22)
            .background(Capsule().fill(mode == value ? Color(white: 0.24) : .clear))
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Theme.quick) { mode = value } }
    }
}

/// One dot per focus session in the cycle: done, current, still to come.
struct SessionDots: View {
    var total: Int
    var done: Int
    var current: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < done ? Theme.focusRed : (i == done && current ? Color.white : Color(white: 0.22)))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

struct TimerButtonStyle: ButtonStyle {
    var primary: Bool
    var color: Color = Theme.timerOrange
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(primary ? color : Color(white: 0.2)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct PresetButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: 58, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.timerOrange : Color(white: 0.16)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The live countdown (timer or pomodoro) shown beside the notch or in the pill.
struct CountdownLabel: View {
    @ObservedObject var timer: TimerStore
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !timer.liveIsRunning)) { context in
            Text(formatCountdown(timer.liveRemaining(at: context.date)))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(timer.liveIsRunning ? (timer.live?.color ?? Theme.timerOrange) : Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Stay awake

/// The coffee cup beside the page dots. Click: stay awake for the default length (or turn off).
/// Right-click or hold: pick a length.
struct AwakeCup: View {
    @ObservedObject var awake: AwakeStore
    var showMenu: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            HStack(spacing: 4) {
                Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 10.5, weight: .semibold))
                if let left = awake.remaining(at: context.date) {
                    Text(formatAwakeRemaining(left))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(awake.isOn ? Theme.awakeOrange : Theme.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(awake.isOn ? Theme.awakeOrange.opacity(0.18) : Color(white: 0.13)))
            .contentShape(Capsule())
            .overlay { if RightClickCatcher.enabled { RightClickCatcher(action: showMenu) } }
            .onTapGesture { withAnimation(Theme.quick) { awake.toggle() } }
            .onLongPressGesture(minimumDuration: 0.35) { showMenu() }
            .help(awake.isOn ? "Staying awake. Click to turn off, right-click for lengths" : "Keep your Mac awake. Right-click for lengths")
            .animation(Theme.quick, value: awake.isOn)
        }
    }
}

/// "Keep awake for…" menu, drawn inside the island.
struct AwakeMenu: View {
    @ObservedObject var awake: AwakeStore
    var close: () -> Void
    @AppStorage(Pref.awakeDefaultMinutes) private var defaultMinutes = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KEEP AWAKE FOR")
                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8).padding(.top, 3).padding(.bottom, 3)
            ForEach(AwakeStore.lengths, id: \.self) { minutes in
                item(minutes == 0 ? "Until I turn it off" : describeAwakeLength(minutes: minutes)
                        .replacingOccurrences(of: " min", with: " minutes").replacingOccurrences(of: " h", with: minutes == 60 ? " hour" : " hours"),
                     checked: minutes == defaultMinutes) {
                    awake.start(minutes: minutes)
                    close()
                }
            }
            if awake.isOn {
                Rectangle().fill(Color(white: 0.22)).frame(height: 0.5).padding(.vertical, 3).padding(.horizontal, 6)
                item("Turn off", checked: false, dim: true) {
                    awake.stop()
                    close()
                }
            }
        }
        .padding(4)
        .frame(width: 158)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color(white: 0.2), lineWidth: 0.5))
    }

    private func item(_ title: String, checked: Bool, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 11.5)).foregroundStyle(dim ? Theme.secondaryText : .white)
                Spacer()
                if checked { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white) }
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)))
    }
}

/// Catches right-clicks on a SwiftUI view (and lets every other click pass through).
struct RightClickCatcher: NSViewRepresentable {
    var action: () -> Void
    /// The snapshot tool can't draw AppKit views, so it turns this off.
    static var enabled = true

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) { view.action = action }

    final class RightClickView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
    }
}
