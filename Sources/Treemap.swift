import SwiftUI
import AppKit

/// A laid-out rectangle for one node within the nested treemap.
struct TreemapTile: Identifiable {
    let id = UUID()
    let node: FileNode
    let rect: CGRect
    let depth: Int
    /// True when drawn as a solid leaf (its children are not shown inside it).
    let isLeaf: Bool
    let color: Color
}

/// Squarified, *nested* treemap layout: children are laid out inside their
/// parent's rectangle recursively, so several levels of the hierarchy are
/// visible at once.
enum TreemapLayout {
    static let maxDepth = 4                 // number of nested layers to draw
    static let headerHeight: CGFloat = 15   // strip reserved for a folder's label
    static let minNestSide: CGFloat = 46    // don't nest into rects smaller than this

    static func tiles(for node: FileNode, in bounds: CGRect) -> [TreemapTile] {
        var out: [TreemapTile] = []
        layout(childrenOf: node, in: bounds, depth: 0, into: &out)
        return out
    }

    private static func layout(childrenOf node: FileNode, in bounds: CGRect,
                               depth: Int, into out: inout [TreemapTile]) {
        guard depth < maxDepth, node.size > 0,
              let children = node.children else { return }
        let items = children.filter { $0.size > 0 }
        guard !items.isEmpty, bounds.width > 1, bounds.height > 1 else { return }

        var rects: [(FileNode, CGRect)] = []
        squarify(items, node.size, bounds, &rects)

        for (child, rect) in rects {
            // One shared color source, so the treemap and the outline agree.
            let color = NodePalette.color(for: child)
            let hasKids = child.children?.contains { $0.size > 0 } ?? false
            let nest = child.isDirectory && hasKids && depth + 1 < maxDepth
                && rect.width > minNestSide && rect.height > minNestSide
            out.append(TreemapTile(node: child, rect: rect, depth: depth, isLeaf: !nest, color: color))
            if nest {
                layout(childrenOf: child, in: innerRect(rect), depth: depth + 1, into: &out)
            }
        }
    }

    /// Space inside a container reserved for its children (leaving a header for
    /// the label and a thin border so the grouping reads clearly).
    private static func innerRect(_ rect: CGRect) -> CGRect {
        let top = min(headerHeight, rect.height * 0.28)
        let pad: CGFloat = 2
        return CGRect(x: rect.minX + pad, y: rect.minY + top,
                      width: max(0, rect.width - 2 * pad),
                      height: max(0, rect.height - top - pad))
    }

    // MARK: Squarify (one level)

    private static func squarify(_ items: [FileNode], _ totalSize: Int64,
                                 _ rect: CGRect, _ out: inout [(FileNode, CGRect)]) {
        var remaining = rect
        var remainingSize = totalSize
        var index = 0

        while index < items.count && remaining.width > 0.5 && remaining.height > 0.5 {
            let shortSide = min(remaining.width, remaining.height)
            var row: [FileNode] = []
            var rowSize: Int64 = 0
            var bestRatio = Double.greatestFiniteMagnitude

            var j = index
            while j < items.count {
                let candidateSize = rowSize + items[j].size
                let ratio = worstRatio(row: row + [items[j]], rowSize: candidateSize,
                                       totalSize: remainingSize,
                                       area: Double(remaining.width) * Double(remaining.height),
                                       shortSide: Double(shortSide))
                if ratio > bestRatio { break }
                bestRatio = ratio
                row.append(items[j]); rowSize = candidateSize; j += 1
            }
            layoutRow(row, rowSize: rowSize, totalSize: remainingSize, in: &remaining, out: &out)
            remainingSize -= rowSize
            index = j
        }
    }

    private static func worstRatio(row: [FileNode], rowSize: Int64, totalSize: Int64,
                                   area: Double, shortSide: Double) -> Double {
        guard rowSize > 0, totalSize > 0, shortSide > 0 else { return .greatestFiniteMagnitude }
        let rowArea = area * Double(rowSize) / Double(totalSize)
        let rowLength = rowArea / shortSide
        guard rowLength > 0 else { return .greatestFiniteMagnitude }
        var worst = 1.0
        for n in row {
            let nodeArea = area * Double(n.size) / Double(totalSize)
            let thickness = nodeArea / rowLength
            guard thickness > 0 else { continue }
            worst = max(worst, max(rowLength / thickness, thickness / rowLength))
        }
        return worst
    }

    private static func layoutRow(_ row: [FileNode], rowSize: Int64, totalSize: Int64,
                                  in rect: inout CGRect, out: inout [(FileNode, CGRect)]) {
        guard rowSize > 0, totalSize > 0, !row.isEmpty else { return }
        let area = Double(rect.width) * Double(rect.height)
        let rowArea = area * Double(rowSize) / Double(totalSize)

        if rect.width >= rect.height {
            let rowWidth = CGFloat(rowArea / Double(rect.height))
            var y = rect.minY
            for n in row {
                let h = rect.height * CGFloat(Double(n.size) / Double(rowSize))
                out.append((n, CGRect(x: rect.minX, y: y, width: rowWidth, height: h)))
                y += h
            }
            rect = CGRect(x: rect.minX + rowWidth, y: rect.minY,
                          width: rect.width - rowWidth, height: rect.height)
        } else {
            let rowHeight = CGFloat(rowArea / Double(rect.width))
            var x = rect.minX
            for n in row {
                let w = rect.width * CGFloat(Double(n.size) / Double(rowSize))
                out.append((n, CGRect(x: x, y: rect.minY, width: w, height: rowHeight)))
                x += w
            }
            rect = CGRect(x: rect.minX, y: rect.minY + rowHeight,
                          width: rect.width, height: rect.height - rowHeight)
        }
    }
}

/// Shared, hierarchy-aware coloring used by both the outline and the treemap so
/// they always agree. A node's hue comes from its top-level category (a slot in
/// a CVD-validated categorical palette); depth drives a lightness/saturation
/// ramp, with a small per-name wobble so siblings stay distinguishable.
enum NodePalette {
    /// Hues (0…1) from the data-viz validated categorical palette, in its
    /// CVD-safe ordering: blue, aqua, yellow, green, violet, red, magenta, orange.
    static let hues: [Double] = [0.591, 0.440, 0.113, 0.333, 0.691, 0.001, 0.937, 0.047]

    /// Solid color for a top-level category by its index — used by the history
    /// chart so its bands share the treemap's category hues.
    static func categoryColor(_ index: Int) -> Color {
        Color(hue: hues[index % hues.count], saturation: 0.58, brightness: 0.80)
    }

    static func color(for node: FileNode) -> Color {
        // Walk to the scan root, tracking the top-level ancestor and depth.
        var depth = 0
        var cur = node
        var top = node
        while let parent = cur.parent { top = cur; cur = parent; depth += 1 }
        guard depth > 0, let categories = cur.children else {
            return Color(hue: 0, saturation: 0, brightness: 0.62)   // the root itself
        }
        let index = categories.firstIndex { $0 === top } ?? 0
        return shade(hue: hues[index % hues.count], level: depth - 1, name: node.name)
    }

    private static func shade(hue: Double, level: Int, name: String) -> Color {
        let l = Double(level)
        let saturation = min(0.72, 0.42 + l * 0.09)
        let wobble = (hashFraction(name) - 0.5) * 0.06
        let brightness = min(0.95, max(0.70, 0.90 - l * 0.05 + wobble))
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func hashFraction(_ s: String) -> Double {
        var hasher = Hasher()
        hasher.combine(s)
        let bits = UInt(bitPattern: hasher.finalize())
        return Double(bits % 1000) / 1000.0
    }
}

struct TreemapView: View {
    let node: FileNode
    @Binding var selection: FileNode?
    var onDrill: (FileNode) -> Void
    var onRescan: (FileNode) -> Void

    @State private var tiles: [TreemapTile] = []
    @State private var hovered: FileNode?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let key = "\(node.path)|\(node.size)|\(Int(geo.size.width))x\(Int(geo.size.height))"
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx) }

                // Hover highlight + tooltip in a cheap overlay so moving the
                // cursor doesn't redraw the whole treemap.
                if let h = hovered, let tile = tiles.last(where: { $0.node == h }) {
                    Canvas { ctx, _ in
                        ctx.stroke(Path(roundedRect: tile.rect, cornerRadius: 2),
                                   with: .color(.primary), lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
                    tooltip(for: h, in: geo.size)
                }

                if tiles.isEmpty {
                    Text("No sub-items with measurable size")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverPoint = p; hovered = hit(p)
                case .ended: hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { e in
                    if let n = hit(e.location), n.isDirectory { onDrill(n) }
                }
            )
            .highPriorityGesture(
                SpatialTapGesture(count: 1).onEnded { e in selection = hit(e.location) }
            )
            .contextMenu {
                // Acts on the tile under the cursor (set by hover as you move to
                // right-click it).
                if let target = hovered {
                    Button("Reveal in Finder") {
                        selection = target
                        NSWorkspace.shared.activateFileViewerSelecting([target.url])
                    }
                    if target.isDirectory {
                        Button("Rescan This Folder") {
                            selection = target
                            onRescan(target)
                        }
                    }
                }
            }
            .onAppear { tiles = TreemapLayout.tiles(for: node, in: bounds(geo.size)) }
            .onChange(of: key) {
                tiles = TreemapLayout.tiles(for: node, in: bounds(geo.size))
            }
        }
    }

    private func bounds(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
    }

    /// Deepest tile under a point (children are appended after their container).
    private func hit(_ p: CGPoint) -> FileNode? {
        for tile in tiles.reversed() where tile.rect.contains(p) { return tile.node }
        return nil
    }

    private func draw(_ ctx: GraphicsContext) {
        for tile in tiles {
            let r = tile.rect
            guard r.width > 0.5, r.height > 0.5 else { continue }
            let path = Path(roundedRect: r, cornerRadius: tile.isLeaf ? 2 : 3)
            ctx.fill(path, with: .color(tile.color))
            let borderWidth: CGFloat = tile.isLeaf ? 0.5 : 1.0
            ctx.stroke(path, with: .color(.black.opacity(tile.isLeaf ? 0.15 : 0.35)),
                       lineWidth: borderWidth)

            if r.width > 46 && r.height > 13 {
                let name = Text(tile.node.name)
                    .font(.system(size: 10, weight: tile.isLeaf ? .regular : .semibold))
                    .foregroundColor(.black.opacity(0.75))
                ctx.draw(name, at: CGPoint(x: r.minX + 4, y: r.minY + 2), anchor: .topLeading)
                if tile.isLeaf && r.height > 32 && r.width > 60 {
                    let sz = Text(formatBytes(tile.node.size))
                        .font(.system(size: 9)).foregroundColor(.black.opacity(0.5))
                    ctx.draw(sz, at: CGPoint(x: r.minX + 4, y: r.minY + 15), anchor: .topLeading)
                }
            }
        }

        if let sel = selection, let tile = tiles.last(where: { $0.node == sel }) {
            ctx.stroke(Path(roundedRect: tile.rect, cornerRadius: 3),
                       with: .color(.primary), lineWidth: 2.5)
        }
    }

    private func tooltip(for node: FileNode, in size: CGSize) -> some View {
        let text = "\(node.name) — \(formatBytes(node.size))"
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .offset(x: min(max(hoverPoint.x + 12, 4), size.width - 220),
                    y: min(max(hoverPoint.y - 28, 4), size.height - 30))
            .allowsHitTesting(false)
    }
}
