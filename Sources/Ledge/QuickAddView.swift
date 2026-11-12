import AppKit
import LedgeCore
import SwiftUI

/// The Calendar page's quick add: one line to type into, a live preview of what Ledge understood,
/// and a short confirmation after saving. In Events mode it makes a Calendar event
/// ("Dentist tomorrow 3pm"); in To-dos mode a reminder ("! Reply to the review fri #s3 [30m]").
/// Return saves, ⌘N switches to the notes view and back, Esc steps back or cancels
/// (those keys arrive from the island controller).
struct QuickAddView: View {
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var model: IslandModel
    var kind: CalendarMode = .events
    @ObservedObject var todos: RemindersStore = .shared

    @State private var text = ""
    @State private var notes = ""
    /// Typing has paused for a moment. Only then does "no date found" show, not mid-word.
    @State private var settled = false
    @State private var settleTask: Task<Void, Never>?
    @State private var saved: Saved?
    @State private var error: String?
    /// The pointer is on the "Added" confirmation: it stays until you move away (to reach its buttons).
    @State private var overConfirmation = false
    @FocusState private var focus: Field?
    /// Esc hid the list suggestions; they come back with the next change to the line.
    @State private var listsHidden = false
    /// The window this copy of quick add is in. The pill on another screen has a hidden twin window
    /// (for full-screen desktops) showing the same quick add; only the copy in the window you're
    /// typing in (the key window) reacts to keys, so the one you see is the one that saves.
    @State private var window = WindowBox()

    private enum Field { case title, notes }

    private var placeholder: String { kind == .todos ? "Reply to the review fri #project [30m]" : "Dentist tomorrow 3pm" }

    /// The notes view is showing. Lives in the model, so ⌘N (handled by the island) shows it too.
    private var showsNotes: Bool { model.quickAddShowsNotes }

    /// What was just saved, kept for the confirmation and Undo.
    enum Saved: Equatable {
        case event(AddedEvent)
        case todo(AddedTodo)

        var date: Date {
            switch self {
            case .event(let e): return e.draft.start
            case .todo(let t): return t.draft.hasDue ? t.draft.event.start : Date()
            }
        }
    }

    var body: some View {
        let todo = kind == .todos ? TodoInput.parse(text) : nil
        let draft = todo?.event ?? QuickEventParser.parse(text)
        let hasText = !text.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(alignment: .top, spacing: 18) {
            DateBadge(date: saved?.date ?? draft.start)
                .background { if RightClickCatcher.enabled { WindowReader(box: window) } }
                // Dimmed on today until a date is read (or typing pauses with none).
                .opacity(saved == nil && !draft.foundDate && !settled ? 0.38 : 1)
                .animation(.easeOut(duration: 0.18), value: saved?.date ?? draft.start)
                .animation(.easeOut(duration: 0.18), value: draft.foundDate || settled)
            ZStack(alignment: .topLeading) {
                if let saved {
                    confirmation(saved).transition(IslandAnimation.swap)
                } else if showsNotes {
                    notesView(draft, todo: todo).transition(IslandAnimation.swap)
                } else {
                    editor(draft, todo: todo, hasText: hasText).transition(IslandAnimation.swap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: showsNotes)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .onAppear {
            // Bring back what you were typing if it closed by accident.
            let kept = model.draft(for: kind)
            if !kept.text.isEmpty || !kept.notes.isEmpty {
                text = kept.text
                notes = kept.notes
            }
            // The panel has just taken keyboard focus: put the cursor in the line right away
            // (and once more a moment later, in case the window wasn't ready yet).
            focusLine(.title)
        }
        .onChange(of: text) { _, _ in
            model.keepDraft(QuickAddDraft(text: text, notes: notes), for: kind)
            listsHidden = false
            error = nil
            settled = false
            settleTask?.cancel()
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { settled = true }
            }
        }
        // Keys handled by the island controller arrive here, on the live view.
        .onReceive(model.quickAddKeys) { key in handle(key) }
        .onChange(of: model.quickAddShowsNotes) { _, open in focusLine(open ? .notes : .title) }
        // The text boxes come back once the island has settled: put the cursor back in.
        .onChange(of: model.isSettled) { _, settled in
            if settled && saved == nil { focusLine(showsNotes ? .notes : .title) }
        }
        .onChange(of: notes) { old, new in
            // "[] " becomes a checkbox; return on a checkbox line starts the next one.
            if let fixed = Checklist.autoFormat(old: old, new: new) { notes = fixed; return }
            model.keepDraft(QuickAddDraft(text: text, notes: notes), for: kind)
        }
        // The island routes Tab and Esc here only while lists are suggested.
        .onChange(of: suggestedLists.isEmpty, initial: true) { _, none in model.quickAddSuggestsLists = !none }
        .onDisappear {
            settleTask?.cancel()
            model.quickAddSuggestsLists = false
        }
    }

    // MARK: Typing

    private func editor(_ draft: QuickEventDraft, todo: TodoDraft?, hasText: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if model.isSettled {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color(white: 0.42)))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .focused($focus, equals: .title)
                        .onSubmit(save)
                } else {
                    // While the island is still moving: plain text (see `IslandModel.isSettled`).
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? Color(white: 0.42) : .white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
                .font(.system(size: 14))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.09)))

            if let todo {
                todoPreview(todo, hasText: hasText)
            } else {
                preview(draft, hasText: hasText)
            }

            hints(draft, hasText: hasText)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The event as it will look in the list: color bar, title, and the day and time understood.
    private func preview(_ draft: QuickEventDraft, hasText: Bool) -> some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(hasText ? calendar.quickAddColor : Color(white: 0.22))
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.title.isEmpty ? "New event" : draft.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(draft.title.isEmpty ? Theme.secondaryText : .white)
                timeLine(draft, hasText: hasText)
                    .font(.system(size: 11).monospacedDigit())
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
        }
        .padding(.leading, 2)
        .animation(.easeOut(duration: 0.18), value: draft)
    }

    private func timeLine(_ draft: QuickEventDraft, hasText: Bool) -> Text {
        if let error {
            return Text(error).foregroundStyle(Theme.calendarRed)
        }
        if draft.foundDate {
            return Text(Self.describe(draft)).foregroundStyle(Theme.secondaryText)
        }
        if hasText && settled {
            // Return still saves: as an all-day event today. Say so before it happens.
            return Text("All day today").foregroundStyle(Theme.secondaryText)
                + Text(" · No date found, add one to change it").foregroundStyle(Theme.timerOrange)
        }
        return Text("Add a day or time, like “tomorrow 3pm” or “fri 7–8pm”").foregroundStyle(Theme.secondaryText)
    }

    /// The to-do as it will look in the list: circle, "!" for a must, list and due date, time guess.
    private func todoPreview(_ todo: TodoDraft, hasText: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .stroke(Color.white.opacity(hasText ? 0.45 : 0.22), lineWidth: 1.5)
                .frame(width: 15, height: 15)
                .padding(3)
            VStack(alignment: .leading, spacing: 1) {
                ((todo.isMust ? Text("! ").foregroundStyle(Theme.calendarRed).fontWeight(.bold) : Text(""))
                    + Text(todo.title.isEmpty ? "New to-do" : todo.title)
                        .foregroundStyle(todo.title.isEmpty ? Theme.secondaryText : Color.white))
                    .font(.system(size: 12.5, weight: .semibold))
                Group {
                    let lists = suggestedLists
                    if lists.isEmpty {
                        todoLine(todo, hasText: hasText).contentTransition(.opacity)
                    } else {
                        listSuggestions(lists)
                    }
                }
                    .font(.system(size: 11).monospacedDigit())
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if let minutes = todo.minutes {
                Text(TodoTitle.format(minutes: minutes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.leading, -1)
        .animation(.easeOut(duration: 0.18), value: todo)
    }

    private func todoLine(_ todo: TodoDraft, hasText: Bool) -> Text {
        if let error { return Text(error).foregroundStyle(Theme.calendarRed) }
        guard hasText else {
            return Text("! must · fri or 3pm due · #list · [30m] time guess").foregroundStyle(Theme.secondaryText)
        }
        let list = todos.listFor(tag: todo.listTag)
        // A "#tag" that matches none of your lists makes a new list: say so, so it's never a surprise.
        if list.isNew {
            return Text("New list “\(list.title)”").foregroundStyle(Theme.timerOrange)
                + Text(" · " + Self.todoDetails(todo)).foregroundStyle(Theme.secondaryText)
        }
        return Text(Self.todoSummary(todo, list: list)).foregroundStyle(Theme.secondaryText)
    }

    // MARK: List suggestions

    /// Your Reminders lists that match the "#list" at the end of the to-do line, best first.
    /// Empty when there's no "#list" being typed, nothing matches, or Esc hid them.
    private var suggestedLists: [String] {
        guard kind == .todos, !showsNotes, saved == nil, !listsHidden,
              let tag = ListSuggest.activeTag(in: text) else { return [] }
        return ListSuggest.matches(tag, in: todos.listTitles)
    }

    /// Up to 4 lists with their color dots. Tab takes the first one; a click takes any.
    private func listSuggestions(_ lists: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(lists.enumerated()), id: \.element) { index, title in
                Button { takeList(title) } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(todos.listColors[title] ?? Theme.secondaryText)
                            .frame(width: 6, height: 6)
                        Text(title)
                            .foregroundStyle(index == 0 ? Color.white : Theme.secondaryText)
                        if index == 0 { KeyCap("tab").foregroundStyle(Theme.secondaryText) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 13)
        .lineLimit(1)
    }

    /// Puts the list's tag in place of the "#list" being typed, then the cursor back at the end.
    private func takeList(_ title: String) {
        text = ListSuggest.complete(text, with: title)
        focusLine(.title)
    }

    private func hints(_ draft: QuickEventDraft, hasText: Bool) -> some View {
        HStack(spacing: 6) {
            if hasText {
                Button(action: openNotes) {
                    HStack(spacing: 6) { KeyCap("⌘N"); Text(notes.isEmpty ? "Notes" : "Edit notes") }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                Button(action: save) {
                    HStack(spacing: 6) {
                        KeyCap("return")
                        Text(kind == .todos || draft.foundDate ? "Add" : "Add all-day")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            KeyCap("esc")
            Text("Cancel")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.secondaryText)
        .frame(height: 26, alignment: .bottom)
    }

    /// ⌘N: the whole right side becomes a notes box, with the event or to-do in one line above it.
    /// Return makes a new line here ("[] " makes a checkbox); ⌘return saves; ⌘N or Esc goes back.
    private func notesView(_ draft: QuickEventDraft, todo: TodoDraft?) -> some View {
        let title = (todo?.title ?? draft.title).isEmpty ? (todo == nil ? "New event" : "New to-do") : (todo?.title ?? draft.title)
        let detail = todo.map { Self.todoSummary($0, list: todos.listFor(tag: $0.listTag)) }
            ?? (draft.foundDate ? Self.describe(draft) : "All day today")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if todo == nil {
                    Capsule().fill(calendar.quickAddColor).frame(width: 3, height: 13)
                } else {
                    Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5).frame(width: 11, height: 11)
                }
                (Text(title).foregroundStyle(.white).fontWeight(.semibold)
                    + Text("  " + detail).foregroundStyle(Theme.secondaryText))
                    .font(.system(size: 11.5).monospacedDigit())
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button(action: closeNotes) {
                        HStack(spacing: 6) { KeyCap("⌘N"); Text("Back") }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    Button(action: save) {
                        HStack(spacing: 6) { KeyCap("⌘↩"); Text("Add") }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            }
            .padding(.leading, 2)
            ZStack(alignment: .topLeading) {
                if model.isSettled {
                    TextEditor(text: $notes)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($focus, equals: .notes)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                } else {
                    // While the island is still moving: plain text (see `IslandModel.isSettled`).
                    Text(notes)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if notes.isEmpty {
                    Text("Notes · type [] for a checkbox")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(white: 0.42))
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            // No box: the notes sit right on the island's black, with just the blinking cursor.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handle(_ key: QuickAddKey) {
        guard saved == nil, window.isKey else { return }
        switch key {
        case .save:
            LedgeLog.shared.write("quick add: ⌘↩ save")
            save()
        case .typeAhead:
            // The island already added the characters to the draft; show them and put the cursor there.
            let kept = model.draft(for: kind)
            if showsNotes { notes = kept.notes } else { text = kept.text }
            focusLine(showsNotes ? .notes : .title)
        case .acceptListSuggestion:
            if let first = suggestedLists.first { takeList(first) }
        case .hideListSuggestions:
            listsHidden = true
        case .toggleNotes, .back:
            break // handled by the model (`quickAddShowsNotes`)
        }
    }

    private func closeNotes() { model.quickAddShowsNotes = false }

    private func openNotes() { model.quickAddShowsNotes = true }

    /// Puts the cursor in a line, at the end of what's there. (macOS selects all the text when a
    /// field gets focus, and the next key would replace it.)
    private func focusLine(_ field: Field) {
        focus = field
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            if focus != field { focus = field }
            try? await Task.sleep(for: .milliseconds(30))
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    // MARK: Saving

    private func save() {
        // With Japanese (or any) input in progress, return confirms the conversion; it never saves.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            LedgeLog.shared.write("quick add: return while converting text, not saving")
            return
        }
        // The pill on another screen has a hidden twin window (for full-screen desktops) showing this
        // same quick add; both hear ⌘↩. Only the first one saves.
        guard !model.quickAddIsConfirming else {
            LedgeLog.shared.write("quick add: save skipped (another copy of this view already saved)")
            return
        }
        // What you typed, from the shared draft (kept up to date by the copy you're typing in), so
        // whichever copy saves, it saves exactly that.
        let kept = model.draft(for: kind)
        let line = kept.text.isEmpty ? text : kept.text
        let body = kept.text.isEmpty ? notes : kept.notes
        guard saved == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            LedgeLog.shared.write("quick add: save skipped (\(saved == nil ? "empty line" : "already saved"))")
            return
        }
        // Parsed again at the moment of saving, so "today" and "now" are current.
        let result: Result<Saved, QuickAddError>
        switch kind {
        case .events:
            var draft = QuickEventParser.parse(line)
            if draft.title.isEmpty { draft.title = "New event" }
            result = calendar.add(draft, notes: body).map { Saved.event($0) }
        case .todos:
            result = todos.add(TodoInput.parse(line), notes: body).map { Saved.todo($0) }
        }
        switch result {
        case .success(let done):
            model.keepDraft(QuickAddDraft(), for: kind)
            model.quickAddIsConfirming = true
            withAnimation(.easeOut(duration: 0.18)) { saved = done }
            // A short confirmation, then back to the list (the new item stays highlighted there).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                // Held open while the pointer is on it, so Undo or Open in… can be clicked.
                while overConfirmation && saved == done { try? await Task.sleep(for: .milliseconds(200)) }
                guard saved == done else { return }
                model.endQuickAdd()
            }
        case .failure(let failure):
            error = failure.message
            if showsNotes { closeNotes() }
        }
    }

    private func undo() {
        guard let saved else { return }
        switch saved {
        case .event(let e): calendar.undo(e)
        case .todo(let t): todos.undo(t)
        }
        self.saved = nil
        model.endQuickAdd()
    }

    private func confirmation(_ saved: Saved) -> some View {
        let heading: String
        let detail: String
        switch saved {
        case .event(let e):
            heading = "Added to Calendar"
            detail = "\(e.draft.title) · \(Self.describe(e.draft))"
        case .todo(let t):
            heading = "Added to \(t.listTitle)"
            detail = "\(t.title) · " + (t.draft.hasDue ? TodoWords.due(t.draft.event.start, hasTime: t.draft.dueHasTime) : "No due date")
        }
        return HStack(spacing: 11) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: undo) {
                HStack(spacing: 6) { Text("Undo"); KeyCap("⌘Z") }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.secondaryText)
            // Open it in its app, e.g. to add a location or invitees.
            switch saved {
            case .event(let e) where !e.eventID.isEmpty:
                OpenInAppButton(color: Theme.calendarRed, help: "Open in Calendar") {
                    calendar.openInCalendar(e.eventID)
                    model.closeForHandOff()
                }
            case .todo(let t):
                OpenInAppButton(color: Theme.remindersBlue, help: "Open in Reminders") {
                    todos.openInReminders(t.id)
                    model.closeForHandOff()
                }
            default:
                EmptyView()
            }
        }
        .onHover { overConfirmation = $0 }
        .frame(maxHeight: .infinity)
    }

    // MARK: Words

    /// "Tomorrow, 3:00 PM – 4:00 PM", "Friday · All day", "Thu, Nov 26, 9:00 AM – 10:00 AM".
    static func describe(_ draft: QuickEventDraft, now: Date = Date()) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDate(draft.start, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(draft.start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else if let ahead = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: draft.start)).day,
                  (2..<7).contains(ahead) {
            day = draft.start.formatted(.dateTime.weekday(.wide))
        } else {
            day = draft.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        let short = { (d: Date) in d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        // Repeating: "Every Mon, Wed, Fri · 5:00 PM – 7:00 PM · from Fri, Nov 13 · until Dec 31, 2029".
        if let rule = draft.repeatRule {
            var parts = [rule.summary()]
            parts.append(draft.isAllDay ? "All day" : "\(time(draft.start)) – \(time(draft.end))")
            parts.append("from " + (cal.isDate(draft.start, inSameDayAs: now) ? "today" : short(draft.start)))
            if let until = rule.until { parts.append("until " + until.formatted(.dateTime.month(.abbreviated).day().year())) }
            return parts.joined(separator: " · ")
        }
        if draft.isAllDay {
            // Several days: "Wed, Jan 20 – Mon, Jan 25 · All day" (the end is the day after the last).
            let last = cal.date(byAdding: .day, value: -1, to: draft.end) ?? draft.end
            if !cal.isDate(last, inSameDayAs: draft.start), last > draft.start {
                return "\(short(draft.start)) – \(short(last)) · All day"
            }
            return "\(day) · All day"
        }
        if !cal.isDate(draft.end, inSameDayAs: draft.start),
           draft.end.timeIntervalSince(draft.start) > 24 * 3600 || cal.component(.hour, from: draft.end) > 6 {
            // Runs into another day: "Sun, Dec 20, 9:00 AM – Mon, Dec 21, 5:00 PM".
            return "\(short(draft.start)), \(time(draft.start)) – \(short(draft.end)), \(time(draft.end))"
        }
        return "\(day), \(time(draft.start)) – \(time(draft.end))"
    }

    /// "s3 data backup · Due Friday · Link", "Ledge (new list) · No due date".
    static func todoSummary(_ todo: TodoDraft, list: (title: String, isNew: Bool)) -> String {
        (list.isNew ? "\(list.title) (new list)" : list.title) + " · " + todoDetails(todo)
    }

    /// The due date (or "No due date"), "Alarm" with a time, and "Link" when there is one.
    static func todoDetails(_ todo: TodoDraft) -> String {
        var parts = [todo.hasDue ? TodoWords.due(todo.event.start, hasTime: todo.dueHasTime) : "No due date"]
        // "Every Fri · Due Fri 8:00 AM"
        if let rule = todo.event.repeatRule, todo.hasDue { parts.insert(rule.summary(), at: 0) }
        // A time of day means Reminders will ring then (on your Mac and iPhone).
        if todo.dueHasTime { parts.append("Alarm") }
        if todo.url != nil { parts.append("Link") }
        return parts.joined(separator: " · ")
    }
}

/// A small outlined key label, like "return" or "esc".
struct KeyCap: View {
    var label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10))
            .padding(.horizontal, 5)
            .frame(height: 15)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}

/// Holds the window a view is in (filled in by `WindowReader`).
final class WindowBox {
    weak var window: NSWindow?
    /// True when it's in the key window, or when the window isn't known yet.
    var isKey: Bool { window?.isKeyWindow ?? true }
}

/// An empty AppKit view that tells a `WindowBox` which window it's in.
struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.box = box
        return v
    }
    func updateNSView(_ view: ReaderView, context: Context) { view.box = box; box.window = view.window }

    final class ReaderView: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() { box?.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
