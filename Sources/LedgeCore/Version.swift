import Foundation

/// Version numbers like "1.3", "1.3.1" or a release tag "v1.4.0".
public enum Version {
    /// The numbers in it: "v1.3.1" → [1, 3, 1]. Anything after a "-" ("1.4.0-beta") is ignored.
    public static func parts(_ text: String) -> [Int] {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
        return t.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Whether `a` is a later version than `b` ("1.3.1" is later than "1.3"; "1.10" than "1.9").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
