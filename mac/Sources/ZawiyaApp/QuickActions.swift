import Foundation
import Combine
import ZawiyaCore

extension Tool {
    var runsImmediatelyFromWheel: Bool {
        switch self {
        case .convert, .stripMetadata, .imagesToPDF, .mergePDF, .splitPDF, .extractText, .zip: return true
        case .compress, .resize, .trim, .videoFrame: return false
        }
    }
}

enum QuickJobState { case queued, running, done, failed, cancelled }
struct QuickJob: Identifiable {
    let id = UUID()
    let inputs: [URL]
    let tool: Tool
    let options: Options
    let destination: URL
    var state = QuickJobState.queued
    var outputs: [URL] = []
    var errors: [String] = []
    var processed = 0
}

/// Keeps background drops separate from the user's unfinished dashboard setup.
/// All file decoding and atomic, non-overwriting publication stay in Converter.
@MainActor final class QuickActions: ObservableObject {
    @Published private(set) var jobs: [QuickJob] = []
    // A static preview never starts a worker or performs file operations.
    init(previewJob: QuickJob? = nil) { if let previewJob { jobs = [previewJob] } }
    private var worker: Task<Void, Never>?
    private var cancellation = Cancellation()
    var isProcessing: Bool { jobs.contains { $0.state == .queued || $0.state == .running } }
    var waitingCount: Int { jobs.filter { $0.state == .queued }.count }
    var visibleJob: QuickJob? {
        if let last = jobs.last, last.state == .failed, last.processed == 0 { return last }
        return jobs.first { $0.state == .running } ?? jobs.first { $0.state == .queued } ?? jobs.last
    }

    @discardableResult func submit(_ urls: [URL], tool: Tool, format: String? = nil, destination: URL? = nil) -> UUID {
        var seen = Set<URL>()
        let inputs = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        var options = Options()
        if let format { options.format = format }
        let folder = destination ?? (inputs.first?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory).appendingPathComponent("Zawiya Exports", isDirectory: true)
        var job = QuickJob(inputs: inputs, tool: tool, options: options, destination: folder)
        if !tool.runsImmediatelyFromWheel || inputs.isEmpty || inputs.count > 2000 || !inputs.allSatisfy({ $0.isFileURL && tool.accepts(FileKind.detect($0)) }) {
            job.state = .failed; job.errors = ["أداة أو ملفات غير مناسبة للإجراء السريع / Unsupported quick action or files."]
        } else if tool == .convert, !MenuCatalog.commonFormats(for: inputs.map(FileKind.detect)).contains(options.format) {
            job.state = .failed; job.errors = ["الصيغة لا تناسب هذه الملفات / No shared output format."]
        } else if jobs.filter({ $0.state == .queued || $0.state == .running }).count >= 20 {
            job.state = .failed; job.errors = ["الطابور ممتلئ؛ انتظر اكتمال مهمة / Queue full; wait for a job to finish."]
        }
        jobs.append(job)
        while jobs.count > 30, let old = jobs.firstIndex(where: { $0.state != .queued && $0.state != .running }) { jobs.remove(at: old) }
        if worker == nil, isProcessing { worker = Task { await processQueue() } }
        return job.id
    }
    func cancelAll() {
        cancellation.cancel()
        for i in jobs.indices where jobs[i].state == .queued { jobs[i].state = .cancelled }
    }
    private func update(_ id: UUID, _ change: (inout QuickJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }
    private func processQueue() async {
        defer { worker = nil }
        while let job = jobs.first(where: { $0.state == .queued }) {
            let token = Cancellation(); cancellation = token
            update(job.id) { $0.state = .running }
            let groups = job.tool.grouped ? [job.inputs] : job.inputs.map { [$0] }
            for group in groups {
                if token.isCancelled { break }
                let request = JobRequest(inputs: group, outputDirectory: job.destination, tool: job.tool, options: job.options)
                let scopes = group.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (url, acquired) in scopes where acquired { url.stopAccessingSecurityScopedResource() } }
                do {
                    let outputs = try await Task.detached(priority: .userInitiated) { try Converter().run(request, cancellation: token) }.value
                    update(job.id) { $0.outputs += outputs; $0.processed += group.count }
                } catch {
                    if !token.isCancelled { update(job.id) { $0.errors.append("\(group.first?.lastPathComponent ?? ""): \(error.localizedDescription)"); $0.processed += group.count } }
                }
            }
            update(job.id) { $0.state = token.isCancelled ? .cancelled : $0.errors.isEmpty ? .done : .failed }
        }
    }
}
