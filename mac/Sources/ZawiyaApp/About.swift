import SwiftUI
import AppKit
import Combine
import Sparkle
import ZawiyaCore

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static let website = URL(string: "https://ahmedqa.com")!
    static let instagram = URL(string: "https://instagram.com/qqad7")!
    static let repository = URL(string: "https://github.com/ahmed1blog-dot/zawiya-tools")!
    static func author(_ arabic: Bool) -> String { arabic ? "أحمد مروان" : "Ahmed Marwan" }

    @MainActor static func showAboutPanel(arabic: Bool) {
        let credits = NSMutableAttributedString(string: "\(arabic ? "تطوير" : "Made by") \(author(arabic))\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        for (title, url) in [("ahmedqa.com", website), ("Instagram @qqad7", instagram), ("GitHub · GPL-3.0", repository)] {
            credits.append(NSAttributedString(string: title + "\n", attributes: [.link: url, .font: NSFont.systemFont(ofSize: 11)]))
        }
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .init(rawValue: "Copyright"): "© 2026 \(author(arabic))"])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Sparkle checks the GitHub appcast, downloads in the background and installs on quit.
@MainActor final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    @Published private(set) var canCheck = false
    @Published var automatic: Bool { didSet { controller?.updater.automaticallyDownloadsUpdates = automatic } }

    init() {
        // A build without a feed (swift run, tests) must not start Sparkle and show feed errors.
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        automatic = controller?.updater.automaticallyDownloadsUpdates ?? false
        observation = controller?.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.canCheck = value }
        }
    }
    var available: Bool { controller != nil }
    func check() { controller?.checkForUpdates(nil) }
}

@MainActor final class AnnouncementStore: ObservableObject {
    @Published private(set) var current: Announcement?
    @Published var dismissedID: String { didSet { UserDefaults.standard.set(dismissedID, forKey: "dismissedAnnouncement") } }
    private var timer: Timer?
    private let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Zawiya Tools", isDirectory: true).appendingPathComponent("banner.json")

    init() {
        dismissedID = UserDefaults.standard.string(forKey: "dismissedAnnouncement") ?? ""
        current = (try? Data(contentsOf: cache)).flatMap { Announcement.validated($0) }
    }
    var visible: Announcement? { current.flatMap { $0.id == dismissedID ? nil : $0 } }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        timer.tolerance = 600; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    func refresh() async {
        var request = URLRequest(url: Announcement.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("ZawiyaTools/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        // Ephemeral: no cookies or cache, and nothing about the user or their files is sent.
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return } // offline: keep the cached banner
        current = Announcement.validated(data)
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if current != nil { try? data.write(to: cache, options: .atomic) } else { try? FileManager.default.removeItem(at: cache) }
    }
}

struct AnnouncementCard: View {
    @ObservedObject var store: AnnouncementStore
    let arabic: Bool
    let dark: Bool
    var body: some View {
        if let item = store.visible {
            VStack(alignment: .leading, spacing: 8) {
                if let image = item.imageURL {
                    AsyncImage(url: image) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(height: 50).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(alignment: .top) {
                    Text(item.title(arabic)).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.dismissedID = item.id } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Brand.muted(dark)).accessibilityLabel(arabic ? "إخفاء الإعلان" : "Hide announcement")
                }
                if !item.body(arabic).isEmpty { Text(item.body(arabic)).font(.system(size: 10)).foregroundStyle(Brand.muted(dark)).fixedSize(horizontal: false, vertical: true) }
                if let link = item.link {
                    Button(item.cta(arabic)) { NSWorkspace.shared.open(link) }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accent(dark))
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.accent(dark).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.accent(dark).opacity(0.25), lineWidth: 1))
                .accessibilityElement(children: .contain)
        }
    }
}

struct CreditsView: View {
    let arabic: Bool
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZawiyaMark(color: Brand.accent(dark)).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zawiya Tools v\(AppInfo.version)").font(.system(size: 13, weight: .semibold)).environment(\.layoutDirection, .leftToRight)
                    Text("\(arabic ? "تطوير" : "Made by") \(AppInfo.author(arabic)) · © 2026").font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
                }
            }
            HStack(spacing: 14) {
                Link("ahmedqa.com", destination: AppInfo.website)
                Link("Instagram @qqad7", destination: AppInfo.instagram)
                Link("GitHub", destination: AppInfo.repository)
            }.font(.system(size: 12, weight: .medium)).tint(Brand.accent(dark)).environment(\.layoutDirection, .leftToRight)
            Text(arabic ? "مفتوح المصدر برخصة GPL-3.0. أي نسخة معدلة يجب أن تحتفظ بهذه الحقوق وتبقى مفتوحة المصدر." : "Open source under GPL-3.0. Modified versions must keep this notice and stay open source.")
                .font(.system(size: 11)).foregroundStyle(Brand.muted(dark)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
