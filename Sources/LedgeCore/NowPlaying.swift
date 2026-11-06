import Foundation

/// What's playing right now, as reported by the media bridge.
public struct NowPlayingState: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double = 0
    /// Elapsed time at `timestamp`.
    public var elapsed: Double = 0
    public var rate: Double = 0
    public var timestamp: Date?
    public var isPlaying = false
    public var bundleID: String?
    public var artworkID: String?

    public init() {}

    public var hasContent: Bool {
        !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Elapsed time at `now`, moving forward while playing and clamped to the track length.
    public func elapsed(at now: Date) -> Double {
        var value = elapsed
        if isPlaying, let timestamp {
            let speed = rate > 0 ? rate : 1
            value += now.timeIntervalSince(timestamp) * speed
        }
        value = max(0, value)
        if duration > 0 { value = min(value, duration) }
        return value
    }

    /// 0...1, or 0 when the length is unknown.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return elapsed(at: now) / duration
    }
}

public enum BridgeMessage: Equatable {
    case ready
    case info(NowPlayingState, artwork: Data?)
    case error(String)
}

public enum BridgeParser {
    /// Parses one JSON line from the media bridge.
    public static func parse(_ line: Data) -> BridgeMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready
        case "error":
            return .error(obj["message"] as? String ?? "unknown error")
        case "info":
            var s = NowPlayingState()
            s.title = obj["title"] as? String
            s.artist = obj["artist"] as? String
            s.album = obj["album"] as? String
            s.duration = number(obj["duration"])
            s.elapsed = number(obj["elapsed"])
            s.rate = number(obj["rate"])
            if let ts = obj["timestamp"] as? Double { s.timestamp = Date(timeIntervalSince1970: ts) }
            s.isPlaying = (obj["playing"] as? Bool) ?? false
            s.bundleID = obj["bundle"] as? String
            s.artworkID = obj["artworkId"] as? String
            let art = (obj["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
            return .info(s, artwork: art)
        default:
            return nil
        }
    }

    private static func number(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
}

/// Formats seconds as m:ss (or h:mm:ss).
public func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
