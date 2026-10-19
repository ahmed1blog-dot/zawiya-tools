import XCTest
import AppKit
import ImageIO
import PDFKit
import ZawiyaCore
@testable import ZawiyaApp

final class QuickActionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zawiya-quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image(_ url: URL, width: Int = 80) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: 40))
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dst, try XCTUnwrap(ctx.makeImage()), [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "PRIVATE-CAPTION"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
    }
    @MainActor private func wait(_ actions: QuickActions) async throws {
        let deadline = Date().addingTimeInterval(15)
        while actions.isProcessing && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(actions.isProcessing)
    }
    func testOnlyToolsWithDeterministicInputsRunImmediately() {
        XCTAssertTrue([Tool.convert, .stripMetadata, .imagesToPDF, .mergePDF, .splitPDF, .extractText, .zip].allSatisfy(\.runsImmediatelyFromWheel))
        XCTAssertFalse([Tool.compress, .resize, .trim, .videoFrame].contains(where: \.runsImmediatelyFromWheel))
    }
    @MainActor func testMetadataDropRunsWithoutOpeningOrChangingDashboardAndPreservesOriginal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("صورة.png"); try image(source)
        let original = try Data(contentsOf: source)
        let originalImage = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalImage, 0, nil) as? [String: Any])
        XCTAssertNotNil((properties[kCGImagePropertyPNGDictionary as String] as? [String: Any])?[kCGImagePropertyPNGDescription as String])
        let workspace = Workspace(); workspace.add([source]); workspace.tool = .resize
        workspace.options.start = .nan; workspace.options.quality = 17; workspace.section = "settings"
        let ids = workspace.items.map(\.id); var presentations = 0; workspace.presentMain = { presentations += 1 }
        workspace.wheelTool([source], tool: .stripMetadata)
        try await wait(workspace.quickActions)
        let job = try XCTUnwrap(workspace.quickActions.jobs.last)
        XCTAssertEqual(job.state, .done); XCTAssertEqual(job.outputs.count, 1)
        XCTAssertEqual(presentations, 0); XCTAssertEqual(workspace.section, "settings")
        XCTAssertEqual(workspace.items.map(\.id), ids); XCTAssertEqual(workspace.tool, .resize)
        XCTAssertEqual(workspace.options.quality, 17); XCTAssertTrue(workspace.options.start.isNaN)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let cleaned = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(job.outputs.first) as CFURL, nil))
        let resultProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(cleaned, 0, nil) as? [String: Any])
        XCTAssertNil((resultProperties[kCGImagePropertyPNGDictionary as String] as? [String: Any])?[kCGImagePropertyPNGDescription as String])
    }
    @MainActor func testImagesToPDFPreservesPageOrderAndTwoQuickJobsQueueWithoutOverwriting() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("أ.png"), second = root.appendingPathComponent("ب.png")
        try image(first, width: 80); try image(second, width: 120)
        let workspace = Workspace(); var presentations = 0; workspace.presentMain = { presentations += 1 }
        workspace.wheelTool([first, second], tool: .imagesToPDF)
        workspace.wheelTool([first, second], tool: .imagesToPDF)
        try await wait(workspace.quickActions)
        XCTAssertEqual(presentations, 0); XCTAssertTrue(workspace.items.isEmpty)
        XCTAssertEqual(workspace.quickActions.jobs.count, 2)
        let outputs = workspace.quickActions.jobs.flatMap(\.outputs)
        XCTAssertEqual(Set(outputs).count, 2)
        for url in outputs {
            let pdf = try XCTUnwrap(PDFDocument(url: url)); XCTAssertEqual(pdf.pageCount, 2)
            XCTAssertLessThan(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).width, try XCTUnwrap(pdf.page(at: 1)).bounds(for: .mediaBox).width)
        }
    }
    @MainActor func testPDFConversionCreatesOneCopyPerImageAndUsesChosenDestination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.png"), second = root.appendingPathComponent("two.png")
        try image(first); try image(second)
        let workspace = Workspace(); workspace.outputDirectory = root.appendingPathComponent("chosen")
        workspace.wheelConvert([first, second], format: "pdf")
        try await wait(workspace.quickActions)
        let job = try XCTUnwrap(workspace.quickActions.jobs.last)
        XCTAssertEqual(job.state, .done); XCTAssertEqual(job.outputs.count, 2)
        for url in job.outputs { XCTAssertEqual(url.deletingLastPathComponent().path, workspace.outputDirectory?.path); XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1) }
    }
    @MainActor func testPartialFailureReportsTheBadFileAndRetainsSuccessfulResults() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("good.png"), bad = root.appendingPathComponent("bad.png")
        try image(good); try Data("not an image".utf8).write(to: bad)
        let actions = QuickActions(); actions.submit([good, bad], tool: .stripMetadata)
        try await wait(actions)
        let job = try XCTUnwrap(actions.jobs.last)
        XCTAssertEqual(job.state, .failed); XCTAssertEqual(job.processed, 2)
        XCTAssertEqual(job.errors.count, 1); XCTAssertTrue(job.errors[0].contains("bad.png"))
        XCTAssertEqual(job.outputs.count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: job.outputs[0].path))
        actions.submit([good], tool: .convert, format: "unsupported")
        XCTAssertEqual(actions.visibleJob?.state, .failed)
    }
    @MainActor func testCancellingQueuedDropsDoesNotCreateFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"); try image(source)
        let actions = QuickActions()
        actions.submit([source], tool: .stripMetadata); actions.submit([source], tool: .imagesToPDF)
        actions.cancelAll(); try await wait(actions)
        XCTAssertTrue(actions.jobs.allSatisfy { $0.state == .cancelled && $0.outputs.isEmpty })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Zawiya Exports").path))
    }
    @MainActor func testToolsThatNeedInputStillOpenSetupWithoutStartingQuickJobs() {
        let workspace = Workspace(); var presentations = 0; workspace.presentMain = { presentations += 1 }
        workspace.wheelTool([URL(fileURLWithPath: "/tmp/video.mp4")], tool: .trim)
        XCTAssertEqual(presentations, 1); XCTAssertEqual(workspace.tool, .trim)
        XCTAssertEqual(workspace.section, "workspace"); XCTAssertFalse(workspace.isRunning)
        XCTAssertTrue(workspace.quickActions.jobs.isEmpty)
    }
}
