import Foundation
import UniformTypeIdentifiers
import ImageIO

public enum FileKind: String, CaseIterable, Sendable {
    case image, video, audio, pdf, subtitle, archive, document, folder, unknown
    public static func detect(_ url: URL) -> Self {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["srt", "vtt"].contains(ext) { return .subtitle }
        if ["zip", "tar", "gz", "tgz", "rar", "7z"].contains(ext) { return .archive }
        if ["doc", "docx", "pages", "ppt", "pptx", "xls", "xlsx", "ods", "csv", "tsv", "txt", "md", "rtf", "epub", "html"].contains(ext) { return .document }
        // Stable even when LaunchServices type registration is unavailable (e.g. a test runner).
        // Conversion still validates the file contents using the decoder.
        if ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp", "avif"].contains(ext) { return .image }
        if ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "aac"].contains(ext) { return .audio }
        if ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v"].contains(ext) { return .video }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) { return .video }
        }
        if ["webp", "avif", "heic", "heif"].contains(ext) { return .image }
        if ["mkv", "webm", "wmv", "avi"].contains(ext) { return .video }
        if ["flac", "ogg", "opus", "wma"].contains(ext) { return .audio }
        return .unknown
    }
    public var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .folder: return "folder"
        default: return "doc"
        }
    }
}

public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case convert, compress, resize, stripMetadata, trim, videoFrame, imagesToPDF, mergePDF, splitPDF, extractText, zip
    public var id: String { rawValue }
    public var icon: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .stripMetadata: return "eye.slash"
        case .trim: return "scissors"
        case .videoFrame: return "photo.on.rectangle"
        case .imagesToPDF: return "photo.stack"
        case .mergePDF: return "doc.on.doc"
        case .splitPDF: return "square.split.2x2"
        case .extractText: return "text.viewfinder"
        case .zip: return "archivebox"
        }
    }
    public func title(_ arabic: Bool) -> String {
        switch self {
        case .convert: return arabic ? "تحويل الصيغة" : "Convert format"
        case .compress: return arabic ? "ضغط الملف" : "Compress"
        case .resize: return arabic ? "تغيير المقاس" : "Resize image"
        case .stripMetadata: return arabic ? "تنظيف البيانات" : "Clean metadata"
        case .trim: return arabic ? "قص المدة" : "Trim media"
        case .videoFrame: return arabic ? "لقطة من الفيديو" : "Video snapshot"
        case .imagesToPDF: return arabic ? "صور إلى PDF" : "Images to PDF"
        case .mergePDF: return arabic ? "دمج PDF" : "Merge PDFs"
        case .splitPDF: return arabic ? "تقسيم PDF" : "Split PDF"
        case .extractText: return arabic ? "استخراج النص · OCR" : "Extract text · OCR"
        case .zip: return arabic ? "إنشاء ZIP" : "Create ZIP"
        }
    }
    public func accepts(_ kind: FileKind) -> Bool {
        switch self {
        case .convert: return [.image, .video, .audio, .pdf, .subtitle].contains(kind)
        case .compress, .stripMetadata: return [.image, .video, .audio].contains(kind)
        case .resize, .imagesToPDF: return kind == .image
        case .trim: return [.video, .audio].contains(kind)
        case .videoFrame: return kind == .video
        case .mergePDF, .splitPDF: return kind == .pdf
        case .extractText: return [.image, .pdf].contains(kind)
        case .zip: return true
        }
    }
    public var grouped: Bool { [.imagesToPDF, .mergePDF, .zip].contains(self) }
}

public struct Options: Sendable {
    public var format = "png"
    public var quality = 80
    public var maxDimension = 1920
    public var start = 0.0
    public var duration = 10.0
    public init() {}
    public func validate() throws {
        guard (1...100).contains(quality), (16...16000).contains(maxDimension), start.isFinite, duration.isFinite,
              start >= 0, start <= 604800, duration > 0, duration <= 604800 else { throw EngineError.invalidOptions }
    }
}

public struct JobRequest: Sendable {
    public let inputs: [URL]
    public let outputDirectory: URL
    public let tool: Tool
    public let options: Options
    public init(inputs: [URL], outputDirectory: URL, tool: Tool, options: Options) {
        self.inputs = inputs; self.outputDirectory = outputDirectory; self.tool = tool; self.options = options
    }
}

public enum EngineError: LocalizedError {
    case invalidOptions, unsupported(String), invalidFile(String), missingEngine(String), failed(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidOptions: return "إعدادات غير صالحة / Invalid options."
        case .unsupported(let s): return "مسار غير مدعوم / Unsupported: \(s)"
        case .invalidFile(let s): return "تعذر قراءة الملف / Cannot read: \(s)"
        case .missingEngine(let s): return "المحرك غير متوفر / Engine unavailable: \(s)"
        case .failed(let s): return s
        case .cancelled: return "أُلغيت المهمة / Cancelled."
        }
    }
}

public enum Engines {
    /// The user approved this app in Gatekeeper, but its downloaded copy keeps the quarantine flag on
    /// each bundled helper, and macOS kills an ad-hoc signed quarantined helper on exec. Clear the flag
    /// on our own sealed helpers only; failure (read-only install) falls back to system engines.
    public static func clearBundledQuarantine() {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("bin"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: bin.path) else { return }
        for name in names where ["ffmpeg", "cwebp"].contains(name) {
            removexattr(bin.appendingPathComponent(name).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
    public static func executable(_ name: String) -> URL? {
        let allowed = ["ffmpeg", "ffprobe", "cwebp", "zip"]
        guard allowed.contains(name) else { return nil }
        // Engines bundled in the app (Contents/Resources/bin) win over system copies.
        let bundled = Bundle.main.resourceURL.map { [$0.appendingPathComponent("bin").path] } ?? []
        for base in bundled + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: base).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    public static func formats(for kind: FileKind) -> [String] {
        switch kind {
        case .image:
            let native = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
            var formats = [("jpg", "public.jpeg"), ("png", "public.png"), ("heic", "public.heic"), ("tiff", "public.tiff"), ("bmp", "com.microsoft.bmp")].filter { native.contains($0.1) }.map { $0.0 }
            if executable("cwebp") != nil { formats.append("webp") }
            formats.append("pdf")
            return formats
        case .video: return executable("ffmpeg") == nil ? [] : ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav"]
        case .audio: return executable("ffmpeg") == nil ? [] : ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        case .pdf: return ["png", "jpg", "txt", "md"]
        case .subtitle: return ["srt", "vtt", "txt"]
        default: return []
        }
    }
}
