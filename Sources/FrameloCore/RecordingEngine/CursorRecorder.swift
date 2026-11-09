import AppKit
import CoreGraphics
import CoreMedia
import Foundation

/// Samples the pointer position and button state at 120 Hz and appends them to `cursor.jsonl`.
/// Uses only Quartz event-state queries, which need no Accessibility or Input Monitoring permission.
///
/// Concurrency: state is confined to `queue` (`@unchecked Sendable` invariant).
final class CursorRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.framelo.recorder.cursor", qos: .userInitiated)
    private let clock: RecordingClock
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var pending = ""
    private var rect = CGRect.zero
    private var windowID: CGWindowID?
    private var tick = 0
    private var lastSample: CursorSample?
    private var buttonDown = false
    private var lastKind = CursorKind.arrow

    static let sampleRate = 120.0

    init(clock: RecordingClock) {
        self.clock = clock
    }

    /// - Parameters:
    ///   - captureRect: recorded area in global points (top-left origin).
    ///   - windowID: when recording a window, its bounds are re-read while recording so moving it keeps the cursor aligned.
    func start(url: URL, captureRect: CGRect, windowID: CGWindowID?) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        queue.sync {
            self.handle = handle
            self.rect = captureRect
            self.windowID = windowID
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Self.sampleRate, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    private func sample() {
        tick += 1
        if tick % 12 == 0 {
            refreshWindowBounds()
            refreshCursorKind()
        }
        if tick % 30 == 0 { flush() }
        guard rect.width > 0, rect.height > 0,
              let time = clock.sessionTime(forHost: RecordingClock.hostNow())?.seconds,
              let location = CGEvent(source: nil)?.location else { return }

        let x = (location.x - rect.minX) / rect.width
        let y = (location.y - rect.minY) / rect.height
        let moved = lastSample.map { abs($0.x - x) > 0.0002 || abs($0.y - y) > 0.0002 } ?? true
        let stale = lastSample.map { time - $0.t > 0.25 } ?? true
        if moved || stale {
            let sample = CursorSample(t: time, x: x, y: y)
            pending += CursorTrack.encodeMove(sample)
            lastSample = sample
        }

        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if down != buttonDown {
            buttonDown = down
            // Only clicks inside the recorded area matter for zooms and click effects.
            if down {
                if (0...1).contains(x), (0...1).contains(y) { pending += CursorTrack.encodeDown(t: time, x: x, y: y) }
            } else {
                pending += CursorTrack.encodeUp(t: time)
            }
        }
    }

    private func refreshWindowBounds() {
        guard let windowID,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]],
              let boundsValue = info.first?[kCGWindowBounds],
              let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary) else { return }
        if bounds.width > 0, bounds.height > 0 { rect = bounds }
    }

    private func refreshCursorKind() {
        Task { @MainActor [weak self] in
            let kind = Self.currentKind()
            self?.queue.async {
                guard let self, kind != self.lastKind,
                      let time = self.clock.sessionTime(forHost: RecordingClock.hostNow())?.seconds else { return }
                self.lastKind = kind
                self.pending += CursorTrack.encodeKind(t: time, kind: kind)
            }
        }
    }

    @MainActor
    private static func currentKind() -> CursorKind {
        guard let current = NSCursor.currentSystem else { return .arrow }
        func matches(_ cursor: NSCursor) -> Bool {
            current.hotSpot == cursor.hotSpot && current.image.size == cursor.image.size
        }
        if matches(.iBeam) { return .iBeam }
        if matches(.pointingHand) { return .pointingHand }
        return .arrow
    }

    private func flush() {
        guard !pending.isEmpty, let handle else { return }
        try? handle.write(contentsOf: Data(pending.utf8))
        pending = ""
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            flush()
            try? handle?.close()
            handle = nil
        }
    }
}
