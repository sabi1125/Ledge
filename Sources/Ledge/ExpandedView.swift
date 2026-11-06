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

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
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

/// Sits beside the notch: page name on the left, page dots on the right.
struct TopBar: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            Label(model.page.title, systemImage: model.page.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .labelStyle(.titleAndIcon)
                .contentTransition(.opacity)
            Spacer(minLength: model.style == .notch ? model.notch.width + 12 : 12)
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
        // Ticks only while it's on screen and counting down.
        TimelineView(.animation(minimumInterval: 0.5, paused: !(visible && timer.countdown.isRunning))) { context in
            let c = timer.countdown
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(formatCountdown(c.remaining(at: context.date)))
                        .font(.system(size: 40, weight: .semibold).monospacedDigit())
                        .foregroundStyle(c.phase == .finished ? Theme.timerOrange : .white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Theme.quick, value: Int(c.remaining(at: context.date)))
                    Text(status(c, now: context.date))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    HStack(spacing: 8) {
                        primaryButton(c)
                        if c.isActive || c.phase == .finished {
                            Button("Reset") { timer.reset() }.buttonStyle(TimerButtonStyle(primary: false))
                        }
                        Button("+1 min") { timer.addMinute() }.buttonStyle(TimerButtonStyle(primary: false))
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
                presets(c)
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder private func primaryButton(_ c: Countdown) -> some View {
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
    }

    private func presets(_ c: Countdown) -> some View {
        let columns = Array(repeating: GridItem(.fixed(44), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(TimerStore.presets, id: \.self) { minutes in
                let selected = !c.isActive && Int(c.duration) == minutes * 60
                Button("\(minutes)m") { timer.choose(minutes: minutes) }
                    .buttonStyle(PresetButtonStyle(selected: selected))
                    .disabled(c.isActive)
                    .opacity(c.isActive ? 0.35 : 1)
            }
        }
        .frame(width: 44 * 3 + 12)
    }

    private func status(_ c: Countdown, now: Date) -> String {
        switch c.phase {
        case .idle: return "Pick a length, then Start"
        case .running:
            let end = Date().addingTimeInterval(c.remaining(at: Date()))
            return "Ends at \(end.formatted(date: .omitted, time: .shortened))"
        case .paused: return "Paused"
        case .finished: return "Done"
        }
    }
}

struct TimerButtonStyle: ButtonStyle {
    var primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(primary ? Theme.timerOrange : Color(white: 0.2)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

struct PresetButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: 44, height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.timerOrange : Color(white: 0.16)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The live countdown shown beside the notch or in the pill.
struct CountdownLabel: View {
    @ObservedObject var timer: TimerStore
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !timer.countdown.isRunning)) { context in
            Text(formatCountdown(timer.countdown.remaining(at: context.date)))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(timer.countdown.isRunning ? Theme.timerOrange : Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
