import Foundation

/// The arithmetic behind the playback shortcuts, kept free of AVKit so it can be tested.
public enum PlaybackMath {
    public static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// Where to seek after skipping `delta` seconds, never before the start or past the end.
    public static func seekTarget(current: Double, delta: Double, duration: Double?) -> Double {
        let target = current + delta
        guard let duration, duration.isFinite, duration > 0 else { return max(0, target) }
        return min(max(0, target), duration)
    }

    /// The next speed up or down the list; stays at the ends. A speed not on the list snaps to its neighbour.
    public static func nextRate(from rate: Double, up: Bool) -> Double {
        if up { return rates.first { $0 > rate + 0.001 } ?? rates.last! }
        return rates.last { $0 < rate - 0.001 } ?? rates.first!
    }

    public static func volume(_ volume: Float, delta: Float) -> Float {
        min(max((volume + delta) * 100, 0), 100).rounded() / 100
    }

    /// True when playback is at (or within a tenth of a second of) the end.
    public static func isAtEnd(current: Double, duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return current >= duration - 0.1
    }
}
