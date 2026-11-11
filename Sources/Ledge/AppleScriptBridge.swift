import Foundation

/// Runs AppleScript with `osascript`, one at a time on a background queue, so talking to Notes or
/// Reminders never stalls the island. macOS asks once per app ("Ledge wants to control Notes").
enum AppleScriptBridge {
    struct Failure: Error, Equatable {
        var message: String
        /// You said no to "Ledge wants to control …" (or haven't been asked yet and it failed).
        var notAllowed: Bool
    }

    private static let queue = DispatchQueue(label: "local.sabir.ledge.applescript")

    /// `args` arrive as `argv` in the script's `on run argv` handler.
    static func run(_ script: String, _ args: [String] = [],
                    completion: @escaping @Sendable (Result<String, Failure>) -> Void = { _ in }) {
        queue.async { completion(runNow(script, args)) }
    }

    /// Waits for the result (used when quitting, so the last edit is saved).
    @discardableResult
    static func runAndWait(_ script: String, _ args: [String] = []) -> Result<String, Failure> {
        queue.sync { runNow(script, args) }
    }

    private static func runNow(_ script: String, _ args: [String]) -> Result<String, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Each line as its own -e; anything after the script is passed to `on run argv`.
        process.arguments = script.split(separator: "\n").flatMap { ["-e", String($0)] } + args
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return .failure(Failure(message: error.localizedDescription, notAllowed: false))
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            var text = String(decoding: out, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            return .success(text)
        }
        let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        LedgeLog.shared.write("applescript: failed: \(message)")
        return .failure(Failure(message: message,
                                notAllowed: message.contains("-1743") || message.localizedCaseInsensitiveContains("not allowed")))
    }
}

/// The AppleScript Ledge uses with Notes and Reminders.
enum AppleScripts {
    /// Makes the "Ledge" folder if needed, then lists its notes: id, title and last change.
    static let listNotes = """
    on run argv
    tell application "Notes"
    if not (exists folder "Ledge") then make new folder with properties {name:"Ledge"}
    set out to ""
    repeat with n in notes of folder "Ledge"
    set out to out & (id of n) & tab & (name of n) & tab & ((modification date of n) as «class isot» as string) & linefeed
    end repeat
    return out
    end tell
    end run
    """

    static let readNote = """
    on run argv
    tell application "Notes" to return plaintext of note id (item 1 of argv)
    end run
    """

    /// Body HTML in, new note's id out.
    static let createNote = """
    on run argv
    tell application "Notes"
    if not (exists folder "Ledge") then make new folder with properties {name:"Ledge"}
    set n to make new note at folder "Ledge" with properties {body:(item 1 of argv)}
    return id of n
    end tell
    end run
    """

    static let updateNote = """
    on run argv
    tell application "Notes" to set body of note id (item 1 of argv) to (item 2 of argv)
    end run
    """

    /// The ids of notes in the Ledge folder whose title or text contains the words (any case).
    static let searchNotes = """
    on run argv
    tell application "Notes"
    set q to item 1 of argv
    set out to ""
    repeat with n in notes of folder "Ledge"
    if (name of n contains q) or (plaintext of n contains q) then set out to out & (id of n) & linefeed
    end repeat
    return out
    end tell
    end run
    """

    /// Moves the note to Notes' Recently Deleted.
    static let deleteNote = """
    on run argv
    tell application "Notes" to delete note id (item 1 of argv)
    end run
    """

    static let showNote = """
    on run argv
    tell application "Notes"
    show note id (item 1 of argv)
    activate
    end tell
    end run
    """

    /// Opens Reminders on the to-do (or just opens Reminders, if it can't find it).
    static let showReminder = """
    on run argv
    tell application "Reminders"
    activate
    try
    show reminder id ("x-apple-reminder://" & (item 1 of argv))
    end try
    end tell
    end run
    """
}
