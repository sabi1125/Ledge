import AppKit
import LedgeCore

/// Runs the media bridge (see Bridge/MediaBridge.m) and feeds what's playing into the island.
@MainActor
final class MediaController {
    private let model: IslandModel
    private var process: Process?
    private var input: Pipe?
    private var lastReported: NowPlayingState?
    /// After you press play/pause, hold that state briefly so a stale report can't flip it back.
    private var heldPlaying: (value: Bool, until: Date)?
    private var lastToggle: Date?
    private var artworkCache: [String: Data] = [:]
    private var artworkOrder: [String] = []
    private var buffer = Data()
    private var artworkID: String?
    private var restarts = 0
    private var startedAt = Date()

    init(model: IslandModel) {
        self.model = model
    }

    private var bridgeFiles: (script: String, library: String)? {
        guard let script = Bundle.main.path(forResource: "media-bridge", ofType: "pl"),
              let lib = Bundle.main.path(forResource: "MediaBridge", ofType: "dylib") else { return nil }
        return (script, lib)
    }

    func start() {
        guard let files = bridgeFiles else {
            NSLog("Ledge: media bridge files are missing from the app bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.library, "ledge_stream"]
        let out = Pipe()
        let inPipe = Pipe() // kept open; the bridge exits when Ledge does
        p.standardOutput = out
        p.standardInput = inPipe
        input = inPipe
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.bridgeExited() }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
        } catch {
            NSLog("Ledge: could not start media bridge: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func bridgeExited() {
        process = nil
        // Forget restarts that happened long ago, then retry with a growing delay.
        if Date().timeIntervalSince(startedAt) > 60 { restarts = 0 }
        guard restarts < 6 else {
            NSLog("Ledge: media bridge keeps exiting; giving up")
            return
        }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 1.5) { [weak self] in
            self?.start()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        switch BridgeParser.parse(line) {
        case let .info(state, artwork):
            if state.title != lastReported?.title || state.isPlaying != lastReported?.isPlaying {
                LedgeLog.shared.write("media: \(state.isPlaying ? "playing" : "paused") \"\(state.title ?? "")\" from \(state.bundleID ?? "?")")
            }
            lastReported = state
            var state = state
            if let held = heldPlaying, Date() < held.until, state.title == model.media.title {
                if state.isPlaying == held.value {
                    heldPlaying = nil // confirmed
                } else {
                    state.isPlaying = held.value
                    state.elapsed = model.media.elapsed(at: Date())
                    state.timestamp = Date()
                }
            }
            if let artwork, let id = state.artworkID {
                artworkCache[id] = artwork
                artworkOrder.removeAll { $0 == id }
                artworkOrder.append(id)
                while artworkOrder.count > 8 { artworkCache[artworkOrder.removeFirst()] = nil }
            }
            if state.artworkID != artworkID {
                if let id = state.artworkID, let data = artwork ?? artworkCache[id] {
                    artworkID = id
                    model.setArtwork(data)
                    LedgeLog.shared.write("artwork: showing \(id) (\(data.count / 1024) KB)")
                } else if state.artworkID == nil {
                    // Players briefly drop the artwork around play/pause. Keep the picture while
                    // it's still the same track; clear it only when the track changed.
                    if state.title != model.media.title || state.artist != model.media.artist {
                        artworkID = nil
                        model.setArtwork(nil)
                        LedgeLog.shared.write("artwork: none for this track")
                    }
                } else {
                    // New artwork id but no image data (shouldn't happen): ask for a fresh report.
                    requestRefresh()
                }
            }
            model.media = state
        case let .error(message):
            NSLog("Ledge: media bridge error: \(message)")
        case .ready, nil:
            break
        }
    }

    // MARK: Commands

    func send(_ command: MediaCommand) {
        var media = model.media
        let name: String
        var arg: String?
        switch command {
        case .toggle:
            // Send an explicit play or pause (not "toggle"), so a click that arrives twice
            // can't undo itself. Base it on what the button showed when it was pressed.
            let shownPlaying = heldPlaying.flatMap { Date() < $0.until ? $0.value : nil } ?? media.isPlaying
            if let last = lastToggle, Date().timeIntervalSince(last) < 0.35 {
                LedgeLog.shared.write("command: ignored repeated play/pause click")
                return
            }
            lastToggle = Date()
            name = shownPlaying ? "pause" : "play"
            // Update right away; the bridge confirms a moment later.
            media.elapsed = media.elapsed(at: Date())
            media.timestamp = Date()
            media.isPlaying = !shownPlaying
            heldPlaying = (media.isPlaying, Date().addingTimeInterval(1.5))
        case .next: name = "next"
        case .previous: name = "previous"
        case let .seek(seconds):
            name = "seek"
            arg = String(seconds)
            media.elapsed = seconds
            media.timestamp = Date()
        }
        model.media = media
        LedgeLog.shared.write("command: \(name)\(arg.map { " \($0)" } ?? "")")

        guard let files = bridgeFiles else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.library, "ledge_send"]
        var env = ProcessInfo.processInfo.environment
        env["LEDGE_CMD"] = name
        if let arg { env["LEDGE_ARG"] = arg }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Once the command has gone through, ask the bridge for a fresh report.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.requestRefresh() }
        }
        try? p.run()
    }

    private func requestRefresh() {
        input?.fileHandleForWriting.write(Data("\n".utf8))
    }
}
