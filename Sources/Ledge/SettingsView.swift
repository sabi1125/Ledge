import AppKit
import LedgeCore
import SwiftUI

/// Settings that need the app (not just a saved preference).
@MainActor
final class SettingsState: ObservableObject {
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var hiderStatus: MenuBarHider.Status = .off
    var onHideIconsChanged: ((Bool) -> Void)?
    var requestAccessibility: (() -> Void)?
    var revealIcons: (() -> Void)?
    /// Opens and closes the notch island once, to show the chosen animation.
    var previewAnimation: (() -> Void)?
}

/// Ledge's settings, shown inside the island itself (opened from Spotlight, the Applications
/// folder, or a right-click on the island). Two columns, in the island's own black style.
struct SettingsPanel: View {
    @ObservedObject var model: IslandModel
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
    @AppStorage(Pref.hideMenuBarIcons) private var hideIcons = true
    // Animation
    @AppStorage(IslandAnimation.key) private var animation = IslandAnimation.calm.rawValue
    // Stay awake
    @AppStorage(Pref.awakeDefaultMinutes) private var awakeMinutes = 60
    @AppStorage(Pref.awakeKeepScreenOn) private var awakeScreenOn = true
    @AppStorage(Pref.awakeWhileCharging) private var awakeCharging = false

    /// The snapshot tool can't draw scroll views, so it turns this off.
    static var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if Self.scrolls {
                ScrollView(.vertical) { columns }.scrollIndicators(.never)
            } else {
                columns
            }
        }
        .onAppear { state.launchAtLogin = LoginItem.isEnabled }
    }

    private var columns: some View {
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 14) {
                        group("Pages") {
                            SwitchRow(title: "Music", symbol: "music.note", isOn: $showMusic)
                            SwitchRow(title: "Calendar", symbol: "calendar", isOn: $pageCalendar)
                            SwitchRow(title: "Timer", symbol: "timer", isOn: $pageTimer)
                            SwitchRow(title: "Notes", symbol: "note.text", isOn: $pageNotes)
                        }
                        group("Indicators") {
                            SwitchRow(title: "Volume", symbol: "speaker.wave.2.fill", isOn: $showVolume)
                            SwitchRow(title: "Brightness", symbol: "sun.max.fill", isOn: $showBrightness)
                            SwitchRow(title: "Charging and low battery", symbol: "battery.75percent", isOn: $showBattery)
                        }
                        group("Behavior") {
                            SwitchRow(title: "Open on hover", symbol: "cursorarrow.motionlines", isOn: $openOnHover)
                            SwitchRow(title: "Trackpad tick", symbol: "hand.tap", isOn: $haptics)
                            SwitchRow(title: "Show on other displays", symbol: "display.2", isOn: $showOnOtherDisplays)
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 14) {
                        group("Animation") {
                            ForEach(IslandAnimation.allCases) { a in
                                ChoiceRow(title: a.title, detail: a.detail, selected: animation == a.rawValue) {
                                    animation = a.rawValue
                                    model.replaySettings() // show it straight away
                                }
                            }
                        }
                        group("Updates") { updatesRow }
                        group("Stay awake") {
                            HStack(spacing: 9) {
                                Image(systemName: "cup.and.saucer")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryText).frame(width: 16)
                                Text("Default length").font(.system(size: 12.5)).foregroundStyle(.white)
                                Spacer(minLength: 8)
                                Menu {
                                    ForEach(AwakeStore.lengths, id: \.self) { m in
                                        Button(m == 0 ? "Until I turn it off" : describeAwakeLength(minutes: m)) { awakeMinutes = m }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(awakeMinutes == 0 ? "Until off" : describeAwakeLength(minutes: awakeMinutes))
                                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                    }
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10).frame(height: 21)
                                    .background(Capsule().fill(Color(white: 0.2)))
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                            .frame(height: 24)
                            SwitchRow(title: "Keep the screen on too", symbol: "display", isOn: $awakeScreenOn)
                            SwitchRow(title: "Stay awake while charging", symbol: "bolt.fill", isOn: $awakeCharging)
                        }
                        group("General") {
                            SwitchRow(title: "Open at login", symbol: "power", isOn: $state.launchAtLogin)
                                .onChange(of: state.launchAtLogin) { _, value in
                                    LoginItem.set(value)
                                    state.launchAtLogin = LoginItem.isEnabled
                                }
                            SwitchRow(title: "Squeeze menu bar icons", symbol: "menubar.rectangle", isOn: $hideIcons)
                                .onChange(of: hideIcons) { _, value in state.onHideIconsChanged?(value) }
                            HStack(spacing: 8) {
                                Button("Quit Ledge") { NSApp.terminate(nil) }
                                    .buttonStyle(PillButtonStyle(prominent: false))
                                Spacer()
                                Button("Done") { model.closeSettings() }
                                    .buttonStyle(PillButtonStyle(prominent: true))
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Label("Settings", systemImage: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: model.style == .notch ? model.notch.width + 12 : 12)
            Button { model.closeSettings() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(white: 0.2)))
            }
            .buttonStyle(PressScaleStyle())
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .frame(height: model.style == .notch ? model.notch.height : IslandLayout.floatingTopBar)
        .padding(.top, model.style == .notch ? 0 : 2)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color(white: 0.45))
                .padding(.bottom, 2)
            content()
        }
    }

    @ViewBuilder private var updatesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ledge \(Updater.versionText)")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                    updateStatus
                }
                Spacer(minLength: 6)
                switch updater.state {
                case .available:
                    Button("Update") { updater.update() }.buttonStyle(PillButtonStyle(prominent: true))
                case .checking, .updating:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check") { updater.check() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            if case let .available(changes) = updater.state {
                ForEach(changes.prefix(3), id: \.self) {
                    Text("• \($0)").font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var updateStatus: some View {
        let text: String? = {
            switch updater.state {
            case .idle: return nil
            case .checking: return "Checking…"
            case .upToDate: return "You have the latest version"
            case let .available(c): return "\(c.count) \(c.count == 1 ? "change" : "changes") available"
            case .updating: return "Updating… Ledge restarts in a minute"
            case let .failed(why): return why
            }
        }()
        if let text {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle({ if case .available = updater.state { return Theme.green }; if case .failed = updater.state { return Theme.amber }; return Theme.secondaryText }())
                .lineLimit(2)
        }
    }
}

// MARK: - Island-style controls

/// A row with an icon, a label and an iOS-style switch.
struct SwitchRow: View {
    var title: String
    var symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            IslandSwitch(isOn: $isOn)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.quick) { isOn.toggle() } }
    }
}

struct IslandSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Theme.green : Color(white: 0.24))
            Circle().fill(Color.white).padding(2)
        }
        .frame(width: 32, height: 19)
        .animation(Theme.quick, value: isOn)
        .contentShape(Capsule())
        .onTapGesture { isOn.toggle() }
    }
}

/// A selectable row with a round marker, a title and a short description.
struct ChoiceRow: View {
    var title: String
    var detail: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle().stroke(selected ? Theme.green : Color(white: 0.35), lineWidth: 1.5)
                    if selected { Circle().fill(Theme.green).padding(3.5) }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.white : Color(white: 0.2)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
