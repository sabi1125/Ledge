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
    @ObservedObject var todos: RemindersStore = .shared
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
            TopBar(model: model, awake: awake, canQuickAdd: canQuickAdd) {
                withAnimation(Theme.quick) { showAwakeMenu.toggle() }
            }
            // The page area is laid out at the size the island is heading to (not the in-between
            // size while it grows or shrinks), so nothing inside drifts or reflows: the shape just
            // reveals or covers it. The island grows around its middle, so a centered page is
            // already where it will end up. Only the top bar follows the moving edges.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    // The current page only (hidden pages don't run at all). Changing page: a
                    // crossfade in place. Each page has its own frame, so the one you're leaving
                    // keeps its size while it fades instead of being squeezed into the new one.
                    ZStack(alignment: .top) {
                        pageView(model.page)
                            .environment(\.isVisiblePage, true)
                            .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
                            .id(model.page)
                            .transition(IslandAnimation.page)
                    }
                    .animation(.smooth(duration: 0.3), value: model.page)
                }
                .clipped()
        }
    }

    /// The page area's final size: the open shape being shown, less the top bar.
    private var pageSize: CGSize {
        let full = IslandLayout.size(for: model.lastOpenShape, notch: model.notch, style: model.style)
        let bar = model.style == .notch ? model.notch.height : IslandLayout.floatingTopBar + 2
        return CGSize(width: full.width, height: max(0, full.height - bar))
    }

    /// The + shows on the Calendar page once Ledge can read that mode's app.
    private var canQuickAdd: Bool {
        guard model.page == .calendar, model.openTodoID == nil else { return false }
        return model.calendarMode == .events ? calendar.access == .granted : todos.access == .granted
    }

    @ViewBuilder private func pageView(_ page: IslandPage) -> some View {
        switch page {
        case .music: PlayerView(model: model)
        case .calendar: CalendarPage(calendar: calendar, model: model)
        case .timer: TimerPage(timer: timer)
        case .notes: NotesPage(notes: notes, model: model)
        }
    }
}

/// Sits beside the notch: page name on the left; quick add (+), the stay-awake cup and page
/// dots on the right. While quick add is open, only "New event" shows.
struct TopBar: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var awake: AwakeStore
    /// Shows the + (Calendar page, with calendar access).
    var canQuickAdd = false
    var showAwakeMenu: () -> Void

    var body: some View {
        let adding = model.isQuickAdding
        let focused = adding || model.openTodoID != nil
        // Every title stays in place and only fades (the animation is limited to opacity), so when
        // the page changes while the island resizes, nothing here lags behind the moving edges.
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                ForEach(model.pages, id: \.self) { p in
                    let shown = !focused && p == model.page
                    Group {
                        if p == .calendar {
                            CalendarModeSwitch(model: model)
                        } else {
                            titleLabel(p.title, symbol: p.symbol)
                        }
                    }
                    .animation(.easeOut(duration: 0.2)) { $0.opacity(shown ? 1 : 0) }
                    .allowsHitTesting(shown)
                }
                titleLabel(leftTitle, symbol: adding ? "plus" : "checklist")
                    .animation(.easeOut(duration: 0.2)) { $0.opacity(focused ? 1 : 0) }
                    .allowsHitTesting(false)
            }
            Spacer(minLength: model.style == .notch ? model.notch.width + 12 : 12)
            HStack(spacing: 0) {
                Button { model.beginQuickAdd() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color(white: 0.85))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color(white: 0.13)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.calendarMode == .todos ? "Add a to-do (⌘N or ⌘T)" : "Add an event (⌘N, or ⌃⌥E from anywhere)")
                .padding(.trailing, 8)
                .animation(.easeOut(duration: 0.2)) { $0.opacity(canQuickAdd ? 1 : 0) }
                .allowsHitTesting(canQuickAdd)
                AwakeCup(awake: awake, showMenu: showAwakeMenu)
                    .fixedSize()
                    .padding(.trailing, 8)
                dots
            }
            .animation(.easeOut(duration: 0.2)) { $0.opacity(focused ? 0 : 1) }
            .allowsHitTesting(!focused)
        }
        .padding(.horizontal, 20)
        .frame(height: model.style == .notch ? model.notch.height : IslandLayout.floatingTopBar)
        .padding(.top, model.style == .notch ? 0 : 2)
    }

    private func titleLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
    }

    private var leftTitle: String {
        if model.isQuickAdding { return model.quickAddKind == .todos ? "New to-do" : "New event" }
        if model.openTodoID != nil { return "To-do" }
        return model.page.title
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.pages.enumerated()), id: \.element) { number, p in
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .animation(.easeOut(duration: 0.2)) { $0.opacity(p == model.page ? 1 : 0.32) }
                    .padding(3)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.spring) { model.show(page: p) } }
                    .help("\(p.title) (⌘\(number + 1))")
            }
        }
    }
}

// MARK: - Calendar

struct CalendarPage: View {
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var model: IslandModel
    @ObservedObject var todos: RemindersStore = .shared

    var body: some View {
        // Quick add, an opened to-do, or the events or to-dos list. Content only fades in and out.
        ZStack(alignment: .topLeading) {
            if model.isQuickAdding {
                QuickAddView(calendar: calendar, model: model, kind: model.quickAddKind)
                    .transition(IslandAnimation.swap)
            } else if let id = model.openTodoID {
                TodoDetail(todos: todos, model: model, id: id)
                    .transition(IslandAnimation.swap)
            } else if model.calendarMode == .todos {
                TodoListPage(todos: todos, model: model)
                    .transition(IslandAnimation.swap)
            } else {
                list.transition(IslandAnimation.swap)
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.isQuickAdding)
        .animation(.easeOut(duration: 0.22), value: model.openTodoID)
        .animation(.easeOut(duration: 0.22), value: model.calendarMode)
    }

    private var list: some View {
        HStack(alignment: .top, spacing: 18) {
            DateBadge(date: Date())
            Group {
                switch calendar.access {
                case .granted:
                    EventList(events: calendar.events, justAddedID: calendar.justAddedID,
                              onOpen: { id in
                                  calendar.openInCalendar(id)
                                  model.closeForHandOff()
                              }) { model.beginQuickAdd() }
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

struct DateBadge: View {
    var date: Date

    var body: some View {
        VStack(alignment: .center, spacing: -2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.calendarRed)
                .contentTransition(.opacity)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 38, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.opacity)
            Text(date.formatted(.dateTime.month(.wide)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.opacity)
        }
        // Centered in its column, and in the page's height.
        .frame(width: 70)
        .frame(maxHeight: .infinity)
    }
}

private struct EventList: View {
    var events: [CalendarItem]
    /// The event quick add just saved: highlighted, and scrolled into view.
    var justAddedID: String?
    /// Click an event: open it in the Calendar app.
    var onOpen: (String) -> Void
    var onAdd: () -> Void
    /// How far (pt) the list goes on below what's showing, for the "+N more" hint.
    @State private var hiddenBelow: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let upcoming = events.filter { $0.end > context.date }
            if upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing coming up")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Your calendar is clear for today and tomorrow.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    Button(action: onAdd) {
                        Label("Add event", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(white: 0.8))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -7)
                    .padding(.top, 6)
                }
                .padding(.top, 6)
            } else {
                // Every event, scrollable with two fingers. No scroll bar: "+N more" says there's more.
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(upcoming) { event in
                                EventRow(event: event, now: context.date, isNew: event.id == justAddedID,
                                         onOpen: event.eventID.map { id in { onOpen(id) } })
                                    .id(event.id)
                            }
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 18) // room to scroll the last row clear of "+N more"
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: .infinity)
                    .onScrollGeometryChange(for: CGFloat.self) { g in
                        g.contentSize.height - g.containerSize.height - g.contentOffset.y
                    } action: { _, below in
                        hiddenBelow = below
                    }
                    .overlay(alignment: .bottomLeading) {
                        let more = Int((max(0, hiddenBelow - 18) / 36).rounded(.up))
                        if more > 0 {
                            Text("+\(more) more")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.leading, 12)
                                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                                .background(Color.black)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: hiddenBelow > 18)
                    .onChange(of: justAddedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    // Back from quick add: the list comes back with the new event in view.
                    .onChange(of: upcoming.contains { $0.id == justAddedID }) { _, there in
                        guard there, let id = justAddedID else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        guard let id = justAddedID, upcoming.contains(where: { $0.id == id }) else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct EventRow: View {
    var event: CalendarItem
    var now: Date
    var isNew = false
    /// Click the row: open the event in the Calendar app. (Join has its own button.)
    var onOpen: (() -> Void)?
    @State private var hovering = false

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
            } else if isNew {
                Text("Just added")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .transition(.opacity)
            }
        }
        // A soft light behind a just-added event that fades away, and a fainter one on hover
        // (the row opens the event in Calendar).
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(isNew ? 0.08 : (hovering && onOpen != nil ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture { onOpen?() }
        .help(onOpen == nil ? "" : "Open in Calendar")
        .padding(.horizontal, -8)
        .padding(.vertical, -2)
        .animation(.easeOut(duration: 0.6), value: isNew)
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

struct Message: View {
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
    @Environment(\.isVisiblePage) private var visible
    @FocusState private var focus: Field?
    /// Delete was clicked once; a second click within 3 seconds deletes.
    @State private var confirmingDelete = false
    @AppStorage(Pref.notesSidebar) private var showsList = true
    /// The note's text box (a macOS text view, so it sits outside `focus`) has the cursor.
    @State private var bodyFocused = false
    /// The cursor should go into the text box, as soon as it's on screen.
    @State private var wantsBodyFocus = false
    /// Each change takes the cursor out of the text box.
    @State private var bodyBlurRequest = 0

    private enum Field { case search, title }

    /// The cursor is somewhere on this page (search, title or the note), or about to be.
    private var isEditing: Bool { focus != nil || bodyFocused || wantsBodyFocus }

    @Environment(\.isTwinWindow) private var isTwinWindow
    /// A floating pill has two windows (the normal one and its full-screen twin), each with its own
    /// copy of this page. Only the copy on screen takes the cursor and starts or ends typing;
    /// otherwise the hidden copy takes the keyboard from the one you're looking at.
    private var inShowingWindow: Bool { isTwinWindow == model.twinIsShowing }

    var body: some View {
        Group {
            switch notes.status {
            case .notAllowed:
                Message(title: "Notes access is off",
                        detail: "Allow Ledge to control Notes in Privacy & Security → Automation.",
                        button: "Open Settings") { notes.openAutomationSettings() }
            case .failed(let why):
                Message(title: "Couldn't reach Notes", detail: why, button: "Try again") { notes.refresh() }
            case .loading, .ready:
                HStack(alignment: .top, spacing: 14) {
                    if showsList {
                        list.frame(width: 168).transition(.opacity)
                        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).transition(.opacity)
                    }
                    editor
                }
                .animation(.easeOut(duration: 0.18), value: showsList)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .onAppear { if visible { notes.refresh() } }
        .onChange(of: visible) { _, now in
            guard now else { return }
            notes.refresh()
            takeCursorIfAsked()
        }
        // Only while this page is the one showing: the pages sit side by side, and a hidden one
        // must never take the cursor or end typing that belongs to quick add.
        .disabled(!visible)
        .onChange(of: isEditing) { _, now in
            guard visible, inShowingWindow, !model.isQuickAdding else { return }
            // Ledge takes the keyboard while you type (so ⌘C/⌘V, Tab and Esc all work).
            if now {
                model.beginNotesTyping()
            } else {
                // A turn later: moving between the title and the note briefly has neither.
                DispatchQueue.main.async {
                    guard !isEditing, model.isTyping else { return }
                    LedgeLog.shared.write("notes: typing ends (nothing on the page has the cursor)")
                    model.isTyping = false
                }
            }
        }
        .onChange(of: model.isTyping) { _, now in
            guard !now else { return }
            focus = nil
            wantsBodyFocus = false
            bodyBlurRequest += 1
        }
        // ⌘L opened the island on Notes: the cursor goes into the note.
        // (`initial`: the page is usually built just after ⌘L asked, so there's no change to see.)
        .onChange(of: model.notesWantsCursor, initial: true) { _, _ in takeCursorIfAsked() }
        // ⌘N or the pencil: the cursor goes to the new note's title (all selected, so typing replaces it).
        .onChange(of: notes.newNoteCount) { _, _ in focus = .title }
        // "[] " becomes a checkbox; return on a list line starts the next one (Tab indents it).
        .onChange(of: notes.text) { old, new in
            if let fixed = Checklist.autoFormat(old: old, new: new) { notes.text = fixed }
        }
        .onDisappear { notes.saveNow() }
    }

    /// ⌘L or ⌘1–⌘4 asked for the cursor in the note: take it, once this page is the one showing.
    private func takeCursorIfAsked() {
        guard model.notesWantsCursor, visible, inShowingWindow else { return }
        model.notesWantsCursor = false
        wantsBodyFocus = true
    }

    // MARK: The list of notes (the "Ledge" folder in Notes)

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NOTES")
                    .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button { notes.newNote() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(white: 0.85))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.leading, 8)
            // Search titles and text.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                TextField("", text: $notes.query, prompt: Text("Search").foregroundStyle(Color(white: 0.42)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white)
                    .focused($focus, equals: .search)
                if !notes.query.isEmpty {
                    Button { notes.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(notes.visibleItems) { item in row(item) }
                    if notes.visibleItems.isEmpty && !notes.query.isEmpty {
                        Text("No matches")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 8).padding(.top, 4)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func row(_ item: NotesStore.Item) -> some View {
        let selected = item.id == notes.selectedID
        return Button { notes.select(item.id) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color(white: 0.85))
                Text(Self.when(item.modified))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "4:12 PM" today, "Nov 9" before.
    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: The open note: title, text, and "Open in Notes"

    @ViewBuilder private var editor: some View {
        if notes.status == .ready && notes.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No notes yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("They're kept in a “Ledge” folder in the Notes app.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Button("New note") { notes.newNote() }
                    .buttonStyle(AppLinkStyle(fill: Theme.notesYellow, text: .black))
                    .padding(.top, 6)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    Button { showsList.toggle() } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(showsList ? Color(white: 0.85) : Theme.secondaryText)
                            .frame(width: 20, height: 19)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsList ? "Hide the list (⌥⌘S)" : "Show the list (⌥⌘S)")
                    Group {
                        if model.isSettled {
                            TextField("", text: $notes.title, prompt: Text("Title").foregroundStyle(Color(white: 0.42)))
                                .textFieldStyle(.plain)
                                .foregroundStyle(.white)
                                .focused($focus, equals: .title)
                                .onSubmit {
                                    focus = nil
                                    wantsBodyFocus = true
                                }
                        } else {
                            // While the island is still moving: plain text (see `IslandModel.isSettled`).
                            Text(notes.title.isEmpty ? "Title" : notes.title)
                                .foregroundStyle(notes.title.isEmpty ? Color(white: 0.42) : .white)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    deleteButton
                    OpenInAppButton(color: Theme.notesYellow, help: "Open in Notes") {
                        notes.openInNotes()
                        model.closeForHandOff()
                    }
                }
                ZStack(alignment: .topLeading) {
                    if model.isSettled {
                        // Markdown is styled as you type: "## Plan" big, "**x**" bold, "---" a line.
                        MarkdownEditor(text: $notes.text, wantsFocus: wantsBodyFocus, blurRequest: bodyBlurRequest) { now in
                            bodyFocused = now
                            if now { wantsBodyFocus = false }
                        }
                    } else {
                        // While the island is still moving: drawn by SwiftUI (see `IslandModel.isSettled`).
                        MarkdownPreview(text: notes.text)
                    }
                    if notes.text.isEmpty {
                        Text("Jot something down… type [] for a checkbox")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(white: 0.42))
                            .allowsHitTesting(false)
                    }
                }
                // No box: the note sits right on the island's black, with just the blinking cursor.
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension NotesPage {
    /// Trash, then a red "Delete?" for 3 seconds; a second click deletes (to Recently Deleted).
    @ViewBuilder var deleteButton: some View {
        if confirmingDelete {
            Button {
                confirmingDelete = false
                notes.deleteSelected()
            } label: {
                Text("Delete?")
            }
            .buttonStyle(AppLinkStyle(fill: Theme.calendarRed, text: .white))
            .help("Click again to delete. It goes to Recently Deleted in Notes")
            .transition(.opacity)
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = false }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 20, height: 19)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this note")
        }
    }
}

/// A small square with an arrow, in the other app's color: opens the note or to-do there.
/// Quiet, but the color makes it easy to spot. The name shows on hover.
struct OpenInAppButton: View {
    var color: Color
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 20, height: 19)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.16)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A small, bright pill ("New note").
struct AppLinkStyle: ButtonStyle {
    var fill: Color
    var text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 19)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
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
    @Namespace private var pill

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
            .background {
                // One highlight that slides to the chosen side.
                if mode == value {
                    Capsule().fill(Color(white: 0.24)).matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { mode = value } }
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
