import Foundation

/// Stores replay clips (frame time ranges) for UI playback. The POC keeps
/// metadata only — actual pixel playback is done by re-reading the ring
/// buffer's frames in the UI layer.
final class ReplayBuffer {
    struct Clip {
        let call: LineCall
        let frameTimes: [Double]
        let createdAt: Date
    }

    private(set) var clips: [Clip] = []
    private let maxClips = 20

    func save(call: LineCall, frames: [VideoFrame]) {
        let clip = Clip(call: call,
                        frameTimes: frames.map { $0.timeSeconds },
                        createdAt: Date())
        clips.insert(clip, at: 0)
        if clips.count > maxClips { clips.removeLast() }
    }

    func clear() { clips.removeAll() }
}
