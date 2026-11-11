import AppKit
import LedgeCore

/// The Notes page's notes, kept in Apple Notes (in a folder called "Ledge"), so they're the same
/// notes as in the Notes app and on your iPhone. Edits save to Notes a moment after you stop typing.
@MainActor
final class NotesStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var modified: Date
    }

    enum Status: Equatable {
        case loading, ready
        /// "Ledge wants to control Notes" was turned down.
        case notAllowed
        case failed(String)
    }

    @Published private(set) var items: [Item] = []
    /// What's typed in the search field. Titles filter right away; matching text is found in
    /// Notes a moment after you stop typing.
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    /// Notes whose text matches the search (from Notes), nil when there's no search.
    @Published private(set) var textMatches: Set<String>?
    private var searchWork: DispatchWorkItem?

    /// The list as shown: everything, or what matches the search.
    var visibleItems: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) || textMatches?.contains($0.id) == true }
    }
    @Published private(set) var status: Status = .loading
    @Published private(set) var selectedID: String?
    /// Goes up each time a new note is made, so the page can put the cursor in its title.
    @Published private(set) var newNoteCount = 0
    /// The open note's title (its first line in Notes) and the rest of its text.
    @Published var title = "" { didSet { if !isLoading && title != oldValue { scheduleSave() } } }
    @Published var text = "" { didSet { if !isLoading && text != oldValue { scheduleSave() } } }

    private var isLoading = false
    /// The text of notes already read from Notes, so opening one shows it at once (no blank flash
    /// while Notes answers).
    private var cache: [String: (title: String, text: String)] = [:]
    /// A list reload is on its way (so opening the page doesn't ask Notes twice).
    private var refreshing = false
    private let isSample: Bool
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    private static let lastNoteKey = "notesLastNoteID"
    private static let migratedKey = "notesMovedToAppleNotes"

    /// `sample` is for snapshots: shows that text and never touches Notes.
    init(sample: String? = nil) {
        isSample = sample != nil
        if let sample {
            isLoading = true
            if !sample.isEmpty {
                items = [Item(id: "sample", title: "Ideas", modified: Date())]
                selectedID = "sample"
                title = "Ideas"
                text = sample
            }
            isLoading = false
            status = .ready
        }
    }

    // MARK: Reading

    /// Reloads the list from Notes (when the Notes page shows).
    func refresh() {
        guard !isSample, !refreshing else { return }
        refreshing = true
        AppleScriptBridge.run(AppleScripts.listNotes) { result in
            DispatchQueue.main.async { [weak self] in
                self?.refreshing = false
                self?.applyList(result)
            }
        }
    }

    private func applyList(_ result: Result<String, AppleScriptBridge.Failure>) {
        switch result {
        case .failure(let f):
            status = f.notAllowed ? .notAllowed : .failed(f.message)
        case .success(let raw):
            let fresh = raw.split(separator: "\n").compactMap { line -> Item? in
                guard let p = NoteFormat.listItem(String(line)) else { return nil }
                return Item(id: p.id, title: p.title.isEmpty ? "Untitled" : p.title, modified: p.modified ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
            // Only touch the list when something you'd see changed (not just a save time).
            if fresh.map({ "\($0.id)\t\($0.title)" }) != items.map({ "\($0.id)\t\($0.title)" }) { items = fresh }
            status = .ready
            moveOldNoteIfNeeded()
            // Keep the open note; else the last one you had open; else the newest.
            if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
                let last = UserDefaults.standard.string(forKey: Self.lastNoteKey)
                if let id = items.first(where: { $0.id == last })?.id ?? items.first?.id { select(id) }
                else { show(title: "", text: "", id: nil) }
            }
        }
    }

    /// Opens a note from the list (saving the one you were in first).
    func select(_ id: String) {
        guard !isSample else { return }
        saveNow()
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.lastNoteKey)
        // Show what we already have straight away; then check Notes for anything newer.
        if let kept = cache[id] {
            show(title: kept.title, text: kept.text, id: id)
        } else if let item = items.first(where: { $0.id == id }) {
            show(title: item.title, text: "", id: id)
        }
        AppleScriptBridge.run(AppleScripts.readNote, [id]) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedID == id, !self.dirty, case .success(let plain) = result else { return }
                let note = NoteFormat.split(plaintext: plain)
                self.cache[id] = (note.title, note.body)
                self.show(title: note.title, text: note.body, id: id)
            }
        }
    }

    /// Puts a note in the editor. Text that's already there is left alone, so a long note isn't
    /// redrawn (and its scroll position isn't lost) for nothing.
    private func show(title newTitle: String, text newText: String, id: String?) {
        isLoading = true
        if title != newTitle { title = newTitle }
        if text != newText { text = newText }
        isLoading = false
        dirty = false
    }

    // MARK: Writing

    /// A new, empty note in the Ledge folder, opened right away.
    func newNote() {
        guard !isSample else { return }
        saveNow()
        AppleScriptBridge.run(AppleScripts.createNote, [NoteFormat.html(title: "New note", body: "")]) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self, case .success(let id) = result, !id.isEmpty else { return }
                self.query = ""
                self.items.insert(Item(id: id, title: "New note", modified: Date()), at: 0)
                self.selectedID = id
                UserDefaults.standard.set(id, forKey: Self.lastNoteKey)
                self.show(title: "New note", text: "", id: id)
                self.newNoteCount += 1
            }
        }
    }

    /// Saves shortly after typing pauses, so every keystroke doesn't go to Notes.
    private func scheduleSave() {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Saves now if there's an unsaved edit. `wait` holds on until Notes has it (when quitting).
    func saveNow(wait: Bool = false) {
        saveWork?.cancel()
        guard dirty, !isSample, let id = selectedID else { return }
        dirty = false
        cache[id] = (title, text)
        let html = NoteFormat.html(title: title, body: text)
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].title = title.isEmpty ? "Untitled" : title
            items[i].modified = Date()
            items.sort { $0.modified > $1.modified }
        }
        if wait {
            AppleScriptBridge.runAndWait(AppleScripts.updateNote, [id, html])
        } else {
            AppleScriptBridge.run(AppleScripts.updateNote, [id, html]) { result in
                if case .failure(let f) = result { LedgeLog.shared.write("notes: save failed: \(f.message)") }
            }
        }
    }

    // MARK: Search and delete

    private func scheduleSearch() {
        searchWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !isSample else { textMatches = nil; return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveNow() // so the search sees your latest words
                AppleScriptBridge.run(AppleScripts.searchNotes, [q]) { result in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.query.trimmingCharacters(in: .whitespaces) == q,
                              case .success(let raw) = result else { return }
                        self.textMatches = Set(raw.split(separator: "\n").map(String.init))
                    }
                }
            }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Deletes the open note (it goes to Recently Deleted in Notes) and opens the next one.
    func deleteSelected() {
        guard !isSample, let id = selectedID else { return }
        saveWork?.cancel()
        dirty = false
        let index = items.firstIndex { $0.id == id } ?? 0
        items.removeAll { $0.id == id }
        selectedID = nil
        AppleScriptBridge.run(AppleScripts.deleteNote, [id]) { result in
            if case .failure(let f) = result { LedgeLog.shared.write("notes: delete failed: \(f.message)") }
        }
        if items.isEmpty {
            show(title: "", text: "", id: nil)
        } else {
            select(items[min(index, items.count - 1)].id)
        }
    }

    /// Opens the note in the Notes app (for pictures, tables, sharing…).
    func openInNotes() {
        guard !isSample, let id = selectedID else { return }
        saveNow()
        AppleScriptBridge.run(AppleScripts.showNote, [id])
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Once: the old scratch note (Notes.txt) becomes a note called "Scratch note", so nothing is lost.
    private func moveOldNoteIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ledge/Notes.txt")
        guard let old = try? String(contentsOf: file, encoding: .utf8),
              !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        AppleScriptBridge.run(AppleScripts.createNote, [NoteFormat.html(title: "Scratch note", body: old)]) { result in
            if case .success = result {
                LedgeLog.shared.write("notes: moved the old scratch note into Apple Notes")
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        }
    }
}
