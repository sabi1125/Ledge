import AppKit
import LedgeCore
import SwiftUI

/// The black island outline: a rounded-bottom rectangle with small outward
/// "shoulders" at the top corners, like the real notch.
struct IslandOutline: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set { bottomRadius = newValue.first; shoulder = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
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
    var openSettings: () -> Void

    var body: some View {
        let shape = model.shape
        let size = IslandLayout.size(for: shape, notch: model.notch)
        let shoulder = IslandLayout.shoulderRadius(for: shape)
        let outline = IslandOutline(bottomRadius: IslandLayout.bottomRadius(for: shape, notch: model.notch),
                                    shoulder: shoulder)

        ZStack(alignment: .top) {
            // At rest the real notch is enough: draw nothing, so the island can never show up
            // on its own (e.g. over a window being moved). It fades in as it grows out of the notch.
            outline.fill(Color.black)
                .opacity(model.showsFill ? 1 : 0)
                .animation(nil, value: model.showsFill) // switch instantly, never fade
            // Content is laid out at its own full size and never resized during the animation:
            // the black shape opens and closes over it like a window, so nothing squishes.
            content
        }
        .frame(width: size.width + shoulder * 2, height: size.height)
        .clipShape(outline)
        .contentShape(outline)
        .shadow(color: .black.opacity(shape == .expanded ? 0.5 : 0), radius: 16, y: 6)
        .onTapGesture { model.clicked() }
        .contextMenu {
            Button("Ledge Settings…", action: openSettings)
            Divider()
            Button("Quit Ledge") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(shape == .hud ? Theme.pop : Theme.spring, value: shape)
        .environment(\.colorScheme, .dark)
    }

    private static let fade = AnyTransition.asymmetric(
        insertion: .opacity.animation(Theme.contentIn),
        removal: .opacity.animation(Theme.contentOut))

    @ViewBuilder private var content: some View {
        switch model.shape {
        // Content only fades (no scaling), so the shape itself carries the motion.
        case .compact:
            CompactView(model: model)
                .fixedFrame(for: .compact, notch: model.notch)
                .transition(Self.fade)
        case .hud:
            if let hud = model.hud {
                HUDView(hud: hud, notch: model.notch)
                    .fixedFrame(for: .hud, notch: model.notch)
                    .transition(Self.fade)
            }
        case .expanded:
            ExpandedView(model: model, calendar: calendar, notes: notes)
                .fixedFrame(for: .expanded, notch: model.notch)
                .transition(Self.fade)
        case .idle, .hover:
            Color.clear
        }
    }
}

private extension View {
    /// Pins a view to the full size of its island shape, whatever size the animating shape is.
    func fixedFrame(for shape: IslandShape, notch: NotchMetrics) -> some View {
        let s = IslandLayout.size(for: shape, notch: notch)
        return frame(width: s.width, height: s.height, alignment: .top)
    }
}

// MARK: - Compact (music playing)

struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: model.artwork, size: 22, radius: 6)
            Spacer(minLength: model.notch.width)
            WaveformView(color: model.tint, playing: model.media.isPlaying)
                .frame(width: 22, height: 14)
        }
        .padding(.horizontal, 10)
        .frame(height: model.notch.height)
    }
}

// MARK: - Expanded player

struct PlayerView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkView(image: model.artwork, size: 56, radius: 12)
                        .shadow(color: model.tint.opacity(0.35), radius: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.media.title ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    WaveformView(color: model.tint, playing: model.media.isPlaying)
                        .frame(width: 26, height: 18)
                }
                ProgressRow(model: model)
                ControlsRow(model: model)
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
    }

    private var subtitle: String {
        let artist = model.media.artist ?? ""
        if !artist.isEmpty { return artist }
        return model.media.album ?? ""
    }
}

struct ProgressRow: View {
    @ObservedObject var model: IslandModel
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
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

/// Volume, brightness and battery: a row that drops down below the notch.
struct HUDView: View {
    var hud: HUD
    var notch: NotchMetrics

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height) // the camera area
            row
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .frame(height: IslandLayout.hudBody - 4)
                .foregroundStyle(.white)
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
        }
    }

    private func levelRow(symbol: String, level: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            LevelBar(level: level).frame(height: 6)
            Text("\(Int((level * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(width: 26, alignment: .trailing)
        }
    }

    private func statusRow(symbol: String, title: String, percent: Int, battery: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 8)
            Text("\(percent)%").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            Image(systemName: battery).font(.system(size: 14))
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
        .animation(Theme.quick, value: level)
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
/// Driven by a timeline (not a repeating animation), so pausing and playing
/// can never leave the bars frozen.
struct WaveformView: View {
    var color: Color
    var playing: Bool

    private let speeds: [Double] = [7.1, 9.3, 6.2, 8.4, 7.7]
    private let offsets: [Double] = [0, 1.3, 2.1, 0.7, 2.8]
    private let rests: [CGFloat] = [0.3, 0.45, 0.25, 0.4, 0.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.6)
                        .scaleEffect(x: 1, y: playing ? level(i, t) : rests[i], anchor: .center)
                }
            }
            .animation(.easeOut(duration: 0.25), value: playing)
        }
    }

    private func level(_ i: Int, _ t: Double) -> CGFloat {
        // Two mixed waves per bar so the motion doesn't look mechanical.
        let a = sin(t * speeds[i] + offsets[i])
        let b = sin(t * speeds[i] * 0.53 + offsets[i] * 1.7)
        return CGFloat(0.55 + 0.3 * a + 0.15 * b).clamped(to: 0.2...1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
