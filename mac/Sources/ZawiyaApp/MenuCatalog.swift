import AppKit
import ZawiyaCore

enum MenuCatalog {
    static func symbol(for format: String) -> String {
        if ["jpg", "png", "webp", "heic", "tiff", "bmp"].contains(format) { return "photo" }
        if ["mp4", "mov", "mkv", "webm", "avi", "gif"].contains(format) { return "film" }
        if ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"].contains(format) { return "waveform" }
        return format == "pdf" ? "doc.richtext" : "text.alignleft"
    }
    static func commonFormats(for kinds: [FileKind], favorites: [String] = []) -> [String] {
        var seen = Set<FileKind>()
        let unique = kinds.filter { seen.insert($0).inserted }
        guard let first = unique.first else { return ordered(Engines.formats(for: .image), favorites: favorites) }
        let supported = unique.map { Set(Engines.formats(for: $0)) }
        let formats = Engines.formats(for: first).filter { format in supported.allSatisfy { $0.contains(format) } }
        return ordered(formats, favorites: favorites)
    }
    static func ordered(_ formats: [String], favorites: [String]) -> [String] {
        var seen = Set<String>()
        return (favorites.filter { formats.contains($0) } + formats).filter { seen.insert($0).inserted }
    }
    static func tools(for kinds: [FileKind]) -> [Tool] {
        let unique = Set(kinds)
        let canConvert = unique.isEmpty || !commonFormats(for: kinds).isEmpty
        return Tool.allCases.filter { tool in unique.allSatisfy { tool.accepts($0) } && (tool != .convert || canConvert) }
    }
    static func matchingTools(_ query: String) -> [Tool] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Tool.allCases }
        return Tool.allCases.filter { tool in
            [tool.title(true), tool.title(false), tool.rawValue].contains { $0.localizedStandardContains(needle) }
        }
    }
}

/// Computes non-overlapping hit targets for the complete menu, without truncating it.
struct WheelGeometry {
    let size: CGSize
    let frames: [CGRect]
    let centerFrame: CGRect
    init(count: Int) {
        let count = max(0, count)
        let cell = CGSize(width: 68, height: 62)
        var radius: CGFloat = 92
        var frames: [CGRect] = []
        while true {
            let side = ceil((radius + cell.width / 2 + 14) * 2)
            let center = side / 2
            frames = (0..<count).map { index in
                let angle = .pi / 2 - CGFloat(index) / CGFloat(max(1, count)) * .pi * 2
                return CGRect(x: center + cos(angle) * radius - cell.width / 2, y: center + sin(angle) * radius - cell.height / 2, width: cell.width, height: cell.height)
            }
            let overlaps = frames.indices.contains { i in frames.indices.contains { j in i < j && frames[i].insetBy(dx: -4, dy: -4).intersects(frames[j]) } }
            if !overlaps {
                size = CGSize(width: side, height: side)
                self.frames = frames
                centerFrame = CGRect(x: center - 38, y: center - 38, width: 76, height: 76)
                return
            }
            radius += 4
        }
    }
    static func presentationFrame(size: CGSize, pointer: CGPoint, screen: CGRect) -> CGRect {
        let safe = screen.insetBy(dx: 12, dy: 12)
        let scale = min(1, safe.width / size.width, safe.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: max(safe.minX, min(pointer.x - width / 2, safe.maxX - width)), y: max(safe.minY, min(pointer.y - height / 2, safe.maxY - height)), width: width, height: height)
    }
}
