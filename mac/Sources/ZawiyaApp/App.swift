import SwiftUI
import AppKit
import ZawiyaCore

@MainActor enum Services {
    static let preferences = Preferences()
    static let workspace = Workspace()
    static let wheel = DragWheel(workspace: workspace, preferences: preferences)
    static let updater = UpdaterModel()
    static let announcements = AnnouncementStore()
}

// Background services start with the app, not with the window: the app can launch
// with its window closed (menu bar only) and the wheel, updates and banner must still run.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Engines.clearBundledQuarantine(); Services.wheel.start(); Services.announcements.start(); _ = Services.updater
        }
    }
}

@main struct ZawiyaToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var preferences = Services.preferences
    @StateObject private var workspace = Services.workspace
    init() {
        // Render this app's own view offscreen for visual QA, without screen capture
        // or reading another app. This mode never starts the drag monitor.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--export-feedback"), args.count > index + 1 {
            do { try FeedbackSound.demonstration.write(to: URL(fileURLWithPath: args[index + 1])); exit(0) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        if let index = args.firstIndex(of: "--render-preview"), args.count > index + 1 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let preferences = Preferences(persist: false)
            preferences.arabic = !args.contains("--preview-english")
            preferences.appearance = args.contains("--preview-light") ? "light" : "dark"
            let workspace = Workspace()
            if let file = args.firstIndex(of: "--preview-file"), args.count > file + 1 { workspace.add([URL(fileURLWithPath: args[file + 1])]); workspace.options.format = "webp" }
            let width = args.contains("--preview-compact") ? 760.0 : 1220.0
            let height = args.contains("--preview-compact") ? 620.0 : 840.0
            if let section = args.firstIndex(of: "--preview-section"), args.count > section + 1 { workspace.section = args[section + 1] }
            preferences.animationsEnabled = true
            let view = Group {
                if let search = args.firstIndex(of: "--preview-search"), args.count > search + 1 { ToolBrowser(initialQuery: args[search + 1]) }
                else { RootView() }
            }.environmentObject(preferences).environmentObject(workspace)
                .environment(\.colorScheme, preferences.scheme ?? .dark).frame(width: width, height: height)
                .transaction { $0.disablesAnimations = true }
            let wheel = DragWheel(workspace: workspace, preferences: preferences)
            let host: NSView
            if args.contains("--preview-status") {
                let folder = URL(fileURLWithPath: "/tmp/Zawiya Exports", isDirectory: true)
                var job = QuickJob(inputs: [folder.appendingPathComponent("sample.png")], tool: .stripMetadata, options: Options(), destination: folder)
                job.state = args.contains("--preview-failure") ? .failed : .done
                job.outputs = args.contains("--preview-failure") ? [] : [folder.appendingPathComponent("sample-zawiya.png")]
                job.errors = args.contains("--preview-failure") ? [preferences.text("تعذر قراءة الملف: صورة.png", "Cannot read file: sample.png")] : []
                host = NSHostingView(rootView: QuickStatusView(actions: QuickActions(previewJob: job), preferences: preferences, close: {}).preferredColorScheme(preferences.scheme))
                host.frame = CGRect(x: 0, y: 0, width: 340, height: host.fittingSize.height)
            } else if let index = args.firstIndex(of: "--preview-wheel"), args.count > index + 1 {
                let urls = workspace.items.isEmpty ? [URL(fileURLWithPath: "/tmp/preview.png")] : workspace.items.map(\.url)
                host = wheel.preview(mode: args[index + 1], urls: urls)
            } else {
                host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
            host.appearance = NSAppearance(named: preferences.nativeDark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: URL(fileURLWithPath: args[index + 1])); exit(0) }
                    catch { fputs("\(error)\n", stderr) }
                }
            }
            exit(1)
        }
    }
    var body: some Scene {
        Window("Zawiya Tools", id: "main") {
            RootView().environmentObject(preferences).environmentObject(workspace)
                .preferredColorScheme(preferences.scheme)
        }.defaultSize(width: 1040, height: 760).windowStyle(.hiddenTitleBar)
            .commands {
                WorkspaceCommands(workspace: workspace, preferences: preferences)
                CommandGroup(replacing: .appInfo) {
                    Button(preferences.text("حول Zawiya Tools", "About Zawiya Tools")) { AppInfo.showAboutPanel(arabic: preferences.arabic) }
                    Button(preferences.text("التحقق من التحديثات…", "Check for Updates…")) { Services.updater.check() }.disabled(!Services.updater.available)
                }
                CommandGroup(replacing: .newItem) { Button(preferences.text("إضافة ملفات…", "Add files…")) { workspace.chooseFiles() }.keyboardShortcut("o") }
                CommandGroup(after: .toolbar) { Button(preferences.text("إلغاء المعالجة", "Cancel processing")) { workspace.cancel() }.keyboardShortcut(".").disabled(!workspace.isRunning) }
            }
        MenuBarExtra("Zawiya Tools", systemImage: "circle.dotted.circle") { TrayMenu().environmentObject(preferences).environmentObject(workspace) }
    }
}

struct TrayMenu: View {
    @Environment(\.openWindow) var openWindow
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var workspace: Workspace
    var body: some View {
        Button("Zawiya Tools") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(preferences.text("إضافة ملفات…", "Add files…")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); workspace.chooseFiles() }
        Button(preferences.text("كل الأدوات…", "All tools…")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); workspace.showToolBrowser = true }
        Menu(preferences.text("اختيار أداة", "Choose a tool")) {
            ForEach(ZawiyaCore.Tool.allCases) { tool in Button(tool.title(preferences.arabic)) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); workspace.selectTool(tool) }.disabled(workspace.isRunning || !workspace.compatibleTools.contains(tool)) }
        }
        Menu(preferences.text("المظهر", "Appearance")) {
            Button(preferences.text("داكن", "Dark")) { preferences.appearance = "dark" }
            Button(preferences.text("فاتح", "Light")) { preferences.appearance = "light" }
            Button(preferences.text("حسب النظام", "System")) { preferences.appearance = "system" }
        }
        Button(preferences.text("الإعدادات", "Settings")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); workspace.section = "settings" }
        Toggle(preferences.text("عجلة السحب", "Drag wheel"), isOn: $preferences.wheelEnabled)
        QuickActionMenu(actions: workspace.quickActions, preferences: preferences)
        Divider()
        if workspace.isRunning { Button(preferences.text("إلغاء المعالجة", "Cancel processing")) { workspace.cancel() } }
        Button(preferences.text("إنهاء", "Quit")) { workspace.cancel(); workspace.quickActions.cancelAll(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
