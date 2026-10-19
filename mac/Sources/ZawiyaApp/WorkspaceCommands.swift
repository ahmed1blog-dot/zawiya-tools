import SwiftUI
import AppKit
import ZawiyaCore

struct WorkspaceCommands: Commands {
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    @Environment(\.openWindow) private var openWindow
    func show(_ section: String = "workspace") { workspace.section = section; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    var body: some Commands {
        CommandMenu(preferences.text("الأدوات", "Tools")) {
            Button(preferences.text("بحث في كل الأدوات…", "Search all tools…")) { show(); workspace.showToolBrowser = true }.keyboardShortcut("k")
            Button(preferences.text("العجلة السريعة للملفات…", "Quick wheel for queued files…")) { workspace.showQuickWheel() }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(workspace.isRunning || workspace.pending.isEmpty)
            Divider()
            ForEach(Tool.allCases) { tool in Button(tool.title(preferences.arabic)) { show(); workspace.selectTool(tool) }.disabled(workspace.isRunning || !workspace.compatibleTools.contains(tool)) }
            Divider()
            Button(preferences.text("تنفيذ العملية", "Run job")) { workspace.start() }.keyboardShortcut(.return).disabled(!workspace.canRun)
            Button(preferences.text("مجلد النتائج…", "Output folder…")) { show(); workspace.chooseOutput() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(workspace.isRunning)
        }
        CommandMenu(preferences.text("التنقل", "Navigate")) {
            Button(preferences.text("مساحة العمل", "Workspace")) { show() }.keyboardShortcut("1")
            Button(preferences.text("إعدادات جاهزة", "Presets")) { show("recipes") }.keyboardShortcut("2")
            Button(preferences.text("القدرات والمحركات", "Capabilities")) { show("capabilities") }.keyboardShortcut("3")
            Button(preferences.text("الإعدادات", "Settings")) { show("settings") }.keyboardShortcut(",")
        }
    }
}
