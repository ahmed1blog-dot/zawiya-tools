import SwiftUI
import AppKit

struct QuickStatusView: View {
    @ObservedObject var actions: QuickActions
    @ObservedObject var preferences: Preferences
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    func t(_ ar: String, _ en: String) -> String { preferences.text(ar, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = actions.visibleJob {
                HStack(spacing: 10) {
                    if job.state == .running || job.state == .queued { ProgressView().controlSize(.small) }
                    else { Image(systemName: job.state == .done ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.circle" : "stop.circle").foregroundStyle(job.state == .failed ? Color.orange : Brand.accent(scheme == .dark)) }
                    Text(job.tool.title(preferences.arabic)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 22, height: 22) }.buttonStyle(.plain).accessibilityLabel(t("إخفاء الإشعار", "Hide notification"))
                }
                Text(detail(job)).font(.system(size: 11)).foregroundStyle(Brand.muted(scheme == .dark)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if actions.waitingCount > 0 { Text(t("في الانتظار: \(actions.waitingCount)", "Waiting: \(actions.waitingCount)")).font(.system(size: 10)).foregroundStyle(Brand.muted(scheme == .dark)) }
                    Spacer()
                    if !job.outputs.isEmpty { Button(t("إظهار النتائج", "Show results")) { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }.controlSize(.small) }
                    if actions.isProcessing { Button(t("إلغاء", "Cancel")) { actions.cancelAll() }.controlSize(.small) }
                }
            }
        }.padding(16).frame(width: 340, alignment: .leading)
            .background(Brand.surface(scheme == .dark), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.line(scheme == .dark), lineWidth: 1))
            .foregroundStyle(scheme == .dark ? Color.white : Brand.ink)
            .environment(\.layoutDirection, preferences.arabic ? .rightToLeft : .leftToRight)
    }
    private func detail(_ job: QuickJob) -> String {
        switch job.state {
        case .queued: return t("بانتظار المهمة السابقة…", "Waiting for the previous job…")
        case .running: return t("جارٍ التنفيذ · \(job.processed) / \(job.inputs.count)", "Processing · \(job.processed) / \(job.inputs.count)")
        case .done: return t("تم حفظ \(job.outputs.count) نتيجة في \(job.destination.lastPathComponent). الأصل محفوظ.", "Saved \(job.outputs.count) result(s) in \(job.destination.lastPathComponent). Originals preserved.")
        case .failed: return job.errors.first ?? t("تعذر إكمال العملية", "The operation could not finish")
        case .cancelled: return t("أُلغيت المهمة. النتائج المكتملة: \(job.outputs.count)", "Cancelled. Completed results: \(job.outputs.count)")
        }
    }
}

struct QuickActionMenu: View {
    @ObservedObject var actions: QuickActions
    @ObservedObject var preferences: Preferences
    var body: some View {
        Menu(preferences.text("الإجراءات السريعة الأخيرة", "Recent quick actions")) {
            if actions.jobs.isEmpty { Text(preferences.text("لا توجد مهام بعد", "No jobs yet")) }
            ForEach(Array(actions.jobs.suffix(10).reversed())) { job in
                Button(job.tool.title(preferences.arabic) + " · " + (job.state == .done ? "✓" : job.state == .failed ? "!" : job.state == .cancelled ? "—" : "…")) { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }.disabled(job.outputs.isEmpty)
            }
            if actions.isProcessing { Divider(); Button(preferences.text("إلغاء المهام السريعة", "Cancel quick jobs")) { actions.cancelAll() } }
        }
    }
}
