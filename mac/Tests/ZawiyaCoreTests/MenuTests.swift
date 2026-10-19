import XCTest
import AppKit
@testable import ZawiyaApp
import ZawiyaCore

final class MenuTests: XCTestCase {
    func testVideoMenuIncludesTheNinthFormat() throws {
        guard Engines.executable("ffmpeg") != nil else { throw XCTSkip("FFmpeg unavailable") }
        let formats = MenuCatalog.commonFormats(for: [.video])
        XCTAssertGreaterThan(formats.count, 8)
        XCTAssertTrue(formats.contains("wav"))
        XCTAssertEqual(Set(formats), Set(Engines.formats(for: .video)))
    }
    func testFavoritesReorderWithoutHidingOrDuplicatingOptions() {
        XCTAssertEqual(MenuCatalog.ordered(["mp4", "mov", "wav"], favorites: ["wav", "wav", "pdf"]), ["wav", "mp4", "mov"])
    }
    func testSearchAndCompatibilityCoverAllTools() {
        XCTAssertEqual(MenuCatalog.matchingTools("").count, Tool.allCases.count)
        XCTAssertEqual(MenuCatalog.matchingTools("ocr"), [.extractText])
        XCTAssertEqual(MenuCatalog.matchingTools("قص"), [.trim])
        XCTAssertEqual(Set(MenuCatalog.matchingTools("PDF")), Set([.imagesToPDF, .mergePDF, .splitPDF]))
        XCTAssertFalse(MenuCatalog.tools(for: [.image]).contains(.mergePDF))
        XCTAssertTrue(MenuCatalog.tools(for: [.image]).contains(.resize))
        XCTAssertEqual(Set(MenuCatalog.tools(for: [.pdf, .audio])), Set([.zip]))
    }
    func testWheelTargetsNeverOverlapOrEscapeTheCanvas() {
        for count in 1...24 {
            let geometry = WheelGeometry(count: count)
            XCTAssertEqual(geometry.frames.count, count)
            let canvas = CGRect(origin: .zero, size: geometry.size)
            for (i, frame) in geometry.frames.enumerated() {
                XCTAssertTrue(canvas.contains(frame), "\(count) options, target \(i)")
                XCTAssertFalse(frame.intersects(geometry.centerFrame))
                for j in geometry.frames.indices where j > i { XCTAssertFalse(frame.intersects(geometry.frames[j]), "\(count) options: \(i) overlaps \(j)") }
            }
        }
    }
    func testWheelStaysOnItsScreenAtEveryCorner() {
        for screen in [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: -1920, y: -100, width: 1920, height: 1080)] {
            for point in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.minY), CGPoint(x: screen.minX, y: screen.maxY), CGPoint(x: screen.maxX, y: screen.maxY)] {
                let frame = WheelGeometry.presentationFrame(size: WheelGeometry(count: 18).size, pointer: point, screen: screen)
                XCTAssertTrue(screen.insetBy(dx: 11, dy: 11).contains(frame))
            }
        }
    }
    @MainActor func testToolSelectionUpdatesTheSetupAndDismissesSearch() {
        let workspace = Workspace()
        workspace.add([URL(fileURLWithPath: "/tmp/zawiya-menu.png")])
        workspace.section = "settings"; workspace.showToolBrowser = true
        workspace.selectTool(.resize)
        XCTAssertEqual(workspace.tool, .resize); XCTAssertEqual(workspace.section, "workspace"); XCTAssertFalse(workspace.showToolBrowser)
        workspace.options.format = "png"; workspace.selectFormat("unsupported"); XCTAssertEqual(workspace.options.format, "png")
        workspace.selectTool(.mergePDF); XCTAssertFalse(workspace.canRun)
    }
    @MainActor func testFavoriteChangesAndMotionCanBeDisabledWithoutPersistence() {
        let preferences = Preferences(persist: false)
        preferences.favoriteFormats = ["jpg", "png"]
        preferences.toggleFavorite("jpg"); XCTAssertEqual(preferences.favoriteFormats, ["png"])
        preferences.toggleFavorite("webp"); XCTAssertEqual(preferences.favoriteFormats, ["png", "webp"])
        preferences.animationsEnabled = false; XCTAssertFalse(preferences.nativeMotion)
    }
}
