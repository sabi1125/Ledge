import AppKit
import LedgeCore
import SwiftUI

// MARK: - Events · To-dos switch

/// Sits in the top bar on the Calendar page (left of the notch). Remembers the last choice.
struct CalendarModeSwitch: View {
    @ObservedObject var model: IslandModel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            option("Events", .events)
            option("To-dos", .todos)
        }
        .padding(2)
        .background(Capsule().fill(Color(white: 0.12)))
    }

    private func option(_ title: String, _ value: CalendarMode) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.calendarMode == value ? Color.white : Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 18)
            .background {
                // One highlight that slides to the chosen side.
                if model.calendarMode == value {
                    Capsule().fill(Color(white: 0.24)).matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.calendarMode = value } }
    }
}

// MARK: - The list

/// To-dos mode: today's to-dos from Reminders. Click a circle to finish one, right-click it to mark
/// it in progress, click the row to open its steps.
struct TodoListPage: View {
    @ObservedObject var todos: RemindersStore
    @ObservedObject var model: IslandModel
    /// How far (pt) the list goes on below what's showing, for the "+N more" hint.
    @State private var hiddenBelow: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            DateBadge(date: Date())
            Group {
                switch todos.access {
                case .granted: content
                case .notAsked:
                    Message(title: "See your to-dos here",
                            detail: "Ledge reads and adds to-dos in the Reminders app.",
                            button: "Show my to-dos") { todos.requestAccess() }
                case .denied:
                    Message(title: "Reminders access is off",
                            detail: "Turn on Ledge in Privacy & Security → Reminders.",
                            button: "Open Settings") { todos.openPrivacySettings() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .onAppear { todos.refresh() }
    }

    @ViewBuilder private var content: some View {
        let items = todos.items
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing left to do")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(todos.doneToday > 0 ? "All done for today · \(todos.doneToday) finished" : "Your to-do list is clear.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Button { model.beginQuickAdd() } label: {
                    Label("Add to-do", systemImage: "plus")
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
            // Every to-do, scrollable. The ones you're working on show their next step under them.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(items) { item in
                            TodoRow(item: item, isNew: item.id == todos.justAddedID, todos: todos, model: model)
                                .id(item.id)
                            if item.isInProgress, !item.isDone, let step = item.nextStep {
                                HStack(spacing: 7) {
                                    TodoCircle(done: step.done, inProgress: false, size: 11) {
                                        todos.toggleStep(item.id, line: step.line)
                                    }
                                    NoteText.inline(step.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(white: 0.82))
                                        .lineLimit(1)
                                }
                                .padding(.leading, 22)
                                .padding(.top, -4)
                            }
                        }
                        footer()
                    }
                    .padding(.top, 3)
                    .padding(.bottom, 18) // room to scroll the last row clear of "+N more"
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                .onScrollGeometryChange(for: CGFloat.self) { g in
                    g.contentSize.height - g.containerSize.height - g.contentOffset.y
                } action: { _, below in
                    hiddenBelow = below
                }
                // No scroll bar: "+N more" says there's more, and two fingers scroll to it.
                .overlay(alignment: .bottomLeading) {
                    let more = Int((max(0, hiddenBelow - 18) / 36).rounded(.up))
                    if more > 0 {
                        Text("+\(more) more")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 26)
                            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                            .background(Color.black)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hiddenBelow > 18)
                .onChange(of: todos.justAddedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                // Back from quick add: the list comes back with the new to-do in view.
                .onChange(of: todos.items.contains { $0.id == todos.justAddedID }) { _, there in
                    guard there, let id = todos.justAddedID else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    guard let id = todos.justAddedID, items.contains(where: { $0.id == id }) else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder private func footer() -> some View {
        if todos.doneToday > 0 {
            Text("\(todos.doneToday) done today")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 26)
        }
    }
}

struct TodoRow: View {
    var item: TodoItem
    var isNew: Bool
    @ObservedObject var todos: RemindersStore
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 8) {
            TodoCircle(done: item.isDone, inProgress: item.isInProgress) {
                todos.toggleDone(item.id)
            } secondary: {
                todos.toggleInProgress(item.id)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    TodoText.title(item).font(.system(size: 12.5, weight: .semibold))
                    TodoText.meta(item).font(.system(size: 11).monospacedDigit())
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                trailing
            }
            .contentShape(Rectangle())
            .onTapGesture { model.openTodo(item.id) }
        }
        // A soft light behind a just-added to-do that fades away.
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(isNew ? 0.08 : 0)))
        .padding(.horizontal, -8)
        .padding(.vertical, -2)
        .animation(.easeOut(duration: 0.6), value: isNew)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if item.isDone {
                Button("Undo") { todos.toggleDone(item.id) }
                    .buttonStyle(.plain)
            } else {
                let progress = Checklist.progress(in: item.notes)
                if progress.total > 0 { Text("\(progress.done)/\(progress.total)") }
                if let url = item.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Open link")
                }
                if let minutes = item.minutes { Text(TodoTitle.format(minutes: minutes)) }
                if isNew && item.minutes == nil { Text("Just added") }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.secondaryText)
    }
}

/// Title and grey line of a to-do, shared by the list and the opened to-do.
enum TodoText {
    static func title(_ item: TodoItem) -> Text {
        let base = Text(item.title)
            .foregroundStyle(item.isDone ? Theme.secondaryText : Color.white)
            .strikethrough(item.isDone)
        guard item.isMust && !item.isDone else { return base }
        return Text("! ").foregroundStyle(Theme.calendarRed).fontWeight(.bold) + base
    }

    static func meta(_ item: TodoItem) -> Text {
        if item.isDone { return Text("Done").foregroundStyle(Theme.green) }
        var parts: [String] = []
        if !item.listTitle.isEmpty { parts.append(item.listTitle) }
        if let due = item.due { parts.append(TodoWords.due(due, hasTime: item.dueHasTime)) }
        if let since = TodoWords.since(item.created) { parts.append(since) }
        let rest = Text(parts.joined(separator: " · ")).foregroundStyle(Theme.secondaryText)
        guard item.isInProgress else { return rest }
        return Text("In progress").foregroundStyle(Theme.timerOrange)
            + Text(parts.isEmpty ? "" : " · ").foregroundStyle(Theme.secondaryText)
            + rest
    }
}

/// The round check: empty (to do), half orange (in progress), green with a tick (done).
struct TodoCircle: View {
    var done: Bool
    var inProgress: Bool
    var size: CGFloat = 15
    var action: () -> Void
    /// Right-click (in progress on and off).
    var secondary: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            ZStack {
                if done {
                    Circle().fill(Theme.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .heavy))
                        .foregroundStyle(.black)
                } else if inProgress {
                    Circle().stroke(Theme.timerOrange, lineWidth: 1.5)
                    HalfCircle().fill(Theme.timerOrange).padding(size * 0.22)
                } else {
                    Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                }
            }
            .frame(width: size, height: size)
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if let secondary, RightClickCatcher.enabled { RightClickCatcher(action: secondary) }
        }
        .help(done ? "Done. Click to undo" : (secondary == nil ? "Tick off" : "Click to finish, right-click to mark in progress"))
        .animation(.easeOut(duration: 0.18), value: done)
        .animation(.easeOut(duration: 0.18), value: inProgress)
    }
}

/// The right half of a circle, for "in progress".
struct HalfCircle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - An opened to-do

/// Click a to-do in the list: its steps ("- [ ] …" lines in its notes) with real checkboxes,
/// plus Start/Pause and the link. Esc or Back returns to the list.
struct TodoDetail: View {
    @ObservedObject var todos: RemindersStore
    @ObservedObject var model: IslandModel
    var id: String
    /// How far (pt) the note goes on below what's showing, for the "more…" hint.
    @State private var hiddenBelow: CGFloat = 0

    var body: some View {
        let item = todos.items.first { $0.id == id }
        HStack(alignment: .top, spacing: 18) {
            DateBadge(date: item?.due ?? Date())
            VStack(alignment: .leading, spacing: 8) {
                if let item {
                    header(item)
                    steps(item)
                } else {
                    Text("This to-do isn't in today's list any more.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func header(_ item: TodoItem) -> some View {
        HStack(spacing: 8) {
            TodoCircle(done: item.isDone, inProgress: item.isInProgress) {
                todos.toggleDone(item.id)
            } secondary: {
                todos.toggleInProgress(item.id)
            }
            VStack(alignment: .leading, spacing: 1) {
                TodoText.title(item).font(.system(size: 12.5, weight: .semibold))
                TodoText.meta(item).font(.system(size: 11).monospacedDigit())
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                if let url = item.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Open link")
                }
                if !item.isDone {
                    Button(item.isInProgress ? "Pause" : "Start") { todos.toggleInProgress(item.id) }
                        .buttonStyle(SmallPillStyle())
                }
                OpenInAppButton(color: Theme.remindersBlue, help: "Open in Reminders") {
                    todos.openInReminders(item.id)
                    model.closeForHandOff()
                }
                Button { model.closeTodo() } label: {
                    HStack(spacing: 5) { KeyCap("esc"); Text("Back") }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize()
        }
    }

    /// The whole note, in order: checkboxes you can tick, bullets, indents and links. Scrolls
    /// with two fingers (no scroll bar); "more…" shows while there's more below.
    @ViewBuilder private func steps(_ item: TodoItem) -> some View {
        let lines = Self.lines(of: item.notes)
        if lines.allSatisfy({ $0.kind == .blank }) {
            Text("No notes yet. Lines like “- [ ] step” become checkboxes here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 2)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(lines) { line in noteLine(line, item: item) }
                }
                .padding(.leading, 2)
                .padding(.bottom, 16) // room to scroll the last line clear of "more…"
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height - g.containerSize.height - g.contentOffset.y
            } action: { _, below in
                hiddenBelow = below
            }
            .overlay(alignment: .bottomLeading) {
                if hiddenBelow > 16 {
                    Text("more…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 2)
                        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                        .background(Color.black)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: hiddenBelow > 16)
        }
    }

    @ViewBuilder private func noteLine(_ line: NoteLine, item: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            switch line.kind {
            case .blank:
                Color.clear.frame(height: 2)
            case .check(let done):
                TodoCircle(done: done, inProgress: false, size: 12) {
                    todos.toggleStep(item.id, line: line.id)
                }
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 4 }
                NoteText.inline(line.text)
                    .font(.system(size: 12))
                    .foregroundStyle(done ? Theme.secondaryText : Color(white: 0.9))
                    .strikethrough(done)
            case .bullet:
                Text("•").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                NoteText.inline(line.text).font(.system(size: 12)).foregroundStyle(Color(white: 0.9))
            case .heading:
                NoteText.inline(line.text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            case .text:
                NoteText.inline(line.text).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, CGFloat(line.level) * 16)
    }

    /// One line of a note, read as Markdown.
    struct NoteLine: Identifiable {
        enum Kind: Equatable { case blank, check(done: Bool), bullet, heading, text }
        var id: Int        // the line number (checkboxes are ticked by it)
        var kind: Kind
        var text: String
        var level: Int     // indent: every 4 spaces (or a tab) is one level
    }

    static func lines(of notes: String) -> [NoteLine] {
        let checks = Dictionary(uniqueKeysWithValues: Checklist.items(in: notes).map { ($0.line, $0) })
        return notes.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let line = String(raw)
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let level = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
            let body = line.dropFirst(leading.count)
            if body.trimmingCharacters(in: .whitespaces).isEmpty {
                return NoteLine(id: index, kind: .blank, text: "", level: 0)
            }
            if let step = checks[index] {
                return NoteLine(id: index, kind: .check(done: step.done), text: step.text, level: level)
            }
            if body.hasPrefix("- ") || body.hasPrefix("* ") {
                return NoteLine(id: index, kind: .bullet, text: String(body.dropFirst(2)), level: level)
            }
            if body.hasPrefix("#") {
                return NoteLine(id: index, kind: .heading,
                                text: body.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), level: level)
            }
            return NoteLine(id: index, kind: .text, text: String(body), level: level)
        }
    }
}

/// One line of notes as inline Markdown: **bold**, `code`, and links shown by name.
enum NoteText {
    static func inline(_ line: String) -> Text {
        let md = NoteLinks.markdown(line)
        if let styled = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(styled)
        }
        return Text(line)
    }
}

struct SmallPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 18)
            .background(Capsule().fill(Color(white: configuration.isPressed ? 0.24 : 0.16)))
    }
}
