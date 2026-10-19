import Foundation
import AppKit
import PDFKit
import ImageIO
import Vision
import UniformTypeIdentifiers
import Darwin

public final class Converter: @unchecked Sendable {
    public init() {}
    public func run(_ request: JobRequest, cancellation: Cancellation = Cancellation()) throws -> [URL] {
        try request.options.validate()
        try cancellation.check()
        let fm = FileManager.default
        let inputs = request.inputs.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !inputs.isEmpty, inputs.count <= 2000 else { throw EngineError.invalidOptions }
        for input in inputs {
            guard input.isFileURL, fm.isReadableFile(atPath: input.path), request.tool.accepts(FileKind.detect(input)) else {
                throw EngineError.unsupported(input.lastPathComponent)
            }
            let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true || (request.tool == .zip && values.isDirectory == true) else {
                throw EngineError.invalidFile(input.lastPathComponent)
            }
        }
        guard request.tool.grouped || inputs.count == 1 else { throw EngineError.invalidOptions }
        let destination = request.outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.isFileURL else { throw EngineError.invalidOptions }
        for input in inputs where FileKind.detect(input) == .folder {
            guard destination.path != input.path, !destination.path.hasPrefix(input.path + "/") else {
                throw EngineError.failed("اختر مجلد إخراج خارج المجلد المراد أرشفته / Output must be outside the source folder.")
            }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let scratch = destination.appendingPathComponent(".zawiya-work-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let input = inputs[0]
        let stem = String(input.deletingPathExtension().lastPathComponent.prefix(160))
        let output = scratch.appendingPathComponent("\(stem)-zawiya")
        var staged: [URL] = []
        switch request.tool {
        case .imagesToPDF:
            let doc = PDFDocument()
            for (index, source) in inputs.enumerated() {
                try cancellation.check()
                let cg = try readImage(source)
                guard let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) else { throw EngineError.invalidFile(source.lastPathComponent) }
                doc.insert(page, at: index)
            }
            let url = output.appendingPathExtension("pdf"); try writePDF(doc, to: url); staged = [url]
        case .mergePDF:
            let doc = PDFDocument()
            for source in inputs {
                let part = try readPDF(source)
                for index in 0..<part.pageCount {
                    try cancellation.check()
                    guard let page = part.page(at: index)?.copy() as? PDFPage else { throw EngineError.invalidFile(source.lastPathComponent) }
                    doc.insert(page, at: doc.pageCount)
                }
            }
            let url = output.appendingPathExtension("pdf"); try writePDF(doc, to: url); staged = [url]
        case .splitPDF:
            let source = try readPDF(input)
            for index in 0..<source.pageCount {
                try cancellation.check()
                let doc = PDFDocument()
                guard let page = source.page(at: index)?.copy() as? PDFPage else { throw EngineError.invalidFile(input.lastPathComponent) }
                doc.insert(page, at: 0)
                let url = output.appendingPathExtension("page-\(String(format: "%03d", index + 1)).pdf")
                try writePDF(doc, to: url); staged.append(url)
            }
        case .extractText:
            let text: String
            if FileKind.detect(input) == .pdf {
                let doc = try readPDF(input)
                var pages: [String] = []
                for i in 0..<doc.pageCount {
                    try cancellation.check()
                    guard let page = doc.page(at: i) else { continue }
                    let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    pages.append(embedded.isEmpty ? try recognize(try render(page, maxDimension: 3000), cancellation: cancellation) : embedded)
                }
                text = pages.joined(separator: "\n\n")
            } else { text = try recognize(try readImage(input), cancellation: cancellation) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.failed("لم يُكتشف نص قابل للاستخراج / No recognizable text found.") }
            let url = output.appendingPathExtension("txt"); try text.write(to: url, atomically: true, encoding: .utf8); staged = [url]
        case .zip:
            guard let executable = Engines.executable("zip") else { throw EngineError.missingEngine("zip") }
            let url = output.appendingPathExtension("zip")
            var common = inputs[0].deletingLastPathComponent()
            while !inputs.allSatisfy({ $0.path.hasPrefix(common.path == "/" ? "/" : common.path + "/") }) { common.deleteLastPathComponent() }
            let relative = inputs.map { String($0.path.dropFirst(common.path == "/" ? 1 : common.path.count + 1)) }
            try ProcessRunner.run(executable, ["-q", "-r", "-y", url.path, "--"] + relative, in: scratch, cancellation: cancellation, workingDirectory: common)
            staged = [url]
        case .convert where FileKind.detect(input) == .subtitle:
            guard Engines.formats(for: .subtitle).contains(request.options.format) else { throw EngineError.unsupported(request.options.format) }
            let url = output.appendingPathExtension(request.options.format)
            let text = try Subtitle.convert(String(contentsOf: input, encoding: .utf8), to: request.options.format)
            try text.write(to: url, atomically: true, encoding: .utf8); staged = [url]
        case .convert where FileKind.detect(input) == .pdf:
            let doc = try readPDF(input)
            let format = request.options.format
            guard Engines.formats(for: .pdf).contains(format) else { throw EngineError.unsupported(format) }
            if ["txt", "md"].contains(format) {
                let text = doc.string ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.failed("الـPDF مصوّر؛ استخدم استخراج النص OCR / Use OCR for this scanned PDF.") }
                let url = output.appendingPathExtension(format); try text.write(to: url, atomically: true, encoding: .utf8); staged = [url]
            } else {
                for i in 0..<doc.pageCount {
                    try cancellation.check()
                    guard let page = doc.page(at: i) else { continue }
                    let url = output.appendingPathExtension("page-\(String(format: "%03d", i + 1)).\(format)")
                    try writeImage(try render(page, maxDimension: request.options.maxDimension), to: url, format: format, quality: request.options.quality, scratch: scratch, cancellation: cancellation)
                    staged.append(url)
                }
            }
        case .convert where FileKind.detect(input) == .image,
             .compress where FileKind.detect(input) == .image,
             .resize where FileKind.detect(input) == .image,
             .stripMetadata where FileKind.detect(input) == .image:
            let format = request.tool == .resize || request.tool == .stripMetadata ? preferredImageFormat(input) : request.options.format
            guard Engines.formats(for: .image).contains(format) else { throw EngineError.unsupported(format) }
            let cg = try readImage(input, maxDimension: request.tool == .resize ? request.options.maxDimension : nil)
            let url = output.appendingPathExtension(format)
            if format == "pdf" {
                let doc = PDFDocument()
                guard let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) else { throw EngineError.invalidFile(input.lastPathComponent) }
                doc.insert(page, at: 0); try writePDF(doc, to: url)
            } else { try writeImage(cg, to: url, format: format, quality: request.options.quality, scratch: scratch, cancellation: cancellation) }
            staged = [url]
        case .convert, .compress, .stripMetadata, .trim, .videoFrame:
            guard let ffmpeg = Engines.executable("ffmpeg") else { throw EngineError.missingEngine("FFmpeg") }
            let kind = FileKind.detect(input)
            guard [.audio, .video].contains(kind) else { throw EngineError.unsupported(input.lastPathComponent) }
            let format: String
            switch request.tool {
            case .videoFrame: format = "png"
            case .stripMetadata: format = input.pathExtension.lowercased()
            case .compress, .trim: format = kind == .video ? "mp4" : "m4a"
            default: format = request.options.format
            }
            guard request.tool == .stripMetadata || request.tool == .videoFrame || Engines.formats(for: kind).contains(format) else { throw EngineError.unsupported(format) }
            let url = output.appendingPathExtension(format)
            var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe", "-format_whitelist", "mov,matroska,webm,avi,asf,mp3,wav,flac,ogg,aiff,aac", "-i", input.path]
            if request.tool == .trim { args += ["-ss", String(request.options.start), "-t", String(request.options.duration)] }
            if request.tool == .videoFrame {
                args += ["-ss", String(request.options.start), "-frames:v", "1", "-update", "1"]
            } else if request.tool == .stripMetadata { args += ["-map", "0", "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1"] }
            else { args += mediaArguments(format: format, quality: request.options.quality) + ["-map_metadata", "-1", "-map_chapters", "-1"] }
            args.append(url.path)
            try ProcessRunner.run(ffmpeg, args, in: scratch, cancellation: cancellation)
            staged = [url]
        default: throw EngineError.unsupported(request.tool.rawValue)
        }
        try cancellation.check()
        guard !staged.isEmpty else { throw EngineError.failed("لا توجد مخرجات / No output produced.") }
        var published: [URL] = []
        do {
            for source in staged {
                try cancellation.check()
                guard ((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { throw EngineError.failed("مخرج فارغ / Empty output.") }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                // Hard-link in the same destination volume: atomic, fails if a name already exists.
                let final = try Self.publish(source, to: destination)
                published.append(final)
            }
            return published
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
    }

    public static func publish(_ source: URL, to destination: URL) throws -> URL {
        for number in 0..<10000 {
            let suffix = number == 0 ? "" : "-\(number + 1)"
            let name = source.deletingPathExtension().lastPathComponent + suffix + "." + source.pathExtension
            let target = destination.appendingPathComponent(name)
            if link(source.path, target.path) == 0 { return target }
            if errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        throw EngineError.failed("تعذر إنشاء اسم إخراج فريد / Could not allocate an output name.")
    }

    private func readImage(_ url: URL, maxDimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000, width * height <= 100_000_000 else { throw EngineError.invalidFile(url.lastPathComponent) }
        let size = min(maxDimension ?? max(width, height), max(width, height))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw EngineError.invalidFile(url.lastPathComponent) }
        return image
    }

    private func preferredImageFormat(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let canonical = ext == "jpeg" ? "jpg" : ext == "tif" ? "tiff" : ext
        return Engines.formats(for: .image).contains(canonical) && canonical != "pdf" ? canonical : "png"
    }

    private func writeImage(_ cg: CGImage, to url: URL, format: String, quality: Int, scratch: URL, cancellation: Cancellation) throws {
        try cancellation.check()
        if format == "webp" {
            guard let encoder = Engines.executable("cwebp") else { throw EngineError.missingEngine("cwebp") }
            let png = scratch.appendingPathComponent("\(UUID().uuidString).png")
            try writeImage(cg, to: png, format: "png", quality: 100, scratch: scratch, cancellation: cancellation)
            try ProcessRunner.run(encoder, ["-quiet", "-q", String(quality), "-metadata", "none", png.path, "-o", url.path], in: scratch, cancellation: cancellation)
            return
        }
        let types = ["jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff", "bmp": "com.microsoft.bmp"]
        guard let type = types[format], let output = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw EngineError.unsupported(format) }
        var image = cg
        if format == "jpg" || format == "bmp" {
            guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EngineError.invalidFile("Image size") }
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let flattened = ctx.makeImage() else { throw EngineError.invalidFile("Image") }; image = flattened
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw EngineError.failed("تعذر كتابة الصورة / Image encoding failed.") }
    }

    private func readPDF(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0, doc.pageCount <= 2000 else { throw EngineError.invalidFile(url.lastPathComponent) }
        return doc
    }
    private func writePDF(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url), let check = PDFDocument(url: url), check.pageCount == doc.pageCount else { throw EngineError.failed("تعذر حفظ PDF / PDF write failed.") }
    }
    private func render(_ page: PDFPage, maxDimension: Int) throws -> CGImage {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { throw EngineError.invalidFile("PDF page") }
        let scale = Double(maxDimension) / max(rect.width, rect.height)
        let size = NSSize(width: max(1, rect.width * scale), height: max(1, rect.height * scale))
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw EngineError.invalidFile("PDF page") }
        return cg
    }
    public static func ocrLanguages() -> [String] { (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? [] }
    private func recognize(_ image: CGImage, cancellation: Cancellation) throws -> String {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        let wanted = supported.filter { $0.hasPrefix("ar") || $0 == "en-US" }
        if !wanted.isEmpty { request.recognitionLanguages = wanted }
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try cancellation.check()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private func mediaArguments(format: String, quality: Int) -> [String] {
        let crf = String(Int(18 + (100 - Double(quality)) * 0.32))
        let audioRate = "\(64 + quality * 192 / 100)k"
        switch format {
        case "mp4", "mov", "mkv": return ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "fast", "-crf", crf, "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"] + (format == "mkv" ? [] : ["-movflags", "+faststart"])
        case "webm": return ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libsvtav1", "-preset", "10", "-crf", crf, "-c:a", "libopus"]
        case "avi": return ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame"]
        case "gif": return ["-an", "-filter_complex", "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", String(max(0, min(9, (100 - quality) * 9 / 90)))]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", audioRate]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg", "opus": return ["-vn", "-c:a", "libopus", "-b:a", audioRate]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "wma": return ["-vn", "-c:a", "wmav1", "-b:a", "128k"]
        default: return []
        }
    }
}

public enum Subtitle {
    public static func convert(_ raw: String, to format: String) throws -> String {
        guard ["srt", "vtt", "txt"].contains(format), raw.utf8.count <= 20_000_000 else { throw EngineError.invalidOptions }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [(String, [String])] = []
        var index = 0
        let timePattern = try NSRegularExpression(pattern: #"^((?:\d{2,}:)?\d{2}:\d{2})[.,](\d{3})\s+-->\s+((?:\d{2,}:)?\d{2}:\d{2})[.,](\d{3})(?:\s+.*)?$"#)
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let match = timePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func capture(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
                func stamp(_ value: String, _ milliseconds: String) throws -> String {
                    let fields = value.split(separator: ":").compactMap { Int($0) }
                    guard (2...3).contains(fields.count), fields.suffix(2).allSatisfy({ (0...59).contains($0) }), fields.count == 2 || fields[0] <= 9999 else { throw EngineError.invalidFile("Subtitle timing") }
                    return (fields.count == 2 ? "00:" : "") + value + "." + milliseconds
                }
                let time = try stamp(capture(1), capture(2)) + " --> " + stamp(capture(3), capture(4))
                index += 1; var body: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[index]); index += 1 }
                cues.append((time, body))
            } else { index += 1 }
        }
        guard !cues.isEmpty else { throw EngineError.invalidFile("Subtitle timing") }
        if format == "txt" { return cues.flatMap(\.1).joined(separator: "\n") + "\n" }
        return (format == "vtt" ? "WEBVTT\n\n" : "") + cues.enumerated().map { i, cue in
            (format == "srt" ? "\(i + 1)\n" : "") + (format == "srt" ? cue.0.replacingOccurrences(of: ".", with: ",") : cue.0) + "\n" + cue.1.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }
}
