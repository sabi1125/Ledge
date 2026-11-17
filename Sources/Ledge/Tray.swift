import AppKit
import LedgeCore
import Quartz
import QuickLookThumbnailing
import SwiftUI

// MARK: - Store

/// A file or folder held in the tray. The tray only points at it: the file stays where it is.
struct TrayItem: Identifiable, Equatable {
    let url: URL
    let isFolder: Bool
    /// "1.2 MB · PDF document · from Downloads"
    let detail: String
    var id: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path) }
}

/// Up to 5 files or folders you dropped on the island, kept until you remove them (they're
/// remembered across launches). Hidden by default: ⌃⌥F shows the tray under the open page.
@MainActor
final class TrayStore: ObservableObject {
    static let shared = TrayStore()
    private static let key = "trayItems"

    /// Newest first.
    @Published private(set) var items: [TrayItem] = []
    /// The strip under the open page. Hidden at launch, and again whenever the island closes.
    @Published var isShown = false

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        items = paths.compactMap { Self.item(for: URL(fileURLWithPath: $0)) }
    }

    var files: Int { items.filter { !$0.isFolder }.count }
    var folders: Int { items.count - files }
    var holdingText: String { TrayText.holding(files: files, folders: folders) }

    static func item(for url: URL) -> TrayItem? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .localizedTypeDescriptionKey])
        let isFolder = v?.isDirectory == true && v?.isPackage != true
        var parts: [String] = []
        if isFolder {
            let n = (try? fm.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
            parts.append(n == 1 ? "1 item" : "\(n) items")
        } else if let size = v?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let kind = v?.localizedTypeDescription { parts.append(kind) }
        parts.append("from " + fm.displayName(atPath: url.deletingLastPathComponent().path))
        return TrayItem(url: url.standardizedFileURL, isFolder: isFolder, detail: parts.joined(separator: " · "))
    }

    /// Adds all of them, or none if they don't fit (no half drops). Ones already held are skipped.
    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        prune()
        var seen = Set(items.map(\.id))
        let fresh = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        if fresh.isEmpty { return !urls.isEmpty }
        guard TrayText.fits(adding: fresh.count, held: items.count) else { return false }
        items.insert(contentsOf: fresh.compactMap(Self.item(for:)), at: 0)
        save()
        LedgeLog.shared.write("tray: holding \(items.count)")
        return true
    }

    func remove(_ item: TrayItem) {
        items.removeAll { $0.id == item.id }
        afterRemoving()
    }

    func clear() {
        items = []
        afterRemoving()
    }

    /// Drops items whose file was moved away or deleted.
    func prune() {
        let kept = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard kept.count != items.count else { return }
        items = kept
        afterRemoving()
    }

    private func afterRemoving() {
        // Empty, there's no tray: the next time it's holding something it starts hidden again.
        if items.isEmpty { isShown = false }
        save()
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: Self.key)
    }

    func open(_ item: TrayItem) { NSWorkspace.shared.open(item.url) }
    func showInFinder(_ item: TrayItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func quickLook(_ item: TrayItem) { TrayQuickLook.shared.show(item.url) }
}

/// The system Quick Look window for one tray item.
final class TrayQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = TrayQuickLook()
    private var url: URL?

    @MainActor func show(_ url: URL) {
        self.url = url
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let url else { return nil }
        return url as NSURL
    }
}

/// What's being dragged toward the island right now.
struct FileDrag: Equatable {
    var files: Int
    var folders: Int
    /// The pointer is over the drop target ("let go now").
    var over = false
}

// MARK: - Views

/// A real thumbnail for images, PDFs and the like; the Finder icon for everything else.
struct TrayThumb: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                           scale: 2, representationTypes: .thumbnail)
                if let t = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    image = t.nsImage
                }
            }
    }
}

/// The dashed box files are dropped into: in the closed island's drop target, and where the
/// tray sits on the open island. Amber when they won't fit.
struct TrayDropBox: View {
    var drag: FileDrag
    var held: Int
    var radius: CGFloat = 12

    var body: some View {
        let n = drag.files + drag.folders
        let fits = TrayText.fits(adding: n, held: held)
        let hot = drag.over && fits
        let color: Color = !fits ? Theme.amber : (hot ? .white : Theme.secondaryText)
        let box = RoundedRectangle(cornerRadius: radius, style: .continuous)
        HStack(spacing: 7) {
            Image(systemName: "tray").font(.system(size: 12, weight: .semibold))
            Text(TrayText.dropTitle(files: drag.files, folders: drag.folders, held: held, over: drag.over))
                .font(.system(size: 12.5, weight: .semibold))
            if let detail = TrayText.dropDetail(files: drag.files, folders: drag.folders, held: held, over: drag.over) {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(box.fill(Color.white.opacity(hot ? 0.07 : 0)))
        .overlay(box.strokeBorder(!fits ? Theme.amber.opacity(0.55) : Color.white.opacity(hot ? 0.45 : 0.22),
                                  style: StrokeStyle(lineWidth: 1, dash: hot ? [] : [4, 3])))
        .animation(.easeOut(duration: 0.15), value: drag)
    }
}

/// The closed island grown into a drop target (shape `.drop`).
struct DropTargetView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var tray: TrayStore = .shared

    var body: some View {
        let notch = model.style == .notch
        VStack(spacing: 0) {
            if notch { Color.clear.frame(height: model.notch.height) }
            TrayDropBox(drag: model.fileDrag ?? FileDrag(files: 1, folders: 0), held: tray.items.count)
                .padding(.horizontal, 16)
                .padding(.top, notch ? 8 : 12)
                .padding(.bottom, notch ? 14 : 12)
        }
    }
}

/// The strip under the open page: what it holds on the left, the items on the right. While
/// files are dragged over the island, the drop box takes its place.
struct TrayStrip: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var tray: TrayStore = .shared
    @State private var hovered: String?

    var body: some View {
        Group {
            if let drag = model.fileDrag {
                TrayDropBox(drag: drag, held: tray.items.count, radius: 10)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
            } else {
                row
            }
        }
        .frame(height: IslandLayout.trayHeight)
        .animation(.easeOut(duration: 0.18), value: model.fileDrag == nil)
    }

    private var row: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "tray").font(.system(size: 11, weight: .semibold))
                Text(tray.holdingText).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Hide Tray (⌃⌥F)") { tray.isShown = false }
                Divider()
                Button("Clear All") { tray.clear() }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(tray.items) { item in
                    TrayIcon(item: item, tray: tray, hovered: $hovered)
                }
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 22)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                .padding(.leading, 24).padding(.trailing, 22)
        }
    }
}

/// One item: thumbnail card, × on hover, the tooltip right away (no delay), drag it out to use it.
struct TrayIcon: View {
    let item: TrayItem
    @ObservedObject var tray: TrayStore
    @Binding var hovered: String?

    var body: some View {
        let isHovered = hovered == item.id
        let card = RoundedRectangle(cornerRadius: 7, style: .continuous)
        TrayThumb(url: item.url, size: 24)
            .frame(width: 30, height: 30)
            .background(card.fill(Color.white.opacity(isHovered ? 0.13 : 0.07)))
            .overlay(card.strokeBorder(Color.white.opacity(isHovered ? 0.22 : 0), lineWidth: 0.5))
            .contentShape(card)
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button { tray.remove(item) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color(white: 0.23)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: -5, y: -5)
                    .help("Remove from tray")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isHovered {
                    TrayTooltip(item: item)
                        .fixedSize()
                        .offset(x: 8, y: -38)
                        .allowsHitTesting(false)
                }
            }
            .onHover { inside in
                if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
            }
            .onTapGesture(count: 2) { tray.open(item) }
            // A copy goes out: the item stays in the tray until you remove it.
            .onDrag { NSItemProvider(object: item.url as NSURL) }
            .contextMenu {
                Button("Quick Look") { tray.quickLook(item) }
                Button("Open") { tray.open(item) }
                Button("Show in Finder") { tray.showInFinder(item) }
                Divider()
                Button("Remove from Tray") { tray.remove(item) }
                Button("Clear All") { tray.clear() }
            }
    }
}

struct TrayTooltip: View {
    let item: TrayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TrayText.shortName(item.name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text("Drag out to use · double-click opens · right-click for more")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(white: 0.45))
                .padding(.top, 3)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.15)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }
}

/// Beside the page dots while the tray is hidden but holding something: a tray and the count.
struct TrayGlyph: View {
    @ObservedObject var tray: TrayStore = .shared

    var body: some View {
        Button { tray.isShown = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "tray").font(.system(size: 10, weight: .semibold))
                Text("\(tray.items.count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 5)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tray.holdingText) (⌃⌥F to show)")
        .contextMenu { Button("Clear All") { tray.clear() } }
    }
}
