import AppKit
import LedgeCore
import SwiftUI

/// The black island outline. On the notch: a rounded-bottom rectangle with small outward
/// "shoulders" at the top corners, like the real notch. Floating (no shoulders): a pill or
/// rounded card with its own top-corner radius.
struct IslandOutline: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(bottomRadius, shoulder), topRadius) }
        set { bottomRadius = newValue.first.first; shoulder = newValue.first.second; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if shoulder < 0.5 {
            let limit = min(rect.height / 2, rect.width / 2)
            return UnevenRoundedRectangle(topLeadingRadius: min(topRadius, limit),
                                          bottomLeadingRadius: min(bottomRadius, limit),
                                          bottomTrailingRadius: min(bottomRadius, limit),
                                          topTrailingRadius: min(topRadius, limit),
                                          style: .continuous).path(in: rect)
        }
        let s = shoulder
        let r = max(0, min(bottomRadius, rect.height / 2, (rect.width - 2 * s) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s),
                       control: CGPoint(x: rect.minX + s, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.minX + s, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - s, y: rect.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.maxX - s, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - s, y: rect.minY + s), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - s, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    var calendar: CalendarStore
    var notes: NotesStore
    var timer: TimerStore
    var awake: AwakeStore
    var settings: SettingsState
    var updater: Updater
    var openSettings: () -> Void

    /// The island's current, on-screen geometry. Each part animates on its own clock, so a
    /// style can move width and height at different times (SwiftUI would otherwise merge them).
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var bottomRadius: CGFloat = 10
    @State private var topRadius: CGFloat = 0
    @State private var shoulder: CGFloat = 6
    @State private var didAppear = false

    private var target: IslandGeometry {
        let shape = model.shape, style = model.style
        let size = IslandLayout.size(for: shape, notch: model.notch, style: style, compactWidth: model.compactWidth)
        return IslandGeometry(width: size.width, height: size.height,
                              bottomRadius: IslandLayout.bottomRadius(for: shape, notch: model.notch, style: style),
                              topRadius: IslandLayout.topRadius(for: shape, notch: model.notch, style: style),
                              shoulder: IslandLayout.shoulderRadius(for: shape, style: style))
    }

    var body: some View {
        let shape = model.shape
        let style = model.style
        let goal = target
        // Until the first layout, draw at the target size.
        let w = didAppear ? width : goal.width
        let h = didAppear ? height : goal.height
        let outline = IslandOutline(bottomRadius: didAppear ? bottomRadius : goal.bottomRadius,
                                    shoulder: didAppear ? shoulder : goal.shoulder,
                                    topRadius: didAppear ? topRadius : goal.topRadius)
        let s = didAppear ? shoulder : goal.shoulder

        ZStack(alignment: .top) {
            // At rest the real notch is enough: draw nothing, so the island can never show up
            // on its own (e.g. over a window being moved).
            outline.fill(Color.black)
                .opacity(model.showsFill ? 1 : 0)
                .animation(nil, value: model.showsFill) // switch instantly, never fade
            // Content is laid out at its own full size and never resized during the animation:
            // the black shape opens and closes over it like a window, so nothing squishes.
            content
        }
        .frame(width: w + s * 2, height: h)
        .clipShape(outline)
        .contentShape(outline)
        .shadow(color: .black.opacity(shape == .expanded || shape == .settings ? 0.5 : 0), radius: 16, y: 6)
        .onTapGesture { model.clicked() }
        .contextMenu {
            Button("Ledge Settings…", action: openSettings)
            Divider()
            Button("Quit Ledge") { NSApp.terminate(nil) }
        }
        .padding(.top, IslandLayout.topGap(style: style))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { move(to: goal, from: nil) }
        .onChange(of: goal) { old, new in move(to: new, from: old) }
    }

    /// Animates the shape to its new size in the chosen style.
    private func move(to new: IslandGeometry, from old: IslandGeometry?) {
        guard let old, didAppear else {
            width = new.width; height = new.height
            bottomRadius = new.bottomRadius; topRadius = new.topRadius; shoulder = new.shoulder
            didAppear = true
            return
        }
        let growing = new.width * new.height >= old.width * old.height
        let style = IslandAnimation.current
        let isHUD = model.shape == .hud || (!growing && old.height > new.height && model.hud != nil)
        // Closing: let the content fade out first, so the shape only ever closes over empty black.
        let lead = growing ? 0 : 0.09
        let widthAnimation = (isHUD ? Theme.pop : style.width(growing: growing)).delay(lead)
        let heightAnimation = (isHUD ? Theme.pop : style.height(growing: growing)).delay(lead)
        // The top-corner shoulders belong to the width (so a narrowing island is never wider
        // than the notch); the bottom corners belong to the height.
        withAnimation(widthAnimation) {
            width = new.width
            shoulder = new.shoulder
        }
        withAnimation(heightAnimation) {
            height = new.height
            bottomRadius = new.bottomRadius
            topRadius = new.topRadius
        }
    }

    /// Content only fades in and out (never scales), in the chosen animation style.
    private static var fade: AnyTransition { IslandAnimation.current.content }

    @ViewBuilder private var content: some View {
        switch model.shape {
        // Content only fades (no scaling), so the shape itself carries the motion.
        case .compact:
            CompactView(model: model, timer: timer)
                .fixedFrame(for: .compact, model: model)
                .transition(Self.fade)
        case .hud:
            if let hud = model.hud {
                HUDView(hud: hud, notch: model.notch, style: model.style)
                    .fixedFrame(for: .hud, model: model)
                    .transition(Self.fade)
            }
        case .expanded:
            ExpandedView(model: model, calendar: calendar, notes: notes, timer: timer, awake: awake)
                .fixedFrame(for: .expanded, model: model)
                .transition(Self.fade)
        case .settings:
            SettingsPanel(model: model, state: settings, updater: updater)
                .fixedFrame(for: .settings, model: model)
                .transition(Self.fade)
        case .idle, .hover:
            Color.clear
        }
    }
}

private extension View {
    /// Pins a view to the full size of its island shape, whatever size the animating shape is.
    func fixedFrame(for shape: IslandShape, model: IslandModel) -> some View {
        let s = IslandLayout.size(for: shape, notch: model.notch, style: model.style, compactWidth: model.compactWidth)
        return frame(width: s.width, height: s.height, alignment: .top)
    }
}

/// The island's size and corner shape, as a value SwiftUI can watch for changes.
struct IslandGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var shoulder: CGFloat
}

// MARK: - Compact (music playing)

struct CompactView: View {
    @ObservedObject var model: IslandModel
    var timer: TimerStore

    /// Music is showing (otherwise this view is here for the timer alone).
    private var musicShowing: Bool { model.hasMedia && model.media.isPlaying }

    var body: some View {
        if model.style == .floating {
            // No camera in the way, so the song name fits in the middle.
            let h = model.notch.height
            let m = IslandLayout.floatingCompactMetrics(height: h)
            HStack(spacing: m.gap) {
                if musicShowing {
                    ArtworkView(image: model.artwork, size: m.art, radius: m.art * 0.3)
                } else {
                    TimerBadge(size: m.art, timer: timer)
                }
                songLine
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.timerActive {
                    CountdownLabel(timer: timer, size: model.pillFontSize)
                } else {
                    WaveformView(color: model.tint, playing: model.media.isPlaying)
                        .frame(width: m.bars, height: h * 0.42)
                }
            }
            // Art and bars sit well inside the pill's round ends.
            .padding(.leading, m.leading)
            .padding(.trailing, m.trailing)
            .frame(height: h)
        } else {
            HStack(spacing: 0) {
                if musicShowing {
                    ArtworkView(image: model.artwork, size: 22, radius: 6)
                } else {
                    TimerBadge(size: 22, timer: timer)
                }
                Spacer(minLength: model.notch.width)
                if model.timerActive {
                    CountdownLabel(timer: timer, size: 12)
                } else {
                    WaveformView(color: model.tint, playing: model.media.isPlaying)
                        .frame(width: 22, height: 14)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: model.notch.height)
        }
    }

    /// Title in white, artist in gray.
    private var songLine: Text {
        let size = model.pillFontSize
        guard musicShowing else {
            return Text(timer.live?.title ?? "Timer").font(.system(size: size, weight: .semibold)).foregroundColor(.white)
        }
        let title = Text(model.media.title ?? "")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(.white)
        guard let artist = model.media.artist, !artist.isEmpty else { return title }
        return title + Text("  \(artist)")
            .font(.system(size: size, weight: .regular))
            .foregroundColor(Theme.secondaryText)
    }
}

/// The timer's (or pomodoro phase's) icon, in place of album art when only it is running.
struct TimerBadge: View {
    var size: CGFloat
    @ObservedObject var timer: TimerStore
    var body: some View {
        Image(systemName: timer.live?.symbol ?? "timer")
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(timer.live?.color ?? Theme.timerOrange)
            .frame(width: size, height: size)
    }
}

// MARK: - Expanded player

struct PlayerView: View {
    @ObservedObject var model: IslandModel

    /// Big art on the left; song, progress and controls in one column beside it,
    /// so the wide island has no empty stretches.
    private let art: CGFloat = 104

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ArtworkView(image: model.artwork, size: art, radius: 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.media.title ?? "")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    WaveformView(color: model.tint, playing: model.media.isPlaying)
                        .frame(width: 24, height: 16)
                        .padding(.top, 3)
                }
                Spacer(minLength: 6)
                ProgressRow(model: model)
                Spacer(minLength: 4)
                ControlsRow(model: model)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: art)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var subtitle: String {
        let artist = model.media.artist ?? ""
        if !artist.isEmpty { return artist }
        return model.media.album ?? ""
    }
}

struct ProgressRow: View {
    @ObservedObject var model: IslandModel
    @Environment(\.isVisiblePage) private var visible
    @State private var dragFraction: Double?

    var body: some View {
        // Ticks only while it's on screen and the song is playing.
        TimelineView(.animation(minimumInterval: 0.5, paused: !(visible && model.media.isPlaying))) { context in
            let duration = model.media.duration
            let fraction = dragFraction ?? model.media.progress(at: context.date)
            let elapsed = duration > 0 ? fraction * duration : model.media.elapsed(at: context.date)
            HStack(spacing: 8) {
                Text(formatTime(elapsed))
                    .frame(width: 34, alignment: .leading)
                ScrubBar(fraction: fraction, enabled: duration > 0) { value in
                    dragFraction = value
                } onEnd: { value in
                    dragFraction = nil
                    model.onCommand?(.seek(value * duration))
                }
                Text(duration > 0 ? "-" + formatTime(max(0, duration - elapsed)) : "")
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
    }
}

struct ScrubBar: View {
    var fraction: Double
    var enabled: Bool
    var onDrag: (Double) -> Void
    var onEnd: (Double) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Color.white.opacity(0.92))
                    .frame(width: max(0, min(1, fraction)) * w)
            }
            .frame(height: hovering ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in if enabled { onDrag(max(0, min(1, v.location.x / w))) } }
                    .onEnded { v in if enabled { onEnd(max(0, min(1, v.location.x / w))) } }
            )
        }
        .frame(height: 14)
        .onHover { h in withAnimation(Theme.quick) { hovering = h } }
    }
}

struct ControlsRow: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 40) {
            IconButton(symbol: "backward.fill", size: 17) { model.onCommand?(.previous) }
            IconButton(symbol: model.media.isPlaying ? "pause.fill" : "play.fill", size: 23) {
                model.onCommand?(.toggle)
            }
            .frame(width: 28)
            IconButton(symbol: "forward.fill", size: 17) { model.onCommand?(.next) }
        }
        .frame(height: 26)
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 14, height: size + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

// MARK: - HUDs

/// Volume, brightness and battery: a row that drops down below the notch,
/// or fills the floating pill on other screens.
struct HUDView: View {
    var hud: HUD
    var notch: NotchMetrics
    var style: IslandStyle = .notch

    /// Text and icon sizes (smaller inside the menu-bar pill).
    private var k: CGFloat { style == .floating ? 0.85 : 1 }

    var body: some View {
        if style == .floating {
            row
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .frame(height: notch.height)
                .foregroundStyle(.white)
        } else {
            VStack(spacing: 0) {
                Color.clear.frame(height: notch.height) // the camera area
                row
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandLayout.hudBody - 4)
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private var row: some View {
        switch hud {
        case let .volume(level, muted):
            levelRow(symbol: muted ? "speaker.slash.fill" : volumeSymbol(level),
                     level: muted ? 0 : level)
        case let .brightness(level):
            levelRow(symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill", level: level)
        case let .charging(percent):
            statusRow(symbol: "bolt.fill", title: "Charging", percent: percent,
                      battery: "battery.100percent.bolt", color: Theme.green)
        case let .lowBattery(percent):
            statusRow(symbol: "exclamationmark.triangle.fill", title: "Low Battery", percent: percent,
                      battery: "battery.25percent", color: Theme.amber)
        case let .pomodoro(ended, next, minutes):
            let color = next.isBreak ? Theme.breakGreen : Theme.focusRed
            HStack(spacing: 7 * k) {
                Image(systemName: ended == .focus ? "checkmark" : "target").font(.system(size: 12 * k, weight: .bold))
                Text(ended == .focus ? "Focus done" : "Break over").font(.system(size: 12.5 * k, weight: .semibold))
                Spacer(minLength: 8)
                Text(next == .focus ? "Focus · \(minutes) min" : "Break · \(minutes) min")
                    .font(.system(size: 12.5 * k, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(color)
        case let .awakeOn(minutes):
            HStack(spacing: 7 * k) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 12 * k, weight: .semibold))
                Text("Staying awake").font(.system(size: 12.5 * k, weight: .semibold))
                Spacer(minLength: 8)
                Text(minutes > 0 ? describeAwakeLength(minutes: minutes) : "until off")
                    .font(.system(size: 12.5 * k, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.awakeOrange)
        case .awakeOff:
            HStack(spacing: 7 * k) {
                Image(systemName: "moon.fill").font(.system(size: 12 * k, weight: .semibold))
                Text("Sleep allowed again").font(.system(size: 12.5 * k, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(white: 0.75))
        case let .timerDone(duration):
            HStack(spacing: 7 * k) {
                Image(systemName: "bell.fill").font(.system(size: 12 * k, weight: .semibold))
                    .symbolEffect(.bounce, options: .repeating)
                Text("Timer done").font(.system(size: 12.5 * k, weight: .semibold))
                Spacer(minLength: 8)
                Text(formatCountdown(duration)).font(.system(size: 12.5 * k, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.timerOrange)
        }
    }

    private func levelRow(symbol: String, level: Double) -> some View {
        HStack(spacing: 10 * k) {
            Image(systemName: symbol)
                .font(.system(size: 13 * k, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20 * k)
            LevelBar(level: level).frame(height: 6 * k)
            Text("\(Int((level * 100).rounded()))")
                .font(.system(size: 12 * k, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(width: 26, alignment: .trailing)
        }
    }

    private func statusRow(symbol: String, title: String, percent: Int, battery: String, color: Color) -> some View {
        HStack(spacing: 7 * k) {
            Image(systemName: symbol).font(.system(size: 12 * k, weight: .semibold))
            Text(title).font(.system(size: 12.5 * k, weight: .semibold))
            Spacer(minLength: 8)
            Text("\(percent)%").font(.system(size: 12.5 * k, weight: .semibold).monospacedDigit())
            Image(systemName: battery).font(.system(size: 14 * k))
        }
        .foregroundStyle(color)
    }

    private func volumeSymbol(_ level: Double) -> String {
        switch level {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

struct LevelBar: View {
    var level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Color.white)
                    .frame(width: max(0, min(1, level)) * geo.size.width)
            }
        }
        .animation(Theme.level, value: level)
    }
}

// MARK: - Shared pieces

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(Color(white: 0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Five bars that bounce while music plays and rest when it pauses.
/// The bouncing runs in macOS's animation system on the graphics hardware (Core Animation),
/// so it costs almost no CPU, unlike redrawing the bars ourselves every frame.
struct WaveformView: NSViewRepresentable {
    var color: Color
    var playing: Bool

    func makeNSView(context: Context) -> WaveformBarsView { WaveformBarsView() }

    func updateNSView(_ view: WaveformBarsView, context: Context) {
        view.update(color: NSColor(color), playing: playing)
    }
}

final class WaveformBarsView: NSView {
    private let bars: [CALayer] = (0..<5).map { _ in CALayer() }
    private let rests: [CGFloat] = [0.3, 0.45, 0.25, 0.4, 0.35]
    private let durations: [Double] = [0.42, 0.55, 0.36, 0.5, 0.46]
    private let delays: [Double] = [0, 0.21, 0.09, 0.33, 0.15]
    private var playing: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars { layer?.addSublayer(bar) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let n = CGFloat(bars.count)
        let gap = min(2.2, bounds.width * 0.08)
        let w = max(1.5, (bounds.width - gap * (n - 1)) / n)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }

    func update(color: NSColor, playing: Bool) {
        let cg = color.cgColor
        for bar in bars where bar.backgroundColor != cg { bar.backgroundColor = cg }
        guard playing != self.playing else { return }
        self.playing = playing
        let now = CACurrentMediaTime()
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "bounce")
            if playing {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = rests[i]
                a.toValue = 1.0
                a.duration = durations[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = now + delays[i]
                a.fillMode = .backwards
                bar.add(a, forKey: "bounce")
            }
            // Resting height (also what the bars settle to when paused).
            bar.transform = CATransform3DMakeScale(1, rests[i], 1)
        }
    }
}

/// Whether a page of the open island is the one on screen (hidden pages pause their clocks).
private struct IsVisiblePageKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isVisiblePage: Bool {
        get { self[IsVisiblePageKey.self] }
        set { self[IsVisiblePageKey.self] = newValue }
    }
}
