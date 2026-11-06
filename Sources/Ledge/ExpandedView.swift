import AppKit
import LedgeCore
import SwiftUI

/// The open island: a top bar beside the notch (page name and dots), then the current page.
/// Swipe with two fingers to move between pages.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var notes: NotesStore

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
            Spacer(minLength: model.notch.width + 12)
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
        .frame(height: model.notch.height)
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
