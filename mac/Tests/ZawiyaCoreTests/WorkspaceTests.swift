import XCTest
import AppKit
import ImageIO
@testable import ZawiyaApp
import ZawiyaCore

final class WorkspaceTests: XCTestCase {
    @MainActor func testQueueExecutesAndPublishesARealImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zawiya-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("صورة واجهة.png")
        let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.green.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        let workspace = Workspace()
        workspace.add([source]); workspace.options.format = "jpg"
        XCTAssertTrue(workspace.canRun)
        workspace.start()
        let deadline = Date().addingTimeInterval(10)
        while workspace.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertFalse(workspace.isRunning); XCTAssertEqual(workspace.items[0].state, .done)
        XCTAssertEqual(workspace.completed, 1); XCTAssertTrue(workspace.pending.isEmpty)
        let output = try XCTUnwrap(workspace.items[0].outputs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path)); XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertGreaterThan(workspace.items[0].outputBytes, 0)
        workspace.requeueAll()
        XCTAssertTrue(workspace.canRun); XCTAssertEqual(workspace.completed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        workspace.start()
        let repeatDeadline = Date().addingTimeInterval(10)
        while workspace.isRunning && Date() < repeatDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertEqual(workspace.items[0].state, .done)
        XCTAssertNotEqual(workspace.items[0].outputs.first, output)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    @MainActor func testMixedQueueDoesNotRunAnIncompatibleTool() {
        let workspace = Workspace()
        workspace.add([URL(fileURLWithPath: "/tmp/image.png"), URL(fileURLWithPath: "/tmp/audio.wav")])
        XCTAssertTrue(workspace.formats.isEmpty); XCTAssertFalse(workspace.canRun)
        workspace.tool = .mergePDF
        workspace.start()
        XCTAssertFalse(workspace.isRunning); XCTAssertNotNil(workspace.message)
    }
}
