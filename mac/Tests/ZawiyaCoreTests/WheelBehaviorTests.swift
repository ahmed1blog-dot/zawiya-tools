import XCTest
import AppKit
import ZawiyaCore
@testable import ZawiyaApp

final class WheelBehaviorTests: XCTestCase {
    @MainActor func testEveryWheelExposesItsCompleteAccessibleTargets() {
        let preferences = Preferences(persist: false)
        preferences.soundsEnabled = false; preferences.hapticsEnabled = false
        let workspace = Workspace(), image = URL(fileURLWithPath: "/tmp/quality.png")
        let wheel = DragWheel(workspace: workspace, preferences: preferences)
        for (mode, expected) in [("convert", Engines.formats(for: .image).count), ("tools", MenuCatalog.tools(for: [.image]).filter { $0 != .convert }.count), ("actions", 6)] {
            let root = wheel.preview(mode: mode, urls: [image])
            let cells = root.subviews.compactMap { $0 as? WheelDropView }
            XCTAssertEqual(cells.count, expected)
            XCTAssertTrue(cells.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityRole() == .button && !($0.accessibilityLabel() ?? "").isEmpty })
            XCTAssertEqual(Set(cells.map(\.title)).count, expected)
            for cell in cells { XCTAssertNotNil(NSImage(systemSymbolName: cell.symbol, accessibilityDescription: nil), "Missing icon: \(cell.title)") }
        }
    }
    @MainActor func testAccessiblePressDispatchesTheOriginalFileReferencesOnce() {
        let urls = [URL(fileURLWithPath: "/tmp/اسم عربي.png")]
        var received: [[URL]] = []
        let cell = WheelDropView(title: "WEBP", symbol: "photo", dark: false, motion: false, urls: urls, hover: { _ in }) { received.append($0) }
        XCTAssertTrue(cell.accessibilityPerformPress())
        XCTAssertEqual(received, [urls])
    }
    @MainActor func testFinishedVideoRetainsItsMenusUntilNewPendingFilesAreAdded() {
        let workspace = Workspace()
        workspace.add([URL(fileURLWithPath: "/tmp/video.mp4")])
        let formats = workspace.formats
        workspace.items[0].state = .done
        XCTAssertEqual(workspace.formats, formats)
        XCTAssertFalse(workspace.compatibleTools.contains(.mergePDF))
        workspace.add([URL(fileURLWithPath: "/tmp/new.png")])
        XCTAssertEqual(workspace.formats, Engines.formats(for: .image))
        XCTAssertTrue(workspace.compatibleTools.contains(.resize))
    }
}
