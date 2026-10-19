import Foundation

/// Remote banner edited by the author in `announcements/banner.json` on GitHub.
/// Anything that fails validation is ignored, so a bad edit can only hide the banner.
public struct Announcement: Codable, Equatable, Sendable {
    public static let feed = URL(string: "https://raw.githubusercontent.com/ahmed1blog-dot/zawiya-tools/main/announcements/banner.json")!
    public static let imagePrefix = "https://raw.githubusercontent.com/ahmed1blog-dot/zawiya-tools/main/announcements/"
    public static let maxBytes = 64 * 1024

    public var version: Int
    public var enabled: Bool
    public var id: String
    public var title_ar, title_en, body_ar, body_en, cta_ar, cta_en: String
    public var url: String
    public var image: String?
    public var expires: String
    public var platforms: [String]

    public func title(_ arabic: Bool) -> String { arabic ? title_ar : title_en }
    public func body(_ arabic: Bool) -> String { arabic ? body_ar : body_en }
    public func cta(_ arabic: Bool) -> String { arabic ? cta_ar : cta_en }
    public var link: URL? { URL(string: url) }
    public var imageURL: URL? { image.flatMap { $0.isEmpty ? nil : URL(string: $0) } }

    public static func validated(_ data: Data, platform: String = "mac", now: Date = Date()) -> Announcement? {
        guard data.count <= maxBytes, let item = try? JSONDecoder().decode(Announcement.self, from: data) else { return nil }
        guard item.version == 1, item.enabled, item.platforms.contains(platform),
              (1...64).contains(item.id.count),
              [item.title_ar, item.title_en].allSatisfy({ (1...60).contains($0.count) }),
              [item.body_ar, item.body_en].allSatisfy({ $0.count <= 160 }),
              [item.cta_ar, item.cta_en].allSatisfy({ (1...24).contains($0.count) }),
              let link = URL(string: item.url), link.scheme == "https", link.host != nil else { return nil }
        if let image = item.image, !image.isEmpty {
            guard image.hasPrefix(imagePrefix), !image.contains(".."), URL(string: image) != nil else { return nil }
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "yyyy-MM-dd"
        guard let expiry = formatter.date(from: item.expires), now < expiry.addingTimeInterval(86_400) else { return nil }
        return item
    }
}
