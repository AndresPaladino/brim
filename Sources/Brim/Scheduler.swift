import Foundation

/// Delayed work on the main thread. The app uses `MainScheduler`; tests use a manual clock.
@MainActor
protocol Scheduler: AnyObject {
    var now: Date { get }
    /// Runs `work` after `delay` seconds unless the returned token is cancelled first.
    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Scheduled
}

/// A pending piece of work. Cancelling twice, or after it ran, does nothing.
@MainActor
final class Scheduled {
    private var onCancel: (() -> Void)?
    private(set) var isCancelled = false

    init(onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

@MainActor
final class MainScheduler: Scheduler {
    static let shared = MainScheduler()

    var now: Date { Date() }

    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Scheduled {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Scheduled { item.cancel() }
    }
}
