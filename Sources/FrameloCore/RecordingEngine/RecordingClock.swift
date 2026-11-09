import CoreMedia
import Foundation

/// The single timebase of a recording session, based on the host clock.
/// Every recorder converts its buffers' host timestamps to session time through this object,
/// so all tracks share one time zero and pauses are removed identically everywhere.
public final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var start: CMTime?
    private var pausedTotal = CMTime.zero
    private var pauseBegan: CMTime?
    private var stopped: CMTime?

    public init() {}

    public static func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    public func begin(at host: CMTime = RecordingClock.hostNow()) {
        lock.withLock {
            start = host
            pausedTotal = .zero
            pauseBegan = nil
            stopped = nil
        }
    }

    public func pause(at host: CMTime = RecordingClock.hostNow()) {
        lock.withLock { if start != nil, pauseBegan == nil, stopped == nil { pauseBegan = host } }
    }

    public func resume(at host: CMTime = RecordingClock.hostNow()) {
        lock.withLock {
            if let began = pauseBegan {
                pausedTotal = pausedTotal + (host - began)
                pauseBegan = nil
            }
        }
    }

    /// Freezes the clock. Returns the final session time.
    @discardableResult
    public func stop(at host: CMTime = RecordingClock.hostNow()) -> CMTime {
        lock.withLock {
            guard let start else { return .zero }
            if let stopped { return stopped }
            let end = pauseBegan ?? host
            let session = end - start - pausedTotal
            stopped = session
            return session
        }
    }

    public var isPaused: Bool { lock.withLock { pauseBegan != nil } }
    public var isRunning: Bool { lock.withLock { start != nil && stopped == nil } }

    /// Session time for a buffer stamped with host time `host`, or `nil` when the buffer must be dropped
    /// (before start, while paused, after stop).
    public func sessionTime(forHost host: CMTime) -> CMTime? {
        lock.withLock {
            guard let start, stopped == nil, pauseBegan == nil, host >= start else { return nil }
            let time = host - start - pausedTotal
            return time >= .zero ? time : nil
        }
    }

    /// Recorded (un-paused) time so far, in seconds.
    public var elapsed: Double {
        lock.withLock {
            guard let start else { return 0 }
            if let stopped { return stopped.seconds }
            let now = pauseBegan ?? Self.hostNow()
            return max(0, (now - start - pausedTotal).seconds)
        }
    }
}
