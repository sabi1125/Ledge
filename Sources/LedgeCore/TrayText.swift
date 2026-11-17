import Foundation

/// The words the tray uses, and its 5-item limit. Pure, so it can be tested.
public enum TrayText {
    /// The tray holds this many files or folders at a time. For more, put them in a folder.
    public static let limit = 5

    public static let empty = "Tray is empty"

    /// "2 files and 1 folder" (nil when there's nothing).
    public static func count(files: Int, folders: Int) -> String? {
        var parts: [String] = []
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// "Holding 1 file in tray", "Holding 2 files and 1 folder in tray".
    public static func holding(files: Int, folders: Int) -> String {
        guard let c = count(files: files, folders: folders) else { return empty }
        return "Holding \(c) in tray"
    }

    public static func spacesLeft(held: Int) -> Int { max(0, limit - held) }

    /// Adding `n` more keeps the tray within its limit (all of them or none).
    public static func fits(adding n: Int, held: Int) -> Bool { n > 0 && held + n <= limit }

    /// The drop target's main line while files are dragged over it.
    public static func dropTitle(files: Int, folders: Int, held: Int, over: Bool) -> String {
        let n = files + folders
        guard fits(adding: n, held: held) else {
            return spacesLeft(held: held) == 0 ? "Tray is full" : "Too many for the tray"
        }
        guard over, let c = count(files: files, folders: folders) else { return "Drop to hold in tray" }
        return "Let go to hold \(c)"
    }

    /// The quieter second part: spaces left, or what to do when it doesn't fit.
    public static func dropDetail(files: Int, folders: Int, held: Int, over: Bool) -> String? {
        let n = files + folders
        let left = spacesLeft(held: held)
        guard fits(adding: n, held: held) else {
            if left == 0 { return "holds \(limit) · put these in a folder" }
            return (left == 1 ? "1 more fits" : "\(left) more fit") + " · put these in a folder"
        }
        guard over else { return nil }
        let after = left - n
        return after == 1 ? "1 space left after" : "\(after) spaces left after"
    }

    /// Long names cut in the middle, keeping the extension: "Screenshot 2026…10.21.48.png".
    public static func shortName(_ name: String, max: Int = 44) -> String {
        guard name.count > max, max > 6 else { return name }
        let tail = (max - 1) / 2
        let head = max - 1 - tail
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }
}
