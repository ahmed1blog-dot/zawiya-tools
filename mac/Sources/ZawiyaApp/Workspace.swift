import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZawiyaCore

@MainActor final class Preferences: ObservableObject {
    private let persist: Bool
    @Published var arabic: Bool { didSet { if persist { UserDefaults.standard.set(arabic, forKey: "arabic") } } }
    @Published var appearance: String { didSet { if persist { UserDefaults.standard.set(appearance, forKey: "appearance") } } }
    @Published var wheelEnabled: Bool { didSet { if persist { UserDefaults.standard.set(wheelEnabled, forKey: "wheelEnabled") } } }
    @Published var animationsEnabled: Bool { didSet { if persist { UserDefaults.standard.set(animationsEnabled, forKey: "animationsEnabled") } } }
    @Published var soundsEnabled: Bool { didSet { if persist { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") } } }
    @Published var hapticsEnabled: Bool { didSet { if persist { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") } } }
    @Published var soundVolume: Double { didSet { if persist { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") } } }
    @Published var wheelAppearance: String { didSet { if persist { UserDefaults.standard.set(wheelAppearance, forKey: "wheelAppearance") } } }
    @Published var favoriteFormats: [String] { didSet { if persist { UserDefaults.standard.set(favoriteFormats, forKey: "favoriteFormats") } } }
    init(persist: Bool = true) {
        self.persist = persist
        let defaults = UserDefaults.standard
        arabic = defaults.object(forKey: "arabic") as? Bool ?? true
        appearance = defaults.string(forKey: "appearance") ?? "dark"
        wheelEnabled = defaults.object(forKey: "wheelEnabled") as? Bool ?? true
        animationsEnabled = defaults.object(forKey: "animationsEnabled") as? Bool ?? true
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        let volume = defaults.object(forKey: "soundVolume") as? Double ?? 0.32
        soundVolume = volume.isFinite ? min(1, max(0, volume)) : 0.32
        wheelAppearance = defaults.string(forKey: "wheelAppearance") == "solid" ? "solid" : "glass"
        favoriteFormats = Array((defaults.stringArray(forKey: "favoriteFormats") ?? ["webp", "jpg", "png", "mp4", "mp3", "pdf"]).prefix(20))
    }
    func text(_ ar: String, _ en: String) -> String { arabic ? ar : en }
    var scheme: ColorScheme? { appearance == "system" ? nil : appearance == "light" ? .light : .dark }
    func toggleFavorite(_ format: String) {
        if favoriteFormats.contains(format) { favoriteFormats.removeAll { $0 == format } }
        else if favoriteFormats.count < 20 { favoriteFormats.append(format) }
    }
    var nativeDark: Bool {
        if let scheme { return scheme == .dark }
        return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    var nativeMotion: Bool { animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

enum JobState: String { case ready, running, done, failed, cancelled }
struct QueueEntry: Identifiable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    let inputBytes: Int64
    var state = JobState.ready
    var outputs: [URL] = []
    var outputBytes: Int64 = 0
    var detail = ""
    var seconds: TimeInterval = 0
}

@MainActor final class Workspace: ObservableObject {
    let quickActions = QuickActions()
    var presentMain: (() -> Void)?
    @Published var items: [QueueEntry] = []
    @Published var tool: Tool = .convert
    @Published var options = Options()
    @Published var outputDirectory: URL?
    @Published var isRunning = false
    @Published var message: String?
    @Published var section = "workspace"
    @Published var shelf: [URL] = []
    @Published var showToolBrowser = false
    @Published var ocrLanguages: [String]?
    private var ocrLoading = false
    private var cancellation = Cancellation()
    var pending: [QueueEntry] { items.filter { $0.state == .ready || $0.state == .failed || $0.state == .cancelled } }
    var completed: Int { items.filter { $0.state == .done }.count }
    var activeOutput: URL? { outputDirectory ?? items.first?.url.deletingLastPathComponent().appendingPathComponent("Zawiya Exports", isDirectory: true) }
    private var menuKinds: [FileKind] { (pending.isEmpty ? items : pending).map(\.kind) }
    var formats: [String] {
        MenuCatalog.commonFormats(for: menuKinds)
    }
    var compatibleTools: [Tool] { MenuCatalog.tools(for: menuKinds) }
    var allOutputs: [URL] { var seen = Set<URL>(); return items.flatMap(\.outputs).filter { seen.insert($0).inserted } }
    var failedCount: Int { items.filter { $0.state == .failed || $0.state == .cancelled }.count }
    var canRun: Bool { !isRunning && !pending.isEmpty && compatibleTools.contains(tool) && (tool != .convert || formats.contains(options.format)) }

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            guard !items.contains(where: { $0.url == normalized }), items.count < 2000 else { continue }
            let values = try? normalized.resourceValues(forKeys: [.fileSizeKey])
            items.append(QueueEntry(url: normalized, kind: FileKind.detect(normalized), inputBytes: Int64(values?.fileSize ?? 0)))
        }
        section = "workspace"
        normalizeFormat()
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = activeOutput
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }
    func load(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { Task { @MainActor in self.add([url]) } }
            }
        }
        return true
    }
    func normalizeFormat() {
        if !formats.contains(options.format), let first = formats.first { options.format = first }
    }
    func selectTool(_ tool: Tool) {
        guard !isRunning else { return }
        self.tool = tool; normalizeFormat(); section = "workspace"; showToolBrowser = false
    }
    func selectFormat(_ format: String) { guard !isRunning, formats.contains(format) else { return }; options.format = format }
    func loadOCRLanguages() async {
        guard ocrLanguages == nil, !ocrLoading else { return }
        ocrLoading = true
        ocrLanguages = await Task.detached(priority: .utility) { Converter.ocrLanguages() }.value
        ocrLoading = false
    }
    func remove(_ id: UUID) { guard !isRunning else { return }; items.removeAll { $0.id == id }; normalizeFormat() }
    func clear() { guard !isRunning else { return }; items.removeAll() }
    func requeueAll() {
        guard !isRunning else { return }
        for index in items.indices { items[index].state = .ready; items[index].detail = ""; items[index].outputBytes = 0; items[index].seconds = 0 }
        normalizeFormat()
    }
    func reveal(_ urls: [URL]) { if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) } }
    func start() {
        guard !isRunning, !pending.isEmpty, let destination = activeOutput else { return }
        let entries = pending
        let incompatible = entries.filter { !tool.accepts($0.kind) }
        guard incompatible.isEmpty else {
            message = "الأداة لا تدعم / Unsupported files: " + incompatible.prefix(5).map { $0.url.lastPathComponent }.joined(separator: ", ")
            return
        }
        guard canRun else { message = "لا توجد صيغة مشتركة لهذه الدفعة / No common output format for this batch."; return }
        let selectedTool = tool
        let selectedOptions = options
        let token = Cancellation(); cancellation = token; isRunning = true
        let groups = selectedTool.grouped ? [entries] : entries.map { [$0] }
        Task {
            defer { isRunning = false }
            for group in groups {
                if token.isCancelled { break }
                let ids = Set(group.map(\.id))
                update(ids) { $0.state = .running; $0.detail = ""; $0.outputs = [] }
                let request = JobRequest(inputs: group.map(\.url), outputDirectory: destination, tool: selectedTool, options: selectedOptions)
                let started = Date()
                do {
                    let scopes = group.map { ($0.url, $0.url.startAccessingSecurityScopedResource()) }
                    defer { for (url, acquired) in scopes where acquired { url.stopAccessingSecurityScopedResource() } }
                    let outputs = try await Task.detached(priority: .userInitiated) { try Converter().run(request, cancellation: token) }.value
                    let bytes = outputs.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                    update(ids) { $0.state = .done; $0.outputs = outputs; $0.seconds = Date().timeIntervalSince(started); $0.outputBytes = selectedTool.grouped ? 0 : bytes }
                } catch {
                    update(ids) { $0.state = token.isCancelled ? .cancelled : .failed; $0.detail = error.localizedDescription }
                }
            }
        }
    }
    func cancel() { cancellation.cancel() }
    private func update(_ ids: Set<UUID>, change: (inout QueueEntry) -> Void) {
        for i in items.indices where ids.contains(items[i].id) { change(&items[i]) }
    }
    func applyRecipe(_ recipe: String) {
        if recipe == "product" { tool = .resize; options.maxDimension = 1600; options.quality = 90 }
        if recipe == "web" { tool = .compress; options.format = Engines.executable("cwebp") != nil ? "webp" : "jpg"; options.quality = 78 }
        if recipe == "social" { tool = .compress; options.quality = 76 }
        if recipe == "clean" { tool = .stripMetadata }
        section = "workspace"
    }
    func wheelConvert(_ urls: [URL], format: String) {
        quickActions.submit(urls, tool: .convert, format: format, destination: outputDirectory)
    }
    func wheelTool(_ urls: [URL], tool: Tool) {
        if tool.runsImmediatelyFromWheel {
            quickActions.submit(urls, tool: tool, destination: outputDirectory)
        } else {
            guard !isRunning else { return }
            clear(); add(urls); self.tool = tool; section = "workspace"; presentMain?()
        }
    }
    func showQuickWheel(_ mode: String = "convert") {
        guard !isRunning, !pending.isEmpty else { return }
        NotificationCenter.default.post(name: .showQuickWheel, object: mode)
    }
    func fileAction(_ action: String, urls: [URL]) {
        switch action {
        case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL])
        case "path": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case "airdrop": NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case "float": shelf = Array(Set(shelf + urls)).sorted { $0.path < $1.path }; NotificationCenter.default.post(name: .showShelf, object: nil)
        case "terminal":
            guard let first = urls.first else { return }
            let folder = FileKind.detect(first) == .folder ? first : first.deletingLastPathComponent()
            NSWorkspace.shared.open([folder], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case "move":
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let targets = urls.map { folder.appendingPathComponent($0.lastPathComponent) }
            guard Set(targets.map(\.path)).count == targets.count, targets.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
                message = "تعارض أسماء في الوجهة. لم يُنقل أي ملف / Destination name conflict. No files moved."
                return
            }
            var moved = 0
            do {
                // FileManager refuses existing targets. Originals only move on this explicit action.
                for (source, target) in zip(urls, targets) { try FileManager.default.moveItem(at: source, to: target); moved += 1 }
            } catch { message = "تم نقل / Moved: \(moved) / \(urls.count). \(error.localizedDescription)" }
        default: break
        }
    }
}

extension Notification.Name {
    static let showShelf = Notification.Name("ZawiyaShowShelf")
    static let showQuickWheel = Notification.Name("ZawiyaShowQuickWheel")
}
