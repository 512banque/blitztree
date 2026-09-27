import AppKit
import SwiftUI

/// The treemap canvas: cushion-shaded rects rendered once into a bitmap per
/// layout change; hover/selection drawn as a light overlay per frame.
final class TreemapNSView: NSView {
    var model: ScanModel? {
        // SwiftUI hands the same model back on every update; only a new one
        // needs a render (the rest goes through relayoutIfNeeded).
        didSet { if model !== oldValue { relayout() } }
    }

    /// Folders an agent plan would remove: lit while the rest dims.
    var highlights: [Int] = [] { didSet { litRects = nil } }
    /// Their rects in the current layout, found once per change, not per frame.
    private var litRects: [CGRect]?
    private var rects: [TMRect] = []
    private var leaves: [TMRect] = [] // files only, for hit-testing
    /// `strip` is the title bar (text + hit target); `region` is the whole
    /// directory rect (hover boundary). Both in view points.
    private var labels: [TMLabel] = []
    private var labelHits: [(rect: CGRect, node: Int)] = []
    private var bitmap: CGImage?
    private var lastSize: CGSize = .zero
    private var lastRoot: Int = -1
    private var lastTreeID: ObjectIdentifier?
    private var lastShowFree = false

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayoutIfNeeded()
    }

    func relayoutIfNeeded() {
        guard let model, let tree = model.tree else { return }
        let treeID = ObjectIdentifier(tree)
        if bounds.size != lastSize || model.viewRoot != lastRoot || treeID != lastTreeID
            || model.showFreeSpace != lastShowFree {
            relayout()
        }
    }

    func relayout() {
        guard let model, let tree = model.tree, bounds.width > 4, bounds.height > 4 else {
            rects = []; leaves = []; bitmap = nil
            needsDisplay = true
            return
        }
        lastSize = bounds.size
        lastRoot = model.viewRoot
        lastTreeID = ObjectIdentifier(tree)
        lastShowFree = model.showFreeSpace

        rects.removeAll(keepingCapacity: true)
        leaves.removeAll(keepingCapacity: true)
        labels.removeAll(keepingCapacity: true)
        renderBitmap(tree: tree)
        needsDisplay = true
    }

    // ---- WinDirStat-style cushion renderer ----
    //
    // Every node adds a parabolic ridge to an accumulated quadratic surface
    //   z = ax2·x² + ax1·x + ay2·y² + ay1·y
    // and leaves are shaded per pixel from the surface normal and a fixed
    // light. Parents paint before children, so every pixel is always covered
    // — no voids, and nesting reads through the compounded cushions exactly
    // like WizTree/WinDirStat.

    nonisolated private struct Surface {
        var ax2 = 0.0, ax1 = 0.0, ay2 = 0.0, ay1 = 0.0

        mutating func addRidge(_ r: CGRect, height: Double) {
            let wx = Double(r.width), wy = Double(r.height)
            if wx > 0 {
                let h4 = 4 * height / (wx * wx)
                ax2 -= h4
                ax1 += h4 * Double(r.minX + r.maxX)
            }
            if wy > 0 {
                let h4 = 4 * height / (wy * wy)
                ay2 -= h4
                ay1 += h4 * Double(r.minY + r.maxY)
            }
        }
    }

    nonisolated private enum Cushion {
        static let baseHeight = 0.55   // ridge height at the top level
        static let falloff = 0.72      // height multiplier per depth
        static let ambient = 0.38
        // Light from the top-left, mostly overhead.
        static let lx = -0.408, ly = -0.408, lz = 0.816

        /// Ridge height proportional to rect size so big tiles still curve.
        static func height(_ r: CGRect, _ h: Double) -> Double {
            h * Double(min(r.width, r.height))
        }
    }

    /// Where one render's hit-testing geometry lands.
    nonisolated private final class RenderOutput: @unchecked Sendable {
        var rects: [TMRect] = []
        var leaves: [TMRect] = []
        var labels: [TMLabel] = []
    }

    private func renderBitmap(tree: Tree) {
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int((bounds.width * scale).rounded()))
        let ph = max(1, Int((bounds.height * scale).rounded()))
        var pixels = [UInt32](repeating: 0xFF16_1616, count: pw * ph)
        let showFree = model?.showFreeSpace ?? false
        let freeBytes = model?.freeBytes ?? 0
        let rootIndex = model?.viewRoot ?? 0
        let out = RenderOutput()

        // The cushion shader repaints every pixel once per nesting level, so
        // a full map is tens of millions of shaded pixels. Split the bitmap
        // into horizontal bands and paint them on every core at once: each
        // band walks the whole tree in the same order but only writes its
        // own rows, so the result is pixel-identical to one pass.
        // The cushion shader repaints every pixel once per nesting level:
        // tens of millions of shaded pixels for a full map. Lay it out once,
        // then paint horizontal bands on every core; each band runs the same
        // steps in the same order over its own rows only, so the result is
        // pixel-identical to a single pass.
        let started = Date()
        let ops = Self.layoutOps(
            tree: tree, pw: pw, ph: ph, scale: scale, root: rootIndex,
            showFree: showFree, freeBytes: freeBytes, out: out
        )
        let laidOut = Date()
        let bands = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 3, ph / 32))
        ops.withUnsafeBufferPointer { ops in
            pixels.withUnsafeMutableBufferPointer { buf in
                nonisolated(unsafe) let base = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    Self.paint(ops, base: base, pw: pw, ph: ph,
                               rows: (ph * band / bands)..<(ph * (band + 1) / bands))
                }
            }
        }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            NSLog("BZ render %dx%d: %d steps, layout %.1f ms, paint %.1f ms (%d bands)",
                  pw, ph, ops.count, laidOut.timeIntervalSince(started) * 1000,
                  -laidOut.timeIntervalSinceNow * 1000, bands)
        }
        rects = out.rects
        leaves = out.leaves
        litRects = nil
        labels = out.labels

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        bitmap = CGImage(
            width: pw, height: ph,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// One step of the cushion painter, in paint order.
    nonisolated private enum PaintOp {
        case shade(CGRect, TypeColor.RGB, Surface)
        /// Darken a frame band around the rect (thickness in pixels).
        case frame(CGRect, Int, Double)
    }

    /// Lays the treemap out once, in paint order: parents before children,
    /// frames after their contents. Also fills `out` with the geometry used
    /// for hit-testing and labels.
    nonisolated private static func layoutOps(
        tree: Tree, pw: Int, ph: Int, scale: CGFloat, root: Int,
        showFree: Bool, freeBytes: UInt64, out: RenderOutput
    ) -> [PaintOp] {
        var ops: [PaintOp] = []
        ops.reserveCapacity(1 << 16)
        var colors = TypeColor.Cache()

        func draw(_ node: Int, _ rect: CGRect, _ h: Double, _ surface: Surface, _ depth: Int) {
            guard rect.width >= 0.5, rect.height >= 0.5 else { return }
            var s = surface
            // The view root adds no ridge: a window-wide parabola would
            // just vignette the whole map.
            if depth > 0 {
                s.addRidge(rect, height: Cushion.height(rect, h))
            }
            let ptRect = CGRect(
                x: rect.minX / scale, y: rect.minY / scale,
                width: rect.width / scale, height: rect.height / scale
            )
            guard tree.isDir(node) else {
                out.leaves.append(TMRect(rect: ptRect, node: node, isDir: false))
                ops.append(.shade(rect, colors.color(tree, node), s))
                return
            }
            out.rects.append(TMRect(rect: ptRect, node: node, isDir: true))

            // WizTree-style framed box: big directories get a title
            // strip on their top border and children render inside
            // the frame — at every depth, no zooming required.
            let headerH = (15 * scale).rounded()
            let headed = depth >= 1
                && rect.width >= 88 * scale
                && rect.height >= max(58 * scale, headerH * 2.8)
            var content = rect
            var layoutNode = node
            if headed {
                // Collapse pass-through chains (a dir whose one child
                // holds ~everything) into a single "A ▸ B" strip.
                var stripName = tree.name(node)
                while let first = tree.children(layoutNode).first {
                    let fi = Int(first)
                    guard tree.isDir(fi),
                          Double(tree.alloc[fi]) >= 0.99 * Double(max(tree.alloc[layoutNode], 1))
                    else { break }
                    stripName += "  ▸  " + tree.name(fi)
                    layoutNode = fi
                }
                ops.append(.shade(rect, TypeColor.strip, Surface()))
                let strip = CGRect(x: rect.minX, y: rect.minY,
                                   width: rect.width, height: headerH)
                out.labels.append(TMLabel(
                    strip: CGRect(x: strip.minX / scale, y: strip.minY / scale,
                                  width: strip.width / scale, height: strip.height / scale),
                    region: ptRect, node: layoutNode, depth: depth, name: stripName
                ))
                content = CGRect(x: rect.minX + 2, y: rect.minY + headerH,
                                 width: rect.width - 4, height: rect.height - headerH - 2)
            }

            // Parent cushion first: covers sub-pixel children and
            // pixel-snap slivers, so the map has no holes.
            ops.append(.shade(content, TypeColor.dir, s))
            if content.width >= 3, content.height >= 3 {
                let level: [(node: Int, rect: CGRect)]
                if depth == 0, showFree, freeBytes > 0 {
                    // Free disk space competes for area like a file.
                    var items: [(node: Int, size: Double)] = tree.children(layoutNode).compactMap {
                        let sz = Double(tree.alloc[Int($0)])
                        return sz > 0 ? (Int($0), sz) : nil
                    }
                    items.append((-1, Double(freeBytes)))
                    items.sort { $0.size > $1.size }
                    level = Squarify.layoutItems(items, rect: content)
                } else {
                    level = Squarify.layoutLevel(tree: tree, dir: layoutNode, rect: content)
                }
                for (kid, r) in level {
                    if kid == -1 {
                        // Flat, quiet void — clearly "nothing here".
                        ops.append(.shade(r, TypeColor.free, Surface()))
                        let pr = CGRect(x: r.minX / scale, y: r.minY / scale,
                                        width: r.width / scale, height: r.height / scale)
                        if pr.width >= 90, pr.height >= 30 {
                            out.labels.append(TMLabel(strip: pr, region: pr, node: -1, depth: 1, name: "Free space"))
                        }
                    } else {
                        draw(kid, r, depth == 0 ? h : h * Cushion.falloff, s, depth + 1)
                    }
                }
            }
            // Separation frames for unheaded dirs (headed ones have
            // their own frame already).
            if !headed {
                switch depth {
                case 0: break // window edge needs no frame
                case 1: ops.append(.frame(rect, Int(2 * scale), 0.30))
                case 2: ops.append(.frame(rect, Int(scale), 0.42))
                case 3: ops.append(.frame(rect, max(1, Int(scale / 2)), 0.55))
                default:
                    if rect.width > 28, rect.height > 28 {
                        ops.append(.frame(rect, 1, 0.62))
                    }
                }
            }
        }

        draw(root, CGRect(x: 0, y: 0, width: pw, height: ph), Cushion.baseHeight, Surface(), 0)
        return ops
    }

    /// Runs the paint steps for pixel rows in `rows` only. Steps are applied
    /// in order, so any split into bands gives the same pixels as one pass.
    nonisolated private static func paint(
        _ ops: UnsafeBufferPointer<PaintOp>, base: UnsafeMutablePointer<UInt32>,
        pw: Int, ph: Int, rows: Range<Int>
    ) {
        let by0 = rows.lowerBound, by1 = rows.upperBound

        func shade(_ r: CGRect, _ rgb: TypeColor.RGB, _ s: Surface) {
            let x0 = max(0, Int(r.minX.rounded())), x1 = min(pw, Int(r.maxX.rounded()))
            let y0 = max(by0, Int(r.minY.rounded())), y1 = min(by1, Int(r.maxY.rounded()))
            guard x1 > x0, y1 > y0 else { return }
            for py in y0..<y1 {
                let fy = Double(py) + 0.5
                let ny = -(2 * s.ay2 * fy + s.ay1)
                let row = base + py * pw
                for px in x0..<x1 {
                    let fx = Double(px) + 0.5
                    let nx = -(2 * s.ax2 * fx + s.ax1)
                    let cos = (nx * Cushion.lx + ny * Cushion.ly + Cushion.lz)
                        / (nx * nx + ny * ny + 1).squareRoot()
                    let lum = Cushion.ambient + max(0, cos) * (1 - Cushion.ambient)
                    let r8 = UInt32(min(255, rgb.r * lum * 255))
                    let g8 = UInt32(min(255, rgb.g * lum * 255))
                    let b8 = UInt32(min(255, rgb.b * lum * 255))
                    (row + px).pointee = 0xFF00_0000 | (b8 << 16) | (g8 << 8) | r8
                }
            }
        }

        /// Separation "grout" between directories. Multiplies what's
        /// underneath so hues survive.
        func frame(_ r: CGRect, thickness: Int, factor: Double) {
            let x0 = max(0, Int(r.minX.rounded())), x1 = min(pw, Int(r.maxX.rounded()))
            let y0 = max(0, Int(r.minY.rounded())), y1 = min(ph, Int(r.maxY.rounded()))
            guard x1 - x0 > thickness * 2 + 2, y1 - y0 > thickness * 2 + 2 else { return }
            func darken(_ px: Int, _ py: Int) {
                let p = base + py * pw + px
                let v = p.pointee
                let r8 = UInt32(Double(v & 0xFF) * factor)
                let g8 = UInt32(Double((v >> 8) & 0xFF) * factor)
                let b8 = UInt32(Double((v >> 16) & 0xFF) * factor)
                p.pointee = 0xFF00_0000 | (b8 << 16) | (g8 << 8) | r8
            }
            for t in 0..<thickness {
                if (by0..<by1).contains(y0 + t) { for px in x0..<x1 { darken(px, y0 + t) } }
                if (by0..<by1).contains(y1 - 1 - t) { for px in x0..<x1 { darken(px, y1 - 1 - t) } }
                let v0 = max(y0 + thickness, by0), v1 = min(y1 - thickness, by1)
                if v1 > v0 {
                    for py in v0..<v1 {
                        darken(x0 + t, py)
                        darken(x1 - 1 - t, py)
                    }
                }
            }
        }

        let top = CGFloat(by0), bottom = CGFloat(by1)
        for op in ops {
            switch op {
            case let .shade(r, rgb, s):
                if r.maxY.rounded() > top, r.minY.rounded() < bottom { shade(r, rgb, s) }
            case let .frame(r, thickness, factor):
                if r.maxY.rounded() > top, r.minY.rounded() < bottom {
                    frame(r, thickness: thickness, factor: factor)
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let bitmap {
            NSImage(cgImage: bitmap, size: bounds.size).draw(
                in: bounds, from: .zero, operation: .copy, fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none.rawValue]
            )
        }

        guard let model, let tree = model.tree else { return }

        // Label hover boundary FIRST, so strip text always renders above it.
        if let hl = hoveredLabel, let lab = labels.first(where: { $0.node == hl }) {
            let rr = lab.region.insetBy(dx: 2, dy: 2)
            let halo = NSBezierPath(rect: rr)
            halo.lineWidth = 7
            NSColor.black.withAlphaComponent(0.55).setStroke()
            halo.stroke()
            let line = NSBezierPath(rect: rr)
            line.lineWidth = 2.5
            NSColor.white.setStroke()
            line.stroke()
        }

        // Title-strip labels: text lives on the directory's frame, never on
        // top of its contents.
        labelHits.removeAll(keepingCapacity: true)
        for label in labels {
            if label.node < 0 {
                // Free-space keeps a small floating tag (it has no frame).
                let text = label.region.width > 130
                    ? "Free space  ·  \(Fmt.size(model.freeBytes))" : "Free space"
                let str = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ])
                str.draw(at: CGPoint(x: label.region.minX + 8, y: label.region.minY + 6))
                continue
            }

            let strip = label.strip
            let hovered = label.node == hoveredLabel
            if hovered {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: strip).fill()
            }
            let nameStr = NSAttributedString(string: label.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 1.0 : 0.92),
            ])
            var avail = strip.width - 12
            if strip.width > 175 {
                // right-aligned size on roomy strips
                let sizeStr = NSAttributedString(string: Fmt.size(tree.alloc[label.node]), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.60),
                ])
                let sw = sizeStr.size()
                sizeStr.draw(at: CGPoint(x: strip.maxX - sw.width - 6,
                                         y: strip.midY - sw.height / 2))
                avail -= sw.width + 10
            }
            let nh = nameStr.size().height
            nameStr.draw(
                with: CGRect(x: strip.minX + 6, y: strip.midY - nh / 2,
                             width: max(0, avail), height: nh),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            labelHits.append((strip, label.node))
        }

        // Hover: outline the file and its parent directory.
        if let h = model.hovered, let r = leaves.first(where: { $0.node == h }) {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let p = NSBezierPath(rect: r.rect.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
            let parent = Int(tree.parents[h])
            if let pr = rects.first(where: { $0.node == parent && $0.isDir }) {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                let pp = NSBezierPath(rect: pr.rect.insetBy(dx: 0.5, dy: 0.5))
                pp.lineWidth = 1
                pp.stroke()
            }
        }
        if !highlights.isEmpty {
            if litRects == nil {
                let wanted = Set(highlights)
                litRects = rects.filter { wanted.contains($0.node) }.map { $0.rect.insetBy(dx: 0.5, dy: 0.5) }
            }
            let lit = litRects ?? []
            if !lit.isEmpty {
                let dim = NSBezierPath(rect: bounds)
                for r in lit { dim.append(NSBezierPath(rect: r)) }
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.55).setFill()
                dim.fill()
                NSColor.controlAccentColor.setStroke()
                for r in lit {
                    let p = NSBezierPath(rect: r)
                    p.lineWidth = 1.5
                    p.stroke()
                }
            }
        }
        if let sel = model.selection, let r = rects.first(where: { $0.node == sel }) {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r.rect.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }
    }

    // ---- Interaction ----

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let esc = event.keyCode == 53
        let cmdUp = event.modifierFlags.contains(.command) && event.keyCode == 126
        if esc || cmdUp, let model, let tree = model.tree, model.viewRoot != 0 {
            let p = Int(tree.parents[model.viewRoot])
            model.viewRoot = p == Int(UInt32.max) ? 0 : p
            relayout()
        } else {
            super.keyDown(with: event)
        }
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(_ point: CGPoint) -> TMRect? {
        // Files are disjoint; smallest matching leaf wins.
        leaves.last(where: { $0.rect.contains(point) })
    }

    private var hoveredLabel: Int? = nil

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let lab = labelHits.first(where: { $0.rect.contains(p) })?.node
        if lab != hoveredLabel {
            hoveredLabel = lab
            needsDisplay = true
        }
        let node = lab ?? hit(p)?.node
        if node != model?.hovered {
            model?.hovered = node
            if let node, let tree = model?.tree {
                toolTip = "\(tree.displayPath(node))\n\(Fmt.size(tree.alloc[node]))"
            } else {
                toolTip = nil
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        model?.hovered = nil
        hoveredLabel = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let model, let tree = model.tree else { return }
        if event.clickCount == 2 {
            // Directory labels are zoom targets first.
            if let lab = labelHits.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) {
                model.viewRoot = lab.node
                relayout()
                return
            }
            if let leaf = hit(p) {
                // zoom into the file's parent directory
                let parent = Int(tree.parents[leaf.node])
                if parent != Int(UInt32.max) && tree.isDir(parent) && parent != model.viewRoot {
                    model.viewRoot = parent
                    relayout()
                }
            }
        } else {
            if let lab = labelHits.first(where: { $0.rect.contains(p) }) {
                model.selection = lab.node
            } else {
                model.selection = hit(p)?.node
            }
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let model, let tree = model.tree, let leaf = hit(p) else { return }
        model.selection = leaf.node
        needsDisplay = true
        NodeMenu.popUp(path: tree.path(leaf.node), with: event, for: self)
    }
}

/// Right-click menu for a file or folder, shared by the treemap and rings.
final class NodeMenu: NSObject {
    private static let shared = NodeMenu()

    static func popUp(path: String, with event: NSEvent, for view: NSView) {
        let menu = NSMenu()
        for (title, action) in [("Reveal in Finder", #selector(revealInFinder(_:))),
                                ("Copy Path", #selector(copyPath(_:))),
                                ("Move to Trash", #selector(moveToTrash(_:)))] {
            if action == #selector(moveToTrash(_:)) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = shared
            item.representedObject = path
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func moveToTrash(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        let alert = NSAlert()
        alert.messageText = "Move \u{201C}\(url.lastPathComponent)\u{201D} to Trash?"
        alert.informativeText = path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            // Note: sizes refresh on next rescan; v1 keeps it simple.
        }
    }
}

struct TreemapView: NSViewRepresentable {
    let model: ScanModel

    func makeNSView(context: Context) -> TreemapNSView {
        let v = TreemapNSView()
        v.model = model
        return v
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.model = model
        view.relayoutIfNeeded()
        let lit = model.agentRun?.highlights(in: model.tree) ?? []
        if lit != view.highlights {
            view.highlights = lit
            view.needsDisplay = true
        }
    }
}
