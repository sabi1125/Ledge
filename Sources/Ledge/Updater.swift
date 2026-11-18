import AppKit

/// "Check for updates": compares the installed Ledge with the project on GitHub, and can pull
/// the latest version and rebuild/reinstall it (scripts/install.sh) without the terminal.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(changes: [String])
        case updating
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// The project folder that holds the source (the git repository): the `sourceFolder` setting
    /// if set, else the folder this copy was built from (written by scripts/build.sh), else ~/Ledge.
    var folder: URL {
        let custom = UserDefaults.standard.string(forKey: "sourceFolder")
        let builtFrom = Bundle.main.object(forInfoDictionaryKey: "LedgeSource") as? String
        return URL(fileURLWithPath: custom ?? builtFrom ?? (NSHomeDirectory() + "/Ledge"))
    }

    /// The saved version this copy of Ledge was built from (written by scripts/build.sh).
    static var installedCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "LedgeCommit") as? String
    }

    static var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return installedCommit.map { "\(v) (\($0))" } ?? v
    }

    func check() {
        guard state != .checking, state != .updating else { return }
        state = .checking
        let folder = folder
        // A build with unsaved changes ("+") already has everything up to the project's current version.
        let raw = Self.installedCommit
        let installed = (raw?.hasSuffix("+") ?? true) ? nil : raw
        Task.detached {
            let result = Self.checkSync(folder: folder, installed: installed)
            await MainActor.run { self.state = result }
        }
    }

    nonisolated private static func checkSync(folder: URL, installed: String?) -> State {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else {
            return .failed("Couldn't find the Ledge project at \(folder.path).")
        }
        let fetch = git(["fetch", "--quiet", "origin"], in: folder)
        guard fetch.ok else { return .failed("Couldn't reach GitHub. \(fetch.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        // Compare against the version that's installed (falls back to the project's current one).
        var base = "HEAD"
        if let installed, git(["cat-file", "-e", "\(installed)^{commit}"], in: folder).ok { base = installed }
        let log = git(["log", "--format=%s", "\(base)..origin/main"], in: folder)
        guard log.ok else { return .failed("Couldn't compare versions.") }
        let changes = log.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return changes.isEmpty ? .upToDate : .available(changes: changes)
    }

    /// Pulls the latest version, then rebuilds and reinstalls Ledge, which restarts it.
    func update() {
        guard state != .updating else { return }
        state = .updating
        let folder = folder
        Task.detached {
            let pull = Self.git(["pull", "--ff-only", "--quiet", "origin", "main"], in: folder)
            guard pull.ok else {
                let why = pull.err.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { self.state = .failed("Couldn't get the latest version. \(why)") }
                return
            }
            // Run the installer on its own, so it keeps going when it quits and restarts Ledge.
            let log = NSHomeDirectory() + "/Library/Logs/Ledge-update.log"
            let script = folder.appendingPathComponent("scripts/install.sh").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", "nohup \"$0\" > \"$1\" 2>&1 &", script, log]
            p.currentDirectoryURL = folder
            do { try p.run() } catch {
                await MainActor.run { self.state = .failed("Couldn't start the installer.") }
                return
            }
            await MainActor.run { self.watchInstall(log: log) }
        }
        LedgeLog.shared.write("updater: updating from \(Self.versionText)")
    }

    /// The installer runs on its own and restarts Ledge when it's done, so success needs no
    /// answer. Failure would leave "Updating…" forever: watch its log for an error, and give up
    /// waiting after a few minutes.
    private func watchInstall(log: String) {
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.state == .updating else { timer.invalidate(); return }
                let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                let failed = ["errSec", "error:", "Build failed", "✗"].contains { text.contains($0) }
                if failed || Date().timeIntervalSince(started) > 240 {
                    timer.invalidate()
                    let why = text.contains("errSec")
                        ? "Signing failed (the keychain prompt wasn't answered?)."
                        : (failed ? "The build failed." : "It's taking too long.")
                    self.state = .failed("Update failed. \(why) See ~/Library/Logs/Ledge-update.log")
                    LedgeLog.shared.write("updater: install didn't finish (\(why))")
                }
            }
        }
    }

    nonisolated private static func git(_ args: [String], in folder: URL) -> (ok: Bool, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0" // never wait for a password prompt
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        // Read while git runs: waiting first would hang once git writes more than a pipe holds.
        // (stderr on its own thread, so neither pipe can fill up while the other is read.)
        let errData = ErrBox()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            errData.data = err.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        reading.wait()
        p.waitUntilExit()
        let e = String(data: errData.data, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, o, e)
    }
}

private final class ErrBox: @unchecked Sendable { var data = Data() }
