import Foundation

/// Caps accessibility IPC. A call into a busy app blocks its thread for up to the messaging timeout, so: at most
/// `width` calls in flight in total and at most one per app. A few hung apps then hold a few slots instead of every
/// thread, and further requests for them wait their turn instead of piling up. Thread-safe.
final class AXLimiter {
    enum Priority: Int {
        /// Focus changes and new windows: they decide the switcher's order, so they go first.
        case high = 0
        /// Scans and refreshes.
        case normal = 1
    }

    static let shared = AXLimiter(width: 5)

    private struct Job {
        let pid: pid_t
        let priority: Priority
        let key: String?
        let work: () -> Void
    }

    let width: Int
    private let execute: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var waiting = [Job]()       // lock; in submission order
    private var busyPIDs = Set<pid_t>() // lock
    private var running = 0             // lock

    /// `execute` runs a started job somewhere (a concurrent queue by default; tests run them by hand).
    init(width: Int, execute: ((@escaping () -> Void) -> Void)? = nil) {
        self.width = max(1, width)
        if let execute {
            self.execute = execute
        } else {
            let queue = DispatchQueue(label: "riffle.ax", qos: .userInitiated, attributes: .concurrent)
            self.execute = { queue.async(execute: $0) }
        }
    }

    /// Queues `work`, which talks to `pid` over AX. With a `key`, a job still waiting under the same key makes this one
    /// redundant (it reads the app's state when it runs, so it will see this change too): nothing is queued, and false
    /// is returned.
    @discardableResult
    func submit(pid: pid_t, priority: Priority = .normal, key: String? = nil, _ work: @escaping () -> Void) -> Bool {
        lock.lock()
        if let key, waiting.contains(where: { $0.key == key }) {
            lock.unlock()
            return false
        }
        waiting.append(Job(pid: pid, priority: priority, key: key, work: work))
        let ready = takeReady()
        lock.unlock()
        ready.forEach(start)
        return true
    }

    var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var queued: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }

    /// Lock held. The oldest job of the most urgent kind whose app has nothing in flight, as long as slots are free.
    private func takeReady() -> [Job] {
        var ready = [Job]()
        while running < width {
            var best: Int?
            for (index, job) in waiting.enumerated() where !busyPIDs.contains(job.pid) {
                if let current = best, waiting[current].priority.rawValue <= job.priority.rawValue { continue }
                best = index
            }
            guard let best else { break }
            let job = waiting.remove(at: best)
            busyPIDs.insert(job.pid)
            running += 1
            ready.append(job)
        }
        return ready
    }

    private func start(_ job: Job) {
        execute { [self] in
            job.work()
            lock.lock()
            busyPIDs.remove(job.pid)
            running -= 1
            let ready = takeReady()
            lock.unlock()
            ready.forEach(start)
        }
    }
}
