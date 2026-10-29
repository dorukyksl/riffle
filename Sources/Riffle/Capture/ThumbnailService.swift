import Cocoa
import ScreenCaptureKit

/// Live window thumbnails. ScreenCaptureKit (rewritten for macOS 26) does the normal captures; the
/// WindowServer's own capture is the fallback, because only it can see minimized windows.
///
/// The cache is kept warm in the background (a window is re-captured right after it loses focus), so the
/// switcher can draw real thumbnails the instant it appears and then refresh them while it is open.
final class ThumbnailService {
    static let shared = ThumbnailService()

    struct Request {
        let wid: CGWindowID
        let frame: CGRect
        let isMinimized: Bool
        /// The window's app is hidden (⌘H): like a minimized window, it isn't on screen.
        var isHidden = false
    }

    enum Priority {
        /// Cards on screen: the switcher's own requests, selected card first.
        case interactive
        /// Keeping the cache warm while the switcher is closed.
        case background
    }

    /// Longest side of a stored thumbnail, in pixels. Main thread.
    var maxPixelSize: CGFloat = 720
    /// Whether a window is still one Riffle shows; a capture that lands after its window closed is dropped.
    var isTracked: (CGWindowID) -> Bool = { _ in true }

    private var cache = [CGWindowID: CGImage]()            // main thread
    private var capturedAt = [CGWindowID: TimeInterval]()  // main thread
    /// Captures at once. Each one is GPU and WindowServer work the capture service largely does in turn, so more in
    /// flight mostly means more waiting and memory; three keep the selected card's refresh from queueing behind others.
    static let maxConcurrent = 3
    private var queue = CaptureQueue(limit: ThumbnailService.maxConcurrent) // main thread
    private var inFlight = [CGWindowID: Priority]()        // main thread
    private var batch = CaptureBatch()                     // main thread
    private var listeners = [UUID: (CGWindowID) -> Void]()
    /// Thumbnails kept at most; the ones captured longest ago go first.
    private let cacheLimit = 96

    private let lock = NSLock()
    private var scWindows = [CGWindowID: SCWindow]()      // lock
    private var shareableRefreshStarted: TimeInterval?    // lock: set while a refresh runs
    private var shareableWaiters = [() -> Void]()         // lock
    private var lastShareableRefresh: TimeInterval = -100 // lock
    private var shareableGeneration = 0                   // lock: bumped by invalidations
    private let fallbackQueue = DispatchQueue(label: "riffle.capture", qos: .userInitiated, attributes: .concurrent)

    var isAvailable: Bool { Permissions.screenRecording }

    func image(for wid: CGWindowID) -> CGImage? { cache[wid] }

    /// For offscreen design renders only.
    func inject(_ image: CGImage, for wid: CGWindowID) { cache[wid] = image }

    func evict(_ wid: CGWindowID) {
        cache[wid] = nil
        capturedAt[wid] = nil
    }

    @discardableResult
    func addListener(_ listener: @escaping (CGWindowID) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    func removeListener(_ token: UUID) {
        listeners[token] = nil
    }

    /// Queues captures, most important first (ahead of, and replacing, older requests for the same windows). Windows
    /// captured less than `freshness` seconds ago are skipped. Interactive requests always go before background ones.
    func refresh(_ requests: [Request], freshness: TimeInterval = 1.0, priority: Priority = .interactive) {
        guard isAvailable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var fresh = [Request]()
        for request in requests where inFlight[request.wid] == nil {
            if let last = capturedAt[request.wid], now - last < freshness { continue }
            // A hidden app's windows can't be captured anew; the picture taken before it was hidden stays.
            if request.isHidden, cache[request.wid] != nil { continue }
            fresh.append(request)
        }
        queue.add(fresh, priority: priority)
        pump()
    }

    private func pump() {
        let background = inFlight.values.filter { $0 == .background }.count
        guard let (request, priority) = queue.next(running: inFlight.count, runningBackground: background) else {
            if inFlight.isEmpty, let summary = batch.finish() { Log.info(summary) }
            return
        }
        inFlight[request.wid] = priority
        let started = ProcessInfo.processInfo.systemUptime
        batch.begin(at: started)
        capture(request, size: targetPixelSize(for: request.frame, maxSide: maxPixelSize)) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight[request.wid] = nil
                self.batch.record(ProcessInfo.processInfo.systemUptime - started)
                if let image, self.isTracked(request.wid) {
                    self.cache[request.wid] = image
                    self.capturedAt[request.wid] = ProcessInfo.processInfo.systemUptime
                    self.trimCache()
                    for listener in self.listeners.values { listener(request.wid) }
                }
                self.pump()
            }
        }
        pump()
    }

    private func trimCache() {
        guard cache.count > cacheLimit else { return }
        let oldest = capturedAt.sorted { $0.value < $1.value }.prefix(cache.count - cacheLimit).map(\.key)
        for wid in oldest { evict(wid) }
    }

    private func targetPixelSize(for frame: CGRect, maxSide: CGFloat) -> CGSize {
        let width = max(frame.width, 1) * 2
        let height = max(frame.height, 1) * 2
        let scale = min(1, maxSide / max(width, height))
        return CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
    }

    /// Captures one window at `size` pixels (sized from the window's current frame: ScreenCaptureKit's own copy may be
    /// stale after a resize). Main thread in; `completion` exactly once, from any queue, within a few seconds even if
    /// ScreenCaptureKit never answers.
    private func capture(_ request: Request, size: CGSize, completion: @escaping (CGImage?) -> Void) {
        let finish = Once(completion)
        // If ScreenCaptureKit hasn't answered in time (it can wedge after sleep), the WindowServer takes over; past that,
        // give up so the slot is freed.
        let offScreen = request.isMinimized || request.isHidden
        fallbackQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !finish.isDone else { return }
            self.captureWithWindowServer(request.wid, size: size, checkShape: !offScreen, completion: finish.call)
        }
        fallbackQueue.asyncAfter(deadline: .now() + 6) { finish(nil) }
        if request.isMinimized || request.isHidden {
            // Off screen entirely: the WindowServer gives the whole window or nothing.
            captureWithWindowServer(request.wid, size: size, checkShape: false, completion: finish.call)
            return
        }
        withSCWindow(request.wid) { [weak self] scWindow in
            guard let self else { return finish(nil) }
            guard let scWindow else {
                self.captureWithWindowServer(request.wid, size: size, completion: finish.call)
                return
            }
            let pixelSize = request.frame.width > 1 && request.frame.height > 1 ? size
                : self.targetPixelSize(for: scWindow.frame, maxSide: max(size.width, size.height))
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let configuration = SCScreenshotConfiguration()
            configuration.width = Int(pixelSize.width)
            configuration.height = Int(pixelSize.height)
            configuration.showsCursor = false
            configuration.ignoreShadows = true
            configuration.dynamicRange = .sdr
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { output, error in
                if let image = output?.sdrImage, error == nil, !ThumbnailService.looksEmpty(image) {
                    finish(image)
                } else {
                    self.captureWithWindowServer(request.wid, size: pixelSize, completion: finish.call)
                }
            }
        }
    }

    private func captureWithWindowServer(_ wid: CGWindowID, size: CGSize, checkShape: Bool = true, completion: @escaping (CGImage?) -> Void) {
        fallbackQueue.async {
            guard let image = PrivateAPI.captureWindow(wid), image.width > 1, image.height > 1 else { return completion(nil) }
            // For a window on screen the WindowServer only returns the part that is visible: one pushed aside (Show
            // Desktop, partly off a display) comes back as a sliver. Better no picture (the last good one stays) than a
            // stretched strip.
            let expected = size.width / max(size.height, 1)
            let got = CGFloat(image.width) / CGFloat(image.height)
            guard !checkShape || abs(got - expected) / expected < 0.12 else { return completion(nil) }
            guard !ThumbnailService.looksEmpty(image) else { return completion(nil) }
            completion(ImageScaler.scaled(image, toFit: size))
        }
    }

    /// A capture that came back fully transparent or black: a failed capture, not the window's content.
    static func looksEmpty(_ image: CGImage) -> Bool {
        let stats = ImageStats(image)
        return stats.mean < 2 && stats.deviation < 1
    }

    /// One full-resolution capture for the preview overlay and the stage; not cached, and outside the queue (it is the
    /// selected window, nothing is more urgent). Never more pixels than the window's screen can show.
    func captureLarge(_ request: Request, maxSide: CGFloat = 3000, completion: @escaping (CGImage?) -> Void) {
        guard isAvailable else { return completion(nil) }
        let screens = NSScreen.screens.map { (frame: ScreenGeometry.axRect(fromCocoa: $0.frame), scale: $0.backingScaleFactor) }
        let size = ThumbnailService.largeCaptureSize(frame: request.frame, screens: screens, maxSide: max(maxSide, maxPixelSize))
        capture(request, size: size) { image in
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Pixels worth capturing for a window shown at most at its real size: its frame at the density of the screen it is
    /// mostly on, capped to that screen's own pixel size and to `maxSide`. Frames and screens in the same (AX)
    /// coordinates.
    static func largeCaptureSize(frame: CGRect, screens: [(frame: CGRect, scale: CGFloat)], maxSide: CGFloat) -> CGSize {
        let width = max(frame.width, 1)
        let height = max(frame.height, 1)
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = screens.max { overlap($0.frame) < overlap($1.frame) }.flatMap { overlap($0.frame) > 0 ? $0 : nil } ?? screens.first
        let scale = screen?.scale ?? 2
        var factor = min(1, maxSide / (max(width, height) * scale))
        if let screen {
            factor = min(factor, screen.frame.width / width, screen.frame.height / height)
        }
        return CGSize(width: max(1, (width * scale * factor).rounded()), height: max(1, (height * scale * factor).rounded()))
    }

    // MARK: - ScreenCaptureKit window lookup

    private func withSCWindow(_ wid: CGWindowID, _ body: @escaping (SCWindow?) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let window = scWindows[wid] {
            lock.unlock()
            body(window)
            return
        }
        // A refresh that never called back (its service wedged after sleep) mustn't hold every capture forever.
        if let started = shareableRefreshStarted, now - started > 5 {
            let stranded = shareableWaiters
            shareableWaiters = []
            shareableRefreshStarted = nil
            lock.unlock()
            Log.warn("shareable content timed out")
            stranded.forEach { $0() }
            lock.lock()
        }
        // ScreenCaptureKit doesn't list every window (e.g. some minimized ones); don't re-query it for each of them.
        if shareableRefreshStarted == nil, now - lastShareableRefresh < 1.5 {
            lock.unlock()
            body(nil)
            return
        }
        shareableWaiters.append { [weak self] in
            guard let self else { return body(nil) }
            self.lock.lock()
            let window = self.scWindows[wid]
            self.lock.unlock()
            body(window)
        }
        let shouldStart = shareableRefreshStarted == nil
        if shouldStart { shareableRefreshStarted = now }
        let generation = shareableGeneration
        lock.unlock()
        guard shouldStart else { return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            if let error { Log.warn("shareable content failed: \(error.localizedDescription)") }
            self.lock.lock()
            if let content {
                var map = [CGWindowID: SCWindow]()
                for window in content.windows { map[window.windowID] = window }
                self.scWindows = map
            }
            let waiters = self.shareableWaiters
            self.shareableWaiters = []
            self.shareableRefreshStarted = nil
            // Invalidated while this refresh ran: it may already miss the new window, so the next miss asks again.
            self.lastShareableRefresh = generation == self.shareableGeneration ? ProcessInfo.processInfo.systemUptime : -100
            self.lock.unlock()
            waiters.forEach { $0() }
        }
    }

    /// Forget the SCWindow list so new windows are picked up on the next capture.
    func invalidateShareableContent() {
        lock.lock()
        lastShareableRefresh = -100
        shareableGeneration += 1
        lock.unlock()
    }
}

/// The order captures run in. Interactive requests (the switcher's cards, selected first) go ahead of background ones
/// (warming the cache), and background work never takes the last slot: a card on screen never waits for more than the
/// captures already under way.
struct CaptureQueue {
    let limit: Int
    private(set) var interactive = [ThumbnailService.Request]()
    private(set) var background = [ThumbnailService.Request]()

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var isEmpty: Bool { interactive.isEmpty && background.isEmpty }

    /// Ahead of everything already waiting at the same priority, replacing waiting requests for the same windows. A
    /// background request for a window that already waits as an interactive one changes nothing.
    mutating func add(_ requests: [ThumbnailService.Request], priority: ThumbnailService.Priority) {
        var seen = Set<CGWindowID>()
        var fresh = requests.filter { seen.insert($0.wid).inserted }
        switch priority {
        case .interactive:
            interactive.removeAll { seen.contains($0.wid) }
            background.removeAll { seen.contains($0.wid) }
            interactive.insert(contentsOf: fresh, at: 0)
        case .background:
            let waiting = Set(interactive.map(\.wid))
            fresh.removeAll { waiting.contains($0.wid) }
            let wids = Set(fresh.map(\.wid))
            background.removeAll { wids.contains($0.wid) }
            background.insert(contentsOf: fresh, at: 0)
        }
    }

    /// The next capture to start, given what runs already.
    mutating func next(running: Int, runningBackground: Int) -> (ThumbnailService.Request, ThumbnailService.Priority)? {
        guard running < limit else { return nil }
        if !interactive.isEmpty { return (interactive.removeFirst(), .interactive) }
        if !background.isEmpty, runningBackground < max(limit - 1, 1) { return (background.removeFirst(), .background) }
        return nil
    }
}

/// Timing of a burst of captures (a summon's cards, the warm-up at launch), logged once the queue drains: the numbers
/// to look at when tuning `ThumbnailService.maxConcurrent`.
struct CaptureBatch {
    static let minimumLogged = 4
    private var startedAt: TimeInterval?
    private var count = 0
    private var total: TimeInterval = 0
    private var slowest: TimeInterval = 0

    mutating func begin(at time: TimeInterval) {
        if startedAt == nil { startedAt = time }
    }

    mutating func record(_ duration: TimeInterval) {
        count += 1
        total += duration
        slowest = max(slowest, duration)
    }

    /// The summary of the batch that just finished, if it was big enough to say something; starts a new one.
    mutating func finish(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        defer { self = CaptureBatch() }
        guard let startedAt, count >= CaptureBatch.minimumLogged else { return nil }
        return String(format: "thumbnails: %d captured in %.0f ms (average %.0f ms, slowest %.0f ms, %d at a time)", count,
                      (now - startedAt) * 1000, total / Double(count) * 1000, slowest * 1000, ThumbnailService.maxConcurrent)
    }
}

/// Calls the wrapped completion once; later calls (a timeout racing a real answer) are ignored. Thread-safe.
final class Once<T> {
    private let lock = NSLock()
    private var completion: ((T) -> Void)?

    init(_ completion: @escaping (T) -> Void) { self.completion = completion }

    func call(_ value: T) {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()
        pending?(value)
    }

    func callAsFunction(_ value: T) { call(value) }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion == nil
    }
}

enum ImageScaler {
    static func scaled(_ image: CGImage, toFit size: CGSize) -> CGImage {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height), 1)
        guard scale < 0.98 else { return image }
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
