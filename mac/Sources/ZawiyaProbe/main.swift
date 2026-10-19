import Foundation
import AppKit
import CoreText
import ImageIO
import PDFKit
import ZawiyaCore

func makeImage(width: Int = 1200, height: Int = 800, arabic: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.027, green: 0.031, blue: 0.043, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.055, green: 0.647, blue: 0.914, alpha: 1)); context.fillEllipse(in: CGRect(x: 100, y: 200, width: 320, height: 320))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
    let text = NSAttributedString(string: "ZAWIYA TOOLS", attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor.white])
    context.textPosition = CGPoint(x: 90, y: 650); CTLineDraw(CTLineCreateWithAttributedString(text), context)
    if arabic {
        let text = NSAttributedString(string: "أداة زاوية", attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("GeezaPro" as CFString, 92, nil), kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor.white])
        context.textPosition = CGPoint(x: 550, y: 430); CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    return context.makeImage()!
}
func png(_ image: CGImage, _ url: URL) {
    let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil); precondition(CGImageDestinationFinalize(output))
}
func makeIcon(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["icon_64x64.png", "icon_64x64@2x.png"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = Double(size) / 1024
        context.scaleBy(x: s, y: s)
        // Ahmed Marwan icon style: sky-to-blue gradient tile with a white mark (34-unit grid scaled to the tile).
        let tile = CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960), cornerWidth: 210, cornerHeight: 210, transform: nil)
        context.saveGState(); context.addPath(tile); context.clip()
        let colors = [CGColor(red: 56/255, green: 189/255, blue: 248/255, alpha: 1), CGColor(red: 37/255, green: 99/255, blue: 235/255, alpha: 1)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!, start: CGPoint(x: 32, y: 992), end: CGPoint(x: 992, y: 32), options: [])
        context.restoreGState()
        // Mark coordinates are top-left based; CoreGraphics is bottom-left, so y is flipped.
        let u = 20.0, ox = 176.0, top = 880.0
        let p = { (x: Double, y: Double) in CGPoint(x: ox + x * u, y: top - y * u) }
        context.setStrokeColor(CGColor.white); context.setLineWidth(2.6 * u); context.setLineCap(.round); context.setLineJoin(.round)
        context.move(to: p(29, 27)); context.addLine(to: p(7, 27)); context.addLine(to: p(22, 7)); context.strokePath()
        context.addArc(center: p(7, 27), radius: 10 * u, startAngle: 0, endAngle: 53.13 * .pi / 180, clockwise: false); context.strokePath()
        context.setFillColor(CGColor.white); context.fillEllipse(in: CGRect(x: ox + 4.2 * u, y: top - 29.8 * u, width: 5.6 * u, height: 5.6 * u))
        let image = context.makeImage()!
        if [16, 32, 128, 256, 512].contains(size) { png(image, folder.appendingPathComponent("icon_\(size)x\(size).png")) }
        if [16, 32, 128, 256, 512].contains(size / 2) { png(image, folder.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
    }
}

let args = CommandLine.arguments
if args.count > 2, args[1] == "--icon" { try makeIcon(URL(fileURLWithPath: args[2])); exit(0) }
if args.count > 2, args[1] == "--arabic-ocr" {
    let directory = URL(fileURLWithPath: args[2], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("عينة OCR عربي.png")
    png(makeImage(arabic: true), source)
    let outputs = try Converter().run(JobRequest(inputs: [source], outputDirectory: directory, tool: .extractText, options: Options()))
    let result = try String(contentsOf: outputs[0], encoding: .utf8)
    print(result)
    guard result.contains("زاوية"), result.contains("أداة") else { fputs("Arabic OCR assertion failed\n", stderr); exit(1) }
    print("PASS Arabic OCR: أداة زاوية")
    let scanned = try Converter().run(JobRequest(inputs: [source], outputDirectory: directory, tool: .imagesToPDF, options: Options()))[0]
    let pdfText = try Converter().run(JobRequest(inputs: [scanned], outputDirectory: directory, tool: .extractText, options: Options()))[0]
    let extracted = try String(contentsOf: pdfText, encoding: .utf8)
    guard extracted.contains("زاوية"), extracted.contains("أداة") else { fputs("Scanned PDF Arabic OCR assertion failed\n", stderr); exit(1) }
    print("PASS Arabic scanned PDF OCR: أداة زاوية")
    let report = try JSONSerialization.data(withJSONObject: ["imageOCR": result, "scannedPDFOCR": extracted, "passed": 2, "total": 2], options: [.prettyPrinted, .sortedKeys])
    try report.write(to: directory.appendingPathComponent("arabic-ocr.json"))
    exit(0)
}
guard args.count > 2, args[1] == "--verify" else { print("ZawiyaProbe --verify <scratch-directory> | --icon <iconset-directory>"); exit(0) }
let root = URL(fileURLWithPath: args[2], isDirectory: true)
let input = root.appendingPathComponent("fixtures", isDirectory: true)
let output = root.appendingPathComponent("results", isDirectory: true)
try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
let source = input.appendingPathComponent("منتج زاوية.png")
png(makeImage(), source)
let pdf = input.appendingPathComponent("مستند زاوية.pdf")
let context = CGContext(pdf as CFURL, mediaBox: nil, nil)!
for i in 1...2 {
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 60, y: 650)
    let text = NSAttributedString(string: "Zawiya Tools - Page \(i)", attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 30, nil)])
    CTLineDraw(CTLineCreateWithAttributedString(text), context); context.endPDFPage()
}
context.closePDF()
let subtitle = input.appendingPathComponent("ترجمة.srt")
try "1\n00:00:00,000 --> 00:00:01,000\nمرحبًا من أداة زاوية\n\n2\n00:00:01,000 --> 00:00:02,000\nZawiya Tools\n".write(to: subtitle, atomically: true, encoding: .utf8)
let token = Cancellation()
let video = input.appendingPathComponent("فيديو زاوية.mp4")
let audio = input.appendingPathComponent("صوت زاوية.wav")
if let ffmpeg = Engines.executable("ffmpeg") {
    try ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path], in: root, cancellation: token)
    try ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "2", audio.path], in: root, cancellation: token)
}
var report: [[String: Any]] = []
func check(_ name: String, _ files: [URL], _ tool: Tool, _ options: Options = Options()) {
    let start = Date()
    do {
        let results = try Converter().run(JobRequest(inputs: files, outputDirectory: output, tool: tool, options: options))
        for url in results {
            let kind = FileKind.detect(url)
            if kind == .image { guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw EngineError.invalidFile(url.lastPathComponent) } }
            if kind == .pdf { guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw EngineError.invalidFile(url.lastPathComponent) } }
            if [.audio, .video].contains(kind), let ffmpeg = Engines.executable("ffmpeg") {
                try ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-protocol_whitelist", "file,pipe", "-i", url.path, "-f", "null", "-"], in: root, cancellation: token)
            }
        }
        report.append(["name": name, "passed": true, "outputs": results.map(\.lastPathComponent), "seconds": Date().timeIntervalSince(start)])
        print("PASS \(name)")
    } catch { report.append(["name": name, "passed": false, "error": error.localizedDescription]); print("FAIL \(name): \(error.localizedDescription)") }
}
for (kind, url) in [(FileKind.image, source), (.video, video), (.audio, audio), (.pdf, pdf), (.subtitle, subtitle)] {
    for format in Engines.formats(for: kind) { var options = Options(); options.format = format; check("\(kind.rawValue) → \(format)", [url], .convert, options) }
}
var resize = Options(); resize.maxDimension = 800
check("resize", [source], .resize, resize)
check("image metadata", [source], .stripMetadata)
var web = Options(); web.format = "webp"; check("image compress", [source], .compress, web)
check("video compress", [video], .compress)
check("audio compress", [audio], .compress)
check("video metadata", [video], .stripMetadata)
check("audio metadata", [audio], .stripMetadata)
var trim = Options(); trim.start = 0.5; trim.duration = 1
check("trim video", [video], .trim, trim); check("trim audio", [audio], .trim, trim)
check("video frame", [video], .videoFrame, trim)
check("images to PDF", [source, source], .imagesToPDF)
check("merge PDF", [pdf, pdf], .mergePDF)
check("split PDF", [pdf], .splitPDF)
check("PDF text", [pdf], .extractText)
check("image OCR", [source], .extractText)
check("ZIP files", [source, subtitle], .zip)
let data = try JSONSerialization.data(withJSONObject: ["results": report, "ocrLanguages": Converter.ocrLanguages(), "passed": report.filter { $0["passed"] as? Bool == true }.count, "total": report.count], options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("verification.json"))
print("\(report.filter { $0["passed"] as? Bool == true }.count)/\(report.count) passed")
if report.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
