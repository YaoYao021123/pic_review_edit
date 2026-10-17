import AppKit
import Foundation
import MediaCore
import Observation

/// Serial background exports. Each job captures its inputs when queued, so
/// editing (or opening another file) never waits for an export to finish.
@MainActor
@Observable
final class ExportQueue {
    enum State: Equatable {
        case waiting, running, finished, failed(String), cancelled
    }

    struct Result: Sendable {
        var outputs: [URL]
        var live: LivePhotoResources?
        var summary: String
        var inPhotos = false
    }

    struct Job: Identifiable {
        let id = UUID()
        let title: String
        var detail = ""
        var state = State.waiting
        var progress: Double?
        var outputs: [URL] = []
        var live: LivePhotoResources?
        var inPhotos = false
        var isActive: Bool { state == .waiting || state == .running }
    }

    typealias Report = @Sendable (_ fraction: Double?, _ detail: String?) -> Void
    typealias Work = @Sendable (_ report: @escaping Report) async throws -> Result

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var pending: [(UUID, Work)] = []
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored private var runningID: UUID?
    @ObservationIgnored var onFinish: ((Job) -> Void)?
    /// Called once when the queue next has nothing waiting or running (used to quit after exports).
    @ObservationIgnored var onIdle: (() -> Void)?

    var activeCount: Int { jobs.filter(\.isActive).count }
    var runningJob: Job? { jobs.first { $0.state == .running } }

    @discardableResult
    func enqueue(_ title: String, work: @escaping Work) -> UUID {
        let job = Job(title: title)
        jobs.insert(job, at: 0)
        if jobs.count > 50 { jobs.removeLast(jobs.count - 50) }
        pending.append((job.id, work))
        startNext()
        return job.id
    }

    func cancel(_ id: UUID) {
        if runningID == id { runningTask?.cancel(); return }
        pending.removeAll { $0.0 == id }
        update(id) { $0.state = .cancelled; $0.progress = nil }
    }

    /// Stops everything; the running export removes its unfinished file before reporting.
    func cancelAll() {
        for (id, _) in pending { update(id) { $0.state = .cancelled; $0.progress = nil } }
        pending.removeAll()
        runningTask?.cancel()
        notifyIfIdle()
    }

    private func notifyIfIdle() {
        guard runningTask == nil, pending.isEmpty, let idle = onIdle else { return }
        onIdle = nil
        idle()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func reveal(_ job: Job) {
        let urls = job.live.map { [$0.imageURL] } ?? job.outputs
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func startNext() {
        guard runningTask == nil, !pending.isEmpty else { return }
        let (id, work) = pending.removeFirst()
        runningID = id
        update(id) { $0.state = .running; $0.progress = nil }
        let report: Report = { [weak self] fraction, detail in
            Task { @MainActor [weak self] in
                self?.update(id) { job in
                    if let fraction { job.progress = min(1, max(0, fraction)) }
                    if let detail { job.detail = detail }
                }
            }
        }
        runningTask = Task { [weak self] in
            let outcome: Swift.Result<Result, Error>
            do { outcome = .success(try await work(report)) } catch { outcome = .failure(error) }
            guard let self else { return }
            let cancelled = Task.isCancelled
            self.update(id) { job in
                job.progress = nil
                switch outcome {
                case .success(let result):
                    job.state = .finished; job.outputs = result.outputs; job.live = result.live; job.detail = result.summary
                    job.inPhotos = result.inPhotos
                case .failure(let error):
                    if cancelled || error is CancellationError { job.state = .cancelled; job.detail = L("已取消，原片保留") }
                    else { job.state = .failed(error.localizedDescription) }
                }
            }
            if let job = self.jobs.first(where: { $0.id == id }) { self.onFinish?(job) }
            self.runningTask = nil
            self.runningID = nil
            self.startNext()
            self.notifyIfIdle()
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
}
