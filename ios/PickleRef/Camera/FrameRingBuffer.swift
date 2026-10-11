import CoreVideo
import Foundation

/// Bounded FIFO of recent frames. Two uses:
/// 1. Trajectory arc fitting across occlusion gaps (look-back window).
/// 2. Replay clips around a detected bounce.
///
/// Retains pixel buffers only for a short window; a 120 fps × 2 s window at
/// 1080p is heavy (~500 MB NV12), so the POC keeps a small sliding window and
/// downsampled luma copies for replay thumbnails. Full-res buffers are handed
/// to consumers synchronously and not retained here beyond the window.
final class FrameRingBuffer {
    struct Entry {
        let frame: VideoFrame
        /// Downsampled grayscale thumbnail for UI replay (optional).
        var thumbnail: [UInt8]?
        var thumbWidth: Int = 0
        var thumbHeight: Int = 0
    }

    private var entries: [Entry] = []
    private let capacity: Int
    private let lock = NSLock()

    /// Seconds of history to keep (drives both arc-fit window and replay).
    private(set) var windowSeconds: Double

    init(capacity: Int = 360, windowSeconds: Double = 3.0) {
        self.capacity = capacity
        self.windowSeconds = windowSeconds
    }

    func append(_ frame: VideoFrame) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(frame: frame))
        trimLocked()
    }

    private func trimLocked() {
        guard let newest = entries.last else { return }
        let cutoff = newest.frame.timeSeconds - windowSeconds
        while let first = entries.first, first.frame.timeSeconds < cutoff || entries.count > capacity {
            entries.removeFirst()
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Frames within `seconds` before `time` (exclusive), oldest first.
    func frames(before time: Double, within seconds: Double) -> [VideoFrame] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = time - seconds
        return entries.map(\.frame).filter { $0.timeSeconds < time && $0.timeSeconds >= cutoff }
    }

    /// Frames within `±seconds` around `time`, oldest first (for replay).
    func clip(around time: Double, seconds: Double) -> [VideoFrame] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.frame).filter { abs($0.timeSeconds - time) <= seconds }
    }

    var newest: VideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return entries.last?.frame
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
