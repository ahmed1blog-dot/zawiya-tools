import XCTest
import AppKit
import ImageIO
@testable import ZawiyaCore

final class SafetyTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("zawiya-tests-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func image(named name: String = "original.png") throws -> URL {
        let url = root.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let out = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(out, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(out)); return url
    }
    func testOriginalAndExistingOutputArePreserved() throws {
        let source = try image(); let before = try Data(contentsOf: source)
        var options = Options(); options.format = "jpg"
        let request = JobRequest(inputs: [source], outputDirectory: root, tool: .convert, options: options)
        let first = try Converter().run(request)[0]; let firstData = try Data(contentsOf: first)
        let second = try Converter().run(request)[0]
        XCTAssertNotEqual(first, second); XCTAssertEqual(try Data(contentsOf: source), before); XCTAssertEqual(try Data(contentsOf: first), firstData)
    }
    func testHostileNamesAreData() throws {
        let source = try image(named: "صورة $(touch hacked) ' ;.png")
        var options = Options(); options.format = "webp"
        guard Engines.executable("cwebp") != nil else { throw XCTSkip("cwebp not installed") }
        let outputs = try Converter().run(JobRequest(inputs: [source], outputDirectory: root, tool: .convert, options: options))
        XCTAssertEqual(outputs.count, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hacked").path))
    }
    func testMalformedImageAndInvalidFormatFailClosed() throws {
        let bad = root.appendingPathComponent("fake.png"); try Data("not an image".utf8).write(to: bad)
        XCTAssertThrowsError(try Converter().run(JobRequest(inputs: [bad], outputDirectory: root, tool: .convert, options: Options())))
        let source = try image(); var options = Options(); options.format = "../../escape"
        XCTAssertThrowsError(try Converter().run(JobRequest(inputs: [source], outputDirectory: root, tool: .convert, options: options)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".zawiya-work-") }))
    }
    func testCancelledJobWritesNothing() throws {
        let source = try image(); let token = Cancellation(); token.cancel()
        XCTAssertThrowsError(try Converter().run(JobRequest(inputs: [source], outputDirectory: root, tool: .resize, options: Options()), cancellation: token))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }
    func testConcurrentPublicationNeverOverwrites() throws {
        let source = root.appendingPathComponent("result.txt"); try Data("proof".utf8).write(to: source)
        let destination = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let lock = NSLock(); var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { _ = try Converter.publish(source, to: destination) } catch { lock.lock(); failures.append(error); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty); let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 20); for file in files { XCTAssertEqual(try Data(contentsOf: file), Data("proof".utf8)) }
    }
    func testArchiveCannotIncludeItsOutput() throws {
        let destination = root.appendingPathComponent("nested")
        XCTAssertThrowsError(try Converter().run(JobRequest(inputs: [root], outputDirectory: destination, tool: .zip, options: Options())))
    }
    func testSubtitleRetainsArabicAndTiming() throws {
        let srt = "1\r\n00:00:01,200 --> 00:00:02,300\r\nأداة زاوية\r\n"
        let vtt = try Subtitle.convert(srt, to: "vtt")
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n")); XCTAssertTrue(vtt.contains("00:00:01.200 --> 00:00:02.300")); XCTAssertTrue(vtt.contains("أداة زاوية"))
        let roundtrip = try Subtitle.convert(vtt, to: "srt"); XCTAssertTrue(roundtrip.contains("00:00:01,200"))
    }
    func testInvalidNumericOptionsAreRejected() throws {
        let source = try image(); var options = Options(); options.start = .nan
        XCTAssertThrowsError(try Converter().run(JobRequest(inputs: [source], outputDirectory: root, tool: .resize, options: options)))
    }
    func testSubtitleHandlesWebVTTShortTimestampsAndWhitespace() throws {
        let result = try Subtitle.convert("WEBVTT\n\n00:01.200\t-->\t00:02.300 align:start\nزاوية\n", to: "srt")
        XCTAssertTrue(result.contains("00:00:01,200 --> 00:00:02,300"))
        XCTAssertFalse(result.contains("align:start"))
    }
    func testDisguisedPlaylistIsRejected() throws {
        guard Engines.executable("ffmpeg") != nil else { throw XCTSkip("FFmpeg unavailable") }
        let source = root.appendingPathComponent("disguised.mp4")
        try "#EXTM3U\n#EXTINF:1,\nhttp://127.0.0.1:1/should-never-be-requested.ts\n".write(to: source, atomically: true, encoding: .utf8)
        var options = Options(); options.format = "mp4"
        XCTAssertThrowsError(try Converter().run(JobRequest(inputs: [source], outputDirectory: root, tool: .convert, options: options)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.contains("zawiya") }))
    }
    func testRunningSubprocessCanBeCancelled() throws {
        guard let ffmpeg = Engines.executable("ffmpeg") else { throw XCTSkip("FFmpeg unavailable") }
        let token = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-re", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "30", "-f", "null", "-"], in: root, cancellation: token))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
