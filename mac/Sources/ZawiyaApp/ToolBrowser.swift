import SwiftUI
import ZawiyaCore

struct ToolBrowser: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var workspace: Workspace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    init(initialQuery: String = "") { _query = State(initialValue: initialQuery) }
    var dark: Bool { scheme == .dark }
    var tools: [Tool] { MenuCatalog.matchingTools(query) }
    var formats: [String] {
        let formats = workspace.formats
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return formats.filter { $0.localizedStandardContains(query) }
    }
    func t(_ ar: String, _ en: String) -> String { preferences.text(ar, en) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.accent(dark))
                TextField(t("ابحث عن أداة أو صيغة…", "Find a tool or format…"), text: $query).textFieldStyle(.plain).font(.system(size: 18)).focused($searchFocused)
                    .onSubmit { if let first = tools.first(where: { workspace.compatibleTools.contains($0) }) { workspace.selectTool(first) } else if let first = formats.first { workspace.selectTool(.convert); workspace.selectFormat(first) } }
                Button(t("إغلاق", "Close")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.plain).foregroundStyle(Brand.muted(dark))
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text(t("كل الأدوات", "ALL TOOLS") + " · \(tools.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.muted(dark)).padding(.horizontal, 12).padding(.vertical, 10)
                    ForEach(tools) { tool in
                        let compatible = workspace.compatibleTools.contains(tool)
                        Button { workspace.selectTool(tool) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: tool.icon).font(.system(size: 18)).frame(width: 28).foregroundStyle(compatible ? Brand.accent(dark) : Brand.muted(dark))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tool.title(preferences.arabic)).font(.system(size: 14, weight: .medium))
                                    Text(compatible ? (workspace.pending.isEmpty ? t("أضف ملفات ثم نفّذ العملية", "Add files, then run the job") : t("متاحة للملفات الحالية", "Available for the current files")) : t("تحتاج نوع ملفات مختلفًا", "Needs a different file type")).font(.system(size: 11)).foregroundStyle(Brand.muted(dark))
                                }
                                Spacer()
                                if workspace.tool == tool { Image(systemName: "checkmark").foregroundStyle(Brand.accent(dark)) }
                            }.padding(12).contentShape(Rectangle()).background(workspace.tool == tool ? Brand.accent(dark).opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(.plain).disabled(!compatible || workspace.isRunning).opacity(compatible ? 1 : 0.5)
                    }
                    if !formats.isEmpty {
                        Text(t("الصيغ المتوافقة", "COMPATIBLE FORMATS")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.muted(dark)).padding(12)
                        ForEach(formats, id: \.self) { format in
                            Button { workspace.selectTool(.convert); workspace.selectFormat(format) } label: {
                                HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text(format.uppercased()); Spacer(); Image(systemName: "return") }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(workspace.isRunning)
                        }
                    }
                    if tools.isEmpty && formats.isEmpty { Text(t("لا توجد نتيجة. جرّب PDF أو ضغط أو WebP.", "No matches. Try PDF, compress or WebP.")).foregroundStyle(Brand.muted(dark)).padding(20) }
                }.padding(12)
            }
            Divider()
            HStack { Text(t("الأدوات غير المتوافقة ظاهرة لتعرف ما تحتاجه.", "Unavailable tools stay visible so you can see what they need.")); Spacer(); Text("⌘ K  /  Esc") }.font(.system(size: 10)).foregroundStyle(Brand.muted(dark)).padding(14)
        }.frame(width: 570, height: 540).background(Brand.surface(dark))
            .environment(\.layoutDirection, preferences.arabic ? .rightToLeft : .leftToRight)
            .onAppear { searchFocused = true }
    }
}
