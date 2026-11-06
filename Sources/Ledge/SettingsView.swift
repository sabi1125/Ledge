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

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @AppStorage(Pref.showMusic) private var showMusic = true
    @AppStorage(Pref.showVolume) private var showVolume = true
    @AppStorage(Pref.showBrightness) private var showBrightness = true
    @AppStorage(Pref.showBattery) private var showBattery = true
    @AppStorage(Pref.openOnHover) private var openOnHover = true
    @AppStorage(Pref.hideMenuBarIcons) private var hideIcons = true

    var body: some View {
        Form {
            Section("Island") {
                Toggle("Show what's playing", isOn: $showMusic)
                Toggle("Open the player when the pointer is over the notch", isOn: $openOnHover)
                Text(openOnHover ? "You can also click the island to open or close it." : "Click the island to open or close it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Indicators") {
                Toggle("Volume", isOn: $showVolume)
                Toggle("Brightness", isOn: $showBrightness)
                Toggle("Charging and low battery", isOn: $showBattery)
            }
            Section("Menu bar") {
                Toggle("Hide other apps' menu bar icons", isOn: $hideIcons)
                    .onChange(of: hideIcons) { _, value in state.onHideIconsChanged?(value) }
                hiderStatusRow
                Text("Press ⌃⌥⌘M, or click the empty space left of Wi-Fi, to show hidden icons for a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple's own icons are switched off in System Settings. Keep Wi-Fi and Battery on, and turn off the rest (Bluetooth, Sound, Focus, Now Playing, Spotlight, Siri, Screen Mirroring, Display and so on).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Menu Bar Settings…") {
                        let urls = ["x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
                                    "x-apple.systempreferences:com.apple.preference.controlcenter"]
                        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { break } }
                    }
                }
            }
            Section("General") {
                Toggle("Open Ledge when you log in", isOn: $state.launchAtLogin)
                    .onChange(of: state.launchAtLogin) { _, value in
                        LoginItem.set(value)
                        state.launchAtLogin = LoginItem.isEnabled
                    }
                HStack {
                    Text("Right-click the island for these settings, or to quit.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit Ledge") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var hiderStatusRow: some View {
        switch state.hiderStatus {
        case .off:
            EmptyView()
        case .hiding, .revealed:
            Label("Hiding icons", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsPermission:
            HStack {
                Label("Needs Accessibility access to find Wi-Fi and the battery", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Allow…") { state.requestAccessibility?() }
            }
        case .couldNotPlace:
            Label("Couldn't find Wi-Fi and the battery in the menu bar, so nothing is hidden. See ~/Library/Logs/Ledge.log.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
