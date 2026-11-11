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
/// folder, or a right-click on the island). A sidebar of sections on the left, one section on the right.
struct SettingsPanel: View {
    enum Section: String, CaseIterable, Identifiable {
        case pages, indicators, animation, pomodoro, awake, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pages: return "Pages"
            case .indicators: return "Indicators"
            case .animation: return "Animation"
            case .pomodoro: return "Pomodoro"
            case .awake: return "Stay awake"
            case .general: return "General"
            }
        }
        var symbol: String {
            switch self {
            case .pages: return "rectangle.stack"
            case .indicators: return "speaker.wave.2"
            case .animation: return "sparkles"
            case .pomodoro: return "target"
            case .awake: return "cup.and.saucer"
            case .general: return "slider.horizontal.3"
            }
        }
    }

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
    // Animation
    @AppStorage(IslandAnimation.key) private var animation = IslandAnimation.calm.rawValue
    // Stay awake
    @AppStorage(Pref.awakeDefaultMinutes) private var awakeMinutes = 60
    @AppStorage(Pref.awakeKeepScreenOn) private var awakeScreenOn = true
    @AppStorage(Pref.awakeWhileCharging) private var awakeCharging = false
    // Pomodoro
    @AppStorage(Pref.pomoFocus) private var pomoFocus = 25
    @AppStorage(Pref.pomoShort) private var pomoShort = 5
    @AppStorage(Pref.pomoLong) private var pomoLong = 15
    @AppStorage(Pref.pomoSessions) private var pomoSessions = 4
    @AppStorage(Pref.pomoAutoStart) private var pomoAutoStart = true

    @State private var section: Section = SettingsPanel.startSection
    @Namespace private var highlight

    /// The snapshot tool can't draw scroll views, so it turns this off.
    static var scrolls = true
    /// Which section opens first (the snapshot tool draws each one).
    static var startSection: Section = .pages

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 18) {
                sidebar
                Group {
                    if Self.scrolls {
                        ScrollView(.vertical) { detail }.scrollIndicators(.never)
                    } else {
                        detail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.leading, 14)
            .padding(.trailing, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .onAppear { state.launchAtLogin = LoginItem.isEnabled }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { s in
                Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { section = s } } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                        Text(s.title).font(.system(size: 12.5, weight: section == s ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == s ? Color.white : Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background {
                        // One highlight that slides to the chosen section.
                        if section == s {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(white: 0.14))
                                .matchedGeometryEffect(id: "section", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 150)
    }

    // MARK: Sections

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color(white: 0.45))
                .padding(.leading, 4)
            switch section {
            case .pages:
                Card {
                    SwitchRow(title: "Music", symbol: "music.note", isOn: $showMusic)
                    CardDivider()
                    SwitchRow(title: "Calendar", symbol: "calendar", isOn: $pageCalendar)
                    CardDivider()
                    SwitchRow(title: "Timer", symbol: "timer", isOn: $pageTimer)
                    CardDivider()
                    SwitchRow(title: "Notes", symbol: "note.text", isOn: $pageNotes)
                }
                hint("Swipe with two fingers on the open island to switch pages.")
            case .indicators:
                Card {
                    SwitchRow(title: "Volume", symbol: "speaker.wave.2.fill", isOn: $showVolume)
                    CardDivider()
                    SwitchRow(title: "Brightness", symbol: "sun.max.fill", isOn: $showBrightness)
                    CardDivider()
                    SwitchRow(title: "Charging and low battery", symbol: "battery.75percent", isOn: $showBattery)
                }
                hint("Shown in the island instead of the macOS pop-ups.")
            case .animation:
                animationGrid
                hint("Tap one to see it right away.")
            case .pomodoro:
                Card {
                    ChoiceRow2(title: "Focus", symbol: "target", value: $pomoFocus,
                               options: [15, 20, 25, 30, 45, 50, 60]) { "\($0) min" }
                    CardDivider()
                    ChoiceRow2(title: "Short break", symbol: "leaf", value: $pomoShort,
                               options: [3, 5, 10, 15]) { "\($0) min" }
                    CardDivider()
                    ChoiceRow2(title: "Long break", symbol: "leaf.fill", value: $pomoLong,
                               options: [10, 15, 20, 25, 30]) { "\($0) min" }
                    CardDivider()
                    ChoiceRow2(title: "Sessions before a long break", symbol: "circle.grid.2x2", value: $pomoSessions,
                               options: [2, 3, 4, 5, 6]) { "\($0)" }
                }
                Card {
                    SwitchRow(title: "Start the next phase by itself", symbol: "arrow.forward.circle", isOn: $pomoAutoStart)
                }
            case .awake:
                Card {
                    ChoiceRow2(title: "Default length", symbol: "cup.and.saucer", value: $awakeMinutes,
                               options: AwakeStore.lengths,
                               menuLabel: { $0 == 0 ? "Until I turn it off" : describeAwakeLength(minutes: $0) }) {
                        $0 == 0 ? "Until off" : describeAwakeLength(minutes: $0)
                    }
                    CardDivider()
                    SwitchRow(title: "Keep the screen on too", symbol: "display", isOn: $awakeScreenOn)
                    CardDivider()
                    SwitchRow(title: "Stay awake while charging", symbol: "bolt.fill", isOn: $awakeCharging)
                }
                hint("Click the cup in the open island to start or stop.")
            case .general:
                Card {
                    SwitchRow(title: "Open at login", symbol: "power", isOn: $state.launchAtLogin)
                        .onChange(of: state.launchAtLogin) { _, value in
                            LoginItem.set(value)
                            state.launchAtLogin = LoginItem.isEnabled
                        }
                    CardDivider()
                    SwitchRow(title: "Open on hover", symbol: "cursorarrow.motionlines", isOn: $openOnHover)
                    CardDivider()
                    SwitchRow(title: "Trackpad tick", symbol: "hand.tap", isOn: $haptics)
                    CardDivider()
                    SwitchRow(title: "Show on other displays", symbol: "display.2", isOn: $showOnOtherDisplays)
                }
                Card { updatesRow.padding(.vertical, 8) }
                Button("Quit Ledge") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 4)
            }
        }
        .id(section)
        .transition(IslandAnimation.swap)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color(white: 0.45))
            .padding(.leading, 4)
    }

    private var animationGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(IslandAnimation.allCases) { a in
                let selected = animation == a.rawValue
                Button {
                    animation = a.rawValue
                    model.replaySettings() // show it straight away
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        Text(a.detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(Theme.green)
                                .padding(10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.075)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.green.opacity(0.8) : .clear, lineWidth: 1.2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
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

    @ViewBuilder private var updatesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ledge \(Updater.versionText)")
                        .font(.system(size: 12.5)).foregroundStyle(.white)
                    updateStatus
                }
                Spacer(minLength: 6)
                switch updater.state {
                case .available:
                    Button("Update") { updater.update() }.buttonStyle(PillButtonStyle(prominent: true))
                case .checking, .updating:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check for updates") { updater.check() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            if case let .available(changes) = updater.state {
                ForEach(changes.prefix(3), id: \.self) {
                    Text("• \($0)").font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        .padding(.leading, 25)
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

/// A soft dark card that groups a few rows.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.075)))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 25)
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
        .frame(height: 34)
        // Only the switch itself flips the setting, so a stray click on the row can't.
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

/// A row with an icon, a label and a pill that opens a short list of choices.
struct ChoiceRow2: View {
    var title: String
    var symbol: String
    @Binding var value: Int
    var options: [Int]
    /// The text in the drop-down list (defaults to the pill's text).
    var menuLabel: ((Int) -> String)? = nil
    var label: (Int) -> String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            Text(title).font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.self) { o in Button((menuLabel ?? label)(o)) { value = o } }
            } label: {
                HStack(spacing: 4) {
                    Text(label(value))
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
        .frame(height: 34)
    }
}
