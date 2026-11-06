import Foundation

/// The scratch note, saved as plain text at ~/Library/Application Support/Ledge/Notes.txt.
@MainActor
final class NotesStore: ObservableObject {
    @Published var text: String {
        didSet { if persists { scheduleSave() } }
    }

    private let url: URL
    private let persists: Bool
    private var saveWork: DispatchWorkItem?

    /// `sample` is for snapshots: shows that text and never touches your real notes file.
    init(sample: String? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ledge", isDirectory: true)
        url = dir.appendingPathComponent("Notes.txt")
        persists = sample == nil
        if let sample {
            text = sample
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    /// Saves shortly after typing pauses, so every keystroke doesn't hit the disk.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = text
        let target = url
        let work = DispatchWorkItem {
            do { try snapshot.write(to: target, atomically: true, encoding: .utf8) }
            catch { LedgeLog.shared.write("notes: save failed: \(error.localizedDescription)") }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        guard persists else { return }
        saveWork?.cancel()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
