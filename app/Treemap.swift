import AppKit

/// One laid-out rectangle in the treemap.
struct TMRect {
    var rect: CGRect
    var node: Int
    var isDir: Bool
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk) over the flat tree.
enum Squarify {
    /// Lay out the direct children of `dir` into `rect` (one level, no
    /// recursion). Children below ~half a pixel are dropped — the caller has
    /// already painted the parent underneath, so nothing shows as a void.
    static func layoutLevel(tree: Tree, dir: Int, rect: CGRect) -> [(node: Int, rect: CGRect)] {
        let kids = tree.children(dir)
        if kids.isEmpty { return [] }

        var items: [(node: Int, size: Double)] = []
        items.reserveCapacity(kids.count)
        for k in kids {
            let s = Double(tree.alloc[Int(k)])
            if s > 0 { items.append((Int(k), s)) }
        }
        return layoutItems(items, rect: rect)
    }

    /// Core squarify over explicit (node, size) items, already sorted
    /// descending. Synthetic nodes (negative ids) welcome.
    static func layoutItems(_ items: [(node: Int, size: Double)], rect: CGRect) -> [(node: Int, rect: CGRect)] {
        guard !items.isEmpty else { return [] }
        let total = items.reduce(0.0) { $0 + $1.size }
        guard total > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total

        var out: [(node: Int, rect: CGRect)] = []
        out.reserveCapacity(min(items.count, 4096))

        var x = rect.minX, y = rect.minY
        var w = rect.width, h = rect.height
        var i = 0

        while i < items.count {
            let side = Double(min(w, h))
            guard side >= 1 else { break }
            // Children are sorted descending: once areas drop below a quarter
            // pixel every remaining child is invisible too.
            if items[i].size * scale < 0.25 { break }

            // Grow a row until the worst aspect ratio would degrade.
            var rowMin = items[i].size * scale
            var rowMax = rowMin
            var rowSum = rowMin
            var rowEnd = i + 1
            var worst = worstRatio(sum: rowSum, minA: rowMin, maxA: rowMax, side: side)
            while rowEnd < items.count {
                let a = items[rowEnd].size * scale
                let newWorst = worstRatio(sum: rowSum + a, minA: min(rowMin, a), maxA: max(rowMax, a), side: side)
                if newWorst > worst { break }
                worst = newWorst
                rowSum += a
                rowMin = min(rowMin, a)
                rowMax = max(rowMax, a)
                rowEnd += 1
            }

            let thickness = CGFloat(rowSum) / min(w, h)
            var offset: CGFloat = 0
            for j in i..<rowEnd {
                let len = CGFloat(items[j].size * scale) / thickness
                let r: CGRect
                if w < h {
                    r = CGRect(x: x + offset, y: y, width: len, height: thickness)
                } else {
                    r = CGRect(x: x, y: y + offset, width: thickness, height: len)
                }
                offset += len
                out.append((items[j].node, r))
            }
            if w < h {
                y += thickness; h -= thickness
            } else {
                x += thickness; w -= thickness
            }
            i = rowEnd
            if w < 0.5 || h < 0.5 { break }
        }
        return out
    }

    private static func worstRatio(sum: Double, minA: Double, maxA: Double, side: Double) -> Double {
        let s2 = sum * sum
        let side2 = side * side
        return max(side2 * maxA / s2, s2 / (side2 * minA))
    }
}

/// Per-extension colors as linear RGB triples for the cushion shader.
/// Vivid, WizTree-class saturation — the cushion shading supplies the depth.
enum TypeColor {
    typealias RGB = (r: Double, g: Double, b: Double)

    private static func hsb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> RGB {
        let c = NSColor(calibratedHue: h, saturation: s, brightness: v, alpha: 1)
            .usingColorSpace(.deviceRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    static let fixed: [String: RGB] = {
        var m: [String: RGB] = [:]
        let groups: [([String], RGB)] = [
            (["mp4", "mov", "mkv", "avi", "webm", "m4v"], hsb(0.055, 0.78, 0.98)), // video: orange
            (["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw", "svg", "icns"], hsb(0.80, 0.55, 0.96)), // images: purple
            (["mp3", "m4a", "aac", "wav", "flac", "aiff"], hsb(0.34, 0.65, 0.88)), // audio: green
            (["zip", "tar", "gz", "xz", "7z", "rar", "dmg", "pkg", "ipa", "xip"], hsb(0.125, 0.72, 0.97)), // archives: amber
            (["dylib", "so", "framework", "bin", "exe", "o", "a", "metallib"], hsb(0.60, 0.62, 0.96)), // binaries: blue
            (["swift", "rs", "c", "h", "cpp", "m", "py", "js", "ts", "tsx", "jsx", "go", "java", "rb", "sh", "json", "yaml", "toml"], hsb(0.47, 0.60, 0.86)), // code: teal
            (["pdf", "doc", "docx", "txt", "md", "pages", "key", "ppt", "pptx", "xls", "xlsx", "csv"], hsb(0.57, 0.40, 0.92)), // docs: slate blue
            (["sst", "db", "sqlite", "sqlite3", "wal", "ldb", "mdb", "realm"], hsb(0.02, 0.55, 0.92)), // databases: coral
            (["plist", "log", "cache", "dat", "tmp"], hsb(0.10, 0.25, 0.80)), // system litter: tan
        ]
        for (exts, color) in groups { for e in exts { m[e] = color } }
        return m
    }()

    /// Extensionless files: warm neutral, clearly "a file", never void-grey.
    static let plain: RGB = hsb(0.09, 0.14, 0.82)
    /// Directory base (shows through where children are sub-pixel).
    /// Light neutral so dense regions read as texture, not holes.
    static let dir: RGB = hsb(0.58, 0.06, 0.66)
    /// Free-space block: flat near-background so it reads as absence.
    static let free: RGB = (0.155, 0.155, 0.175)
    /// Frame + title strip of a labeled directory (WizTree-style box).
    /// Flat-shaded, so pick the pre-lighting value for a ~#26262B result.
    static let strip: RGB = (0.165, 0.165, 0.195)

    static func forName(_ name: String) -> RGB {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return plain }
        let ext = name[name.index(after: dot)...].lowercased()
        if ext.count > 10 { return plain }
        if let c = fixed[ext] { return c }
        // fallback: stable hash -> vivid hue
        var h: UInt32 = 2166136261
        for b in ext.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return hsb(CGFloat(h % 360) / 360.0, 0.52, 0.90)
    }
}
