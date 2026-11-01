import Foundation
import Darwin
@testable import Brim

/// A clock the test moves by hand. Work runs in time order when the clock passes its deadline.
@MainActor
final class ManualScheduler: Scheduler {
    private(set) var now: Date
    private var queue: [(due: Date, seq: Int, token: Scheduled, work: @MainActor () -> Void)] = []
    private var seq = 0

    init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) { now = start }

    var pending: Int { queue.filter { !$0.token.isCancelled }.count }

    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Scheduled {
        let token = Scheduled()
        seq += 1
        queue.append((now.addingTimeInterval(delay), seq, token, work))
        return token
    }

    /// Moves the clock forward, running everything that comes due on the way (including work scheduled meanwhile).
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = queue.filter({ !$0.token.isCancelled && $0.due <= target }).min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }) {
            queue.removeAll { $0.seq == next.seq }
            now = max(now, next.due)
            next.work()
        }
        queue.removeAll { $0.token.isCancelled }
        now = target
    }

    /// Runs until nothing is left (bounded, so a timer that keeps re-arming fails the test instead of hanging).
    func drain(limit: TimeInterval = 24 * 3600) {
        advance(by: limit)
    }
}

/// A fresh UserDefaults suite per test, so tests never read or write the real preferences.
@MainActor
func makePreferences(_ configure: (Preferences) -> Void = { _ in }) -> Preferences {
    let name = "brim-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let prefs = Preferences(defaults: defaults)
    configure(prefs)
    return prefs
}

enum Repo {
    /// The repository root, from this file's location.
    static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let resources = root.appendingPathComponent("Resources")
    static let sources = root.appendingPathComponent("Sources/Brim")
    static let fixtures = root.appendingPathComponent("Tests/BrimTests/Fixtures")
}

/// A temporary folder removed at the end of the test.
final class TempDir {
    let url: URL
    init() {
        // Short path: Unix socket paths must stay under 104 bytes.
        url = URL(fileURLWithPath: "/tmp/brim-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A connected pair of Unix sockets: the app side and the hook side.
final class SocketPair {
    let app: Int32
    let hook: Int32
    private var received = Data()

    init() {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        app = fds[0]; hook = fds[1]
        var on: Int32 = 1
        setsockopt(app, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(hook, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(app, F_SETFL, O_NONBLOCK)
    }

    func send(_ text: String) { _ = text.withCString { write(hook, $0, strlen($0)) } }

    /// Everything the app wrote, once it closed its side, or nil if it is still open.
    func reply() -> String? {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(hook, &buf, buf.count, MSG_DONTWAIT)
            if n > 0 { received.append(contentsOf: buf[0..<n]); continue }
            return n == 0 ? String(decoding: received, as: UTF8.self) : nil
        }
    }

    /// True while the app keeps the connection open (nothing written, not closed).
    var isOpen: Bool {
        var b: UInt8 = 0
        return recv(hook, &b, 1, MSG_DONTWAIT | MSG_PEEK) < 0 && errno == EAGAIN
    }

    func closeHook() { close(hook) }
}

/// Waits for GCD work on the main queue (socket and file sources) until `condition` holds.
/// Tests run on the main actor, so they must suspend for those handlers to run.
@MainActor
func eventually(timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

func jsonText(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// A sample track.
func track(_ title: String = "Song", playing: Bool = true, elapsed: Double = 10, duration: Double = 200, at date: Date) -> NowPlaying {
    NowPlaying(title: title, artist: "Artist", album: "Album", duration: duration, elapsed: elapsed, timestamp: date,
               rate: 1, playing: playing, appName: "Music", bundleID: "com.apple.Music", artwork: nil, accent: .white)
}
