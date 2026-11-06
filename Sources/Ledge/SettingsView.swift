import AppKit
import SwiftUI

/// Observable wrapper so the settings window can show live status.
@MainActor
final class SettingsState: ObservableObject {
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var hiderStatus: MenuBarHider.Status = .off
    var onHideIconsChanged: ((Bool) -> Void)?
    var requestAccessibility: (() -> Void)?
    var revealIcons: (() -> Void)?
}

/// Everything in Ledge can be switched on or off here.
struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var updater: Updater

    // Pages
    @AppStorage(Pref.showMusic) private var showMusic = true
    @AppStorage(Pref.pageCalendar) private var pageCalendar = true
    @AppStorage(Pref.pageTimer) private var pageTimer = true
    @AppStorage(Pref.pageNotes) private var pageNotes = true
    // Indicators
    @AppStorage(Pref.showVolume) private var showVolume = true
    @AppStorage(Pref.showBrightness) private var showBrightness = true
    @AppStorage(Pref.showBattery) private var showBattery = true
    // Behavior
    @AppStorage(Pref.openOnHover) private var openOnHover = true
    @AppStorage(Pref.haptics) private var haptics = true
    @AppStorage(Pref.showOnOtherDisplays) private var showOnOtherDisplays = true
    // Menu bar
    @AppStorage(Pref.hideMenuBarIcons) private var hideIcons = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showMusic) { row("Music", "music.note", "What's playing, with controls") }
                Toggle(isOn: $pageCalendar) { row("Calendar", "calendar", "Today's date and your next events") }
                Toggle(isOn: $pageTimer) { row("Timer", "timer", "A countdown that lives in the notch") }
                Toggle(isOn: $pageNotes) { row("Notes", "note.text", "A scratch pad") }
            } header: {
                Text("Pages")
            } footer: {
                Text("Swipe with two fingers on the open island to move between pages.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Indicators") {
                Toggle(isOn: $showVolume) { row("Volume", "speaker.wave.2.fill", nil) }
                Toggle(isOn: $showBrightness) { row("Brightness", "sun.max.fill", nil) }
                Toggle(isOn: $showBattery) { row("Charging and low battery", "battery.75percent", nil) }
            }

            Section("Behavior") {
                Toggle("Open when the pointer is over the notch", isOn: $openOnHover)
                Toggle("Trackpad tick when the island opens", isOn: $haptics)
                Toggle("Show Ledge on other displays", isOn: $showOnOtherDisplays)
            }

            Section("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ledge \(Updater.versionText)")
                        updateStatus
                    }
                    Spacer()
                    updateButton
                }
                if case let .available(changes) = updater.state {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(changes.prefix(5), id: \.self) { Text("• \($0)").font(.caption) }
                        if changes.count > 5 {
                            Text("and \(changes.count - 5) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Open Ledge when you log in", isOn: $state.launchAtLogin)
                    .onChange(of: state.launchAtLogin) { _, value in
                        LoginItem.set(value)
                        state.launchAtLogin = LoginItem.isEnabled
                    }
                DisclosureGroup("Menu bar") {
                    Toggle("Squeeze other apps' icons into the overflow", isOn: $hideIcons)
                        .onChange(of: hideIcons) { _, value in state.onHideIconsChanged?(value) }
                    hiderStatusRow
                    Text("To remove icons completely, turn them off in System Settings → Menu Bar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Menu Bar Settings…") {
                        let urls = ["x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
                                    "x-apple.systempreferences:com.apple.preference.controlcenter"]
                        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { break } }
                    }
                }
                HStack {
                    Text("Right-click the island to open these settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit Ledge") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, _ symbol: String, _ detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle: EmptyView()
        case .checking: Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .upToDate: Text("You have the latest version").font(.caption).foregroundStyle(.secondary)
        case let .available(changes):
            Text("\(changes.count) \(changes.count == 1 ? "change" : "changes") available")
                .font(.caption).foregroundStyle(.green)
        case .updating: Text("Updating… Ledge will restart in a minute").font(.caption).foregroundStyle(.secondary)
        case let .failed(why): Text(why).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var updateButton: some View {
        switch updater.state {
        case .available: Button("Update and restart") { updater.update() }.buttonStyle(.borderedProminent)
        case .checking, .updating: ProgressView().controlSize(.small)
        default: Button("Check for updates") { updater.check() }
        }
    }

    @ViewBuilder private var hiderStatusRow: some View {
        switch state.hiderStatus {
        case .off:
            EmptyView()
        case .hiding, .revealed:
            Label("Squeezing icons", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsPermission:
            HStack {
                Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Allow…") { state.requestAccessibility?() }
            }
        case .couldNotPlace:
            Label("Couldn't find Wi-Fi and the battery in the menu bar.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
