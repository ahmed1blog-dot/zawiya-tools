import XCTest
@testable import ZawiyaCore

final class AnnouncementTests: XCTestCase {
    private func json(_ changes: [String: Any] = [:]) -> Data {
        var base: [String: Any] = ["version": 1, "enabled": true, "id": "a1", "title_ar": "عنوان", "title_en": "Title", "body_ar": "نص", "body_en": "Body",
                                   "cta_ar": "افتح", "cta_en": "Open", "url": "https://ahmedqa.com", "image": "", "expires": "2027-12-31", "platforms": ["mac", "windows"]]
        changes.forEach { base[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: base)
    }
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!

    func testRepositoryBannerFileIsValid() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../announcements/banner.json").standardizedFileURL
        XCTAssertNotNil(Announcement.validated(try Data(contentsOf: file), platform: "mac", now: now))
    }
    func testAcceptsValidBanner() { XCTAssertEqual(Announcement.validated(json(), now: now)?.id, "a1") }
    func testRejectsUnsafeOrStaleBanners() {
        let rejected: [[String: Any]] = [
            ["enabled": false], ["version": 2], ["url": "http://ahmedqa.com"], ["url": "javascript:alert(1)"], ["expires": "2026-10-01"], ["expires": "soon"],
            ["platforms": ["windows"]], ["title_en": String(repeating: "x", count: 61)], ["body_ar": String(repeating: "ن", count: 161)], ["cta_en": ""],
            ["image": "https://evil.example/a.png"], ["image": "https://raw.githubusercontent.com/ahmed1blog-dot/zawiya-tools/main/announcements/../../x.png"]
        ]
        for change in rejected { XCTAssertNil(Announcement.validated(json(change), now: now), "\(change)") }
        XCTAssertNil(Announcement.validated(Data(repeating: 32, count: Announcement.maxBytes + 1), now: now))
        XCTAssertNil(Announcement.validated(Data("not json".utf8), now: now))
    }
    func testAcceptsImageFromOwnRepositoryAndExpiryDay() {
        XCTAssertNotNil(Announcement.validated(json(["image": Announcement.imagePrefix + "banner.png", "expires": "2026-10-19"]), now: now))
    }
}
