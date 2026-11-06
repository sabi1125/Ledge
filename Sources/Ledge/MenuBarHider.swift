import AppKit
import ApplicationServices
import LedgeCore

/// Hides every third-party menu bar icon by placing an invisible, very wide
/// "divider" item just left of Apple's Wi-Fi and battery icons. Anything to the
/// left of the divider (all other apps' icons, including apps installed later,
/// which macOS adds on the left) gets pushed off-screen.
///
/// The divider's position is measured with the Accessibility API, so the hider
/// never turns on until it knows exactly where Wi-Fi and the battery are.
@MainActor
final class MenuBarHider {
    enum Status: Equatable {
        case off
        case needsPermission
        case couldNotPlace
        case hiding
        case revealed
    }

    private(set) var status: Status = .off { didSet { onStatusChange?(status) } }
    var onStatusChange: ((Status) -> Void)?

    private var divider: NSStatusItem?
    private var revealTimer: Timer?
    private var permissionTimer: Timer?
    private let autosaveName = "LedgeDivider"
    /// Width of the divider while hiding; found by `hide(keptBefore:)`.
    private var hiddenLength: CGFloat = 300
    private let log = LedgeLog.shared

    private var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }

    // MARK: Control

    func apply(enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard AXIsProcessTrusted() else {
            log.write("hider: waiting for Accessibility permission")
            status = .needsPermission
            waitForPermission()
            return
        }
        log.write("hider: Accessibility permission OK")
        permissionTimer?.invalidate()
        place()
    }

    func stop() {
        revealTimer?.invalidate()
        permissionTimer?.invalidate()
        removeDivider()
        status = .off
    }

    /// Asks macOS for Accessibility access (shows the system prompt once).
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        waitForPermission()
    }

    /// Shows the hidden icons for a few seconds.
    func reveal(seconds: TimeInterval = 8) {
        guard let divider, status == .hiding || status == .revealed else { return }
        divider.length = 0
        status = .revealed
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideAgain() }
        }
    }

    private func hideAgain() {
        guard let divider, status == .revealed else { return }
        divider.length = hiddenLength
        status = .hiding
    }

    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, AXIsProcessTrusted() else { return }
                self.permissionTimer?.invalidate()
                if Pref.bool(Pref.hideMenuBarIcons) { self.place() }
            }
        }
    }

    // MARK: Placement

    private func place() {
        guard let target = keepVisibleLeftEdge() else {
            log.write("hider: could not find Wi-Fi/battery/Control Center items")
            status = .couldNotPlace
            return
        }
        // macOS remembers a "preferred position" for each status item (roughly: points from the
        // right edge). Guess, measure where the divider actually landed, and correct.
        let screenMaxX = NSScreen.screens.first?.frame.maxX ?? 0
        let saved = UserDefaults.standard.object(forKey: positionKey) as? Double
        let keptBefore = keptFrames()
        attempt(1, position: saved ?? Double(screenMaxX - target + 2), direction: 1,
                lastGap: nil, target: target, keptBefore: keptBefore)
    }

    /// One placement try. `direction` flips if a correction moved the divider the wrong way.
    private func attempt(_ n: Int, position: Double, direction: Double, lastGap: CGFloat?,
                         target: CGFloat, keptBefore: [CGFloat]) {
        guard n <= 8 else {
            removeDivider()
            status = .couldNotPlace
            log.write("hider: gave up placing divider")
            return
        }
        UserDefaults.standard.set(position, forKey: positionKey)
        removeDivider()
        // macOS 27 doesn't let us read our own item's position, so measure it indirectly:
        // make the divider 30pt wide and see which icons shift left to make room.
        // Icons that shift are left of the divider; icons that stay are right of it.
        let before = positionsByKey()
        let width: CGFloat = 30
        createDivider(length: width)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let after = self.positionsByKey()
            var keptShifted: [String] = [], foreignStill: [String] = []
            var stillXs: [CGFloat] = []
            for (key, item) in before {
                let shifted = after[key].map { $0.frame.minX < item.frame.minX - width / 2 } ?? true
                if !shifted { stillXs.append(item.frame.minX) }
                if self.isOverflow(item) { continue }
                if self.isKept(item) && shifted { keptShifted.append(key) }
                if !self.isKept(item) && !shifted { foreignStill.append(key) }
            }
            // The divider sits just left of the leftmost icon that didn't move.
            let boundary = stillXs.min() ?? (NSScreen.screens.first?.frame.maxX ?? target)
            self.log.write("hider: attempt \(n) position \(Int(position)) divider near x=\(Int(boundary)) target \(Int(target)) keptShifted=\(keptShifted.count) appsRightOfDivider=\(foreignStill.count)")

            if keptShifted.isEmpty && foreignStill.isEmpty {
                self.hide(keptBefore: keptBefore)
                return
            }
            let error = target - boundary  // negative = move left, positive = move right
            var dir = direction
            if let lastGap, abs(error) >= abs(lastGap) - 0.5 { dir = -dir } // got worse: flip
            // Positive position change moves the item left (points from the right edge).
            let next = position - dir * Double(error) + (error < 0 ? 2 : -2) * dir
            self.attempt(n + 1, position: next, direction: dir, lastGap: error,
                         target: target, keptBefore: keptBefore)
        }
    }

    /// On macOS 27 an over-wide item is just tucked away, so instead the divider is sized to
    /// fill the gap between the notch and Wi-Fi. Other icons then have no room and macOS moves
    /// them into its overflow. Tries sizes until no app icon is visible.
    private func hide(keptBefore: [CGFloat]) {
        let target = keptBefore.first ?? 0
        let notchRight = IslandController.notchedScreen()?.auxiliaryTopRightArea.map { area -> CGFloat in
            // auxiliaryTopRightArea is relative to the screen; convert to global x.
            (IslandController.notchedScreen()?.frame.minX ?? 0) + ((IslandController.notchedScreen()?.frame.width ?? 0) - area.width)
        } ?? 0
        let available = max(40, target - notchRight)
        let override = UserDefaults.standard.double(forKey: "dividerLength")
        // Reuse the size that worked last time only if the gap is still about the same.
        let saved = UserDefaults.standard.double(forKey: "dividerLengthWorked")
        let savedFits = saved > 0 && saved <= available + 30 && saved >= available - 60
        let first = override > 0 ? override : (savedFits ? saved : available - 2)
        let appsBefore = foreignVisible(rightOf: notchRight, before: target)
        log.write("hider: sizing divider, gap \(Int(available))pt between notch (\(Int(notchRight))) and Wi-Fi (\(Int(target)))")
        trySize(first, step: 1, notchRight: notchRight, target: target, available: available,
                keptBefore: keptBefore, appsBefore: appsBefore, fixed: override > 0)
    }

    private func trySize(_ length: CGFloat, step: Int, notchRight: CGFloat, target: CGFloat, available: CGFloat,
                         keptBefore: [CGFloat], appsBefore: [MenuExtra], fixed: Bool) {
        guard step <= 10, length > 0 else {
            log.write("hider: no divider size hid the icons; turning hiding off")
            removeDivider()
            status = .couldNotPlace
            return
        }
        divider?.length = length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            // Safety check: Wi-Fi, battery, Control Center and the clock must not move.
            // Every icon we keep must still be exactly where it was. (Another item, like macOS's
            // overflow chevron, sliding in next to them is fine.)
            let after = self.allMenuExtras().filter { self.isAppleKeepCandidate($0) || $0.kept }.map(\.frame.minX)
            let moved = keptBefore.contains { x in !after.contains { abs($0 - x) <= 3 } }
            if moved {
                self.log.write("hider: size \(Int(length)): kept icons moved (\(keptBefore.map(Int.init)) -> \(after.map(Int.init))); undoing")
                self.removeDivider()
                self.status = .couldNotPlace
                return
            }
            let visible = self.foreignVisible(rightOf: notchRight, before: target)
            self.log.write("hider: size \(Int(length)): still visible: " +
                           (visible.isEmpty ? "none" : visible.map { "\($0.owner)@\(Int($0.frame.minX))" }.joined(separator: ", ")))
            if visible.isEmpty {
                self.hiddenLength = length
                UserDefaults.standard.set(Double(length), forKey: "dividerLengthWorked")
                self.status = .hiding
                self.log.write("hider: hiding with divider size \(Int(length))")
                return
            }
            if fixed {
                self.log.write("hider: fixed size from 'dividerLength' didn't hide everything")
                self.hiddenLength = length
                self.status = .hiding
                return
            }
            // If nothing moved at all, the divider was probably too big and got tucked away: shrink.
            // If icons moved but some still fit, grow.
            let unchanged = visible.allSatisfy { v in appsBefore.contains { $0.owner == v.owner && abs($0.frame.minX - v.frame.minX) < 2 } }
            let next = unchanged ? length - 24 : min(length + 12, available + 30)
            self.trySize(next, step: step + 1, notchRight: notchRight, target: target, available: available,
                         keptBefore: keptBefore, appsBefore: appsBefore, fixed: false)
        }
    }

    /// Other apps' icons currently showing between the notch and Wi-Fi.
    private func foreignVisible(rightOf left: CGFloat, before right: CGFloat) -> [MenuExtra] {
        let me = ProcessInfo.processInfo.processIdentifier
        return allMenuExtras().filter {
            // MenuBarAgent's own pieces (like the overflow chevron) can't be hidden, so ignore them.
            $0.pid != me && !isKept($0) && !isOverflow($0) && !isAppleKeepCandidate($0) && $0.frame.width > 0
                && $0.frame.minX >= left - 1 && $0.frame.minX < right
        }
    }

    private func keptFrames() -> [CGFloat] {
        allMenuExtras().filter(isKept).map(\.frame.minX).sorted()
    }

    /// Every other app's menu bar item, keyed so the same item can be found again after a change.
    private func positionsByKey() -> [String: MenuExtra] {
        let me = ProcessInfo.processInfo.processIdentifier
        var counts: [String: Int] = [:]
        var result: [String: MenuExtra] = [:]
        // Count from the right: items on the right never move when the divider grows.
        for e in allMenuExtras().reversed() where e.pid != me && e.frame.width > 0 {
            let base = "\(e.owner)|\(e.identifier)"
            let k = counts[base, default: 0]
            counts[base] = k + 1
            result["\(base)#\(k)"] = e
        }
        return result
    }

    private func createDivider(length: CGFloat = 0) {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = autosaveName
        item.button?.image = nil
        item.button?.title = ""
        // Clicking empty menu bar space left of Wi-Fi reveals the hidden icons.
        item.button?.target = self
        item.button?.action = #selector(dividerClicked)
        divider = item
    }

    @objc private func dividerClicked() { reveal() }

    private func removeDivider() {
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
    }

    // MARK: Reading the menu bar (Accessibility)

    private struct MenuExtra {
        var identifier: String
        var frame: CGRect // x grows rightwards; y is top-down but unused
        var pid: pid_t
        var owner: String
        var details: String
        var kept = false
    }

    /// Apple's items we keep visible: Wi-Fi, battery, Control Center and the clock.
    private static let keepIdentifiers = ["wifi", "battery", "controlcenter", "clock"]
    /// On macOS 27, Wi-Fi, battery, Control Center and the clock (and any other
    /// Apple icons left on in System Settings → Menu Bar) belong to MenuBarAgent.
    private static let keepOwners = ["com.apple.MenuBarAgent", "com.apple.controlcenter"]

    /// macOS 27's own "Show Hidden Menu Bar Items" chevron.
    private func isOverflow(_ extra: MenuExtra) -> Bool {
        extra.identifier.contains("overflow")
    }

    private func isKept(_ extra: MenuExtra) -> Bool { extra.kept }

    private func isAppleKeepCandidate(_ extra: MenuExtra) -> Bool {
        if isOverflow(extra) { return false }
        if Self.keepOwners.contains(extra.owner) { return true }
        let id = extra.identifier.lowercased()
        return Self.keepIdentifiers.contains { id.contains($0) }
    }

    /// Left edge of the leftmost kept item, in screen points.
    private func keepVisibleLeftEdge() -> CGFloat? {
        let extras = allMenuExtras()
        log.write("hider: menu extras: " + extras.map { "\($0.identifier)@\(Int($0.frame.minX))" }.joined(separator: ", "))
        for e in extras {
            log.write("hider:   \(isKept(e) ? "keep" : "hide") x=\(Int(e.frame.minX)) w=\(Int(e.frame.width)) owner=\(e.owner) \(e.details)")
        }
        let kept = extras.filter(isKept)
        return kept.map(\.frame.minX).min()
    }

    /// A non-kept, non-Ledge item whose left edge lies in [lo, hi).
    private func firstForeignItem(between lo: CGFloat, and hi: CGFloat) -> CGFloat? {
        let me = ProcessInfo.processInfo.processIdentifier
        return allMenuExtras()
            .filter { $0.pid != me && !isKept($0) && !isOverflow($0) && $0.frame.minX >= lo - 1 && $0.frame.minX < hi - 1 && $0.frame.width > 0 }
            .map(\.frame.minX).min()
    }

    private func allMenuExtras() -> [MenuExtra] {
        var result: [MenuExtra] = []
        for app in NSWorkspace.shared.runningApplications {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
                  let barElement = bar else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barElement as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                  let items = children as? [AXUIElement] else { continue }
            for item in items {
                guard let frame = Self.frame(of: item) else { continue }
                let ident = Self.string(item, "AXIdentifier") ?? Self.string(item, kAXDescriptionAttribute)
                    ?? Self.string(item, kAXTitleAttribute) ?? app.bundleIdentifier ?? "?"
                let details = ["AXIdentifier", kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXSubroleAttribute]
                    .compactMap { attr in Self.string(item, attr).map { "\(attr)=\"\($0)\"" } }
                    .joined(separator: " ")
                result.append(MenuExtra(identifier: ident, frame: frame, pid: app.processIdentifier,
                                        owner: app.bundleIdentifier ?? "?", details: details))
            }
        }
        result.sort { $0.frame.minX < $1.frame.minX }
        // Keep only the run of Apple icons at the right end (Wi-Fi, battery, Control Center,
        // clock). Stop at the first app icon, so stray Apple items further left get hidden too.
        let me = ProcessInfo.processInfo.processIdentifier
        for i in result.indices.reversed() {
            if result[i].pid == me || result[i].frame.width <= 0 { continue }
            guard isAppleKeepCandidate(result[i]) else { break }
            result[i].kept = true
        }
        return result
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}

/// A small log file at ~/Library/Logs/Ledge.log, to see what happened after the fact.
final class LedgeLog {
    static let shared = LedgeLog()
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Ledge.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
