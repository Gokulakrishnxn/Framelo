import Foundation

/// A click expressed in timeline time.
public struct TimelineClick: Sendable, Equatable {
    public var time: Double
    public var x: Double
    public var y: Double
}

/// Cursor data mapped onto the timeline through the current edit.
public struct TimelineCursor: Sendable {
    public let timeMap: TimeMap
    public let tracks: [UUID: CursorTrack]

    public init(timeMap: TimeMap, tracks: [UUID: CursorTrack]) {
        self.timeMap = timeMap
        self.tracks = tracks
    }

    public static let empty = TimelineCursor(timeMap: TimeMap(clips: []), tracks: [:])

    /// Cursor track and session time for a timeline time, or `nil` in a gap or when no cursor was recorded.
    public func lookup(_ time: MediaTime) -> (track: CursorTrack, sourceTime: Double)? {
        guard case .clip(let index, let sourceTime) = timeMap.locate(time),
              let track = tracks[timeMap.segments[index].sourceID], !track.isEmpty else { return nil }
        return (track, sourceTime.seconds)
    }

    public func rawPosition(at seconds: Double) -> (x: Double, y: Double)? {
        guard let (track, sourceTime) = lookup(MediaTime(seconds: seconds)) else { return nil }
        return track.position(at: sourceTime)
    }

    /// Every click that survives the edit, in timeline time, sorted.
    public var clicks: [TimelineClick] {
        var result: [TimelineClick] = []
        for segment in timeMap.segments {
            guard let track = tracks[segment.sourceID] else { continue }
            let start = segment.sourceStart.seconds
            let end = segment.sourceEnd.seconds
            for click in track.clicks where click.t >= start && click.t < end {
                let time = segment.timeline.start.seconds + (click.t - start) / segment.speed
                result.append(TimelineClick(time: time, x: click.x, y: click.y))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}

/// Suggests zooms from where and when the user clicked.
public enum AutoZoomGenerator {
    /// Clicks closer together than this belong to one zoom.
    public static let clusterGap = 3.0
    /// How long the camera stays in after the last click of a cluster.
    public static let hold = 1.6
    /// Zooms separated by less than this are merged, so the camera does not bounce out and straight back in.
    public static let minimumGap = 1.2

    public static func generate(clicks: [TimelineClick], duration: Double, settings: MotionSettings) -> [ZoomEvent] {
        let usable = clicks.filter { (0...1).contains($0.x) && (0...1).contains($0.y) && $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        guard !usable.isEmpty, duration > 0 else { return [] }

        var clusters: [[TimelineClick]] = []
        for click in usable {
            if let last = clusters.last?.last, click.time - last.time <= clusterGap {
                clusters[clusters.count - 1].append(click)
            } else {
                clusters.append([click])
            }
        }

        var events: [ZoomEvent] = []
        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last else { continue }
            // Arrive at the target just before the first click lands.
            let start = max(0, first.time - settings.zoomInDuration * 0.9)
            let end = min(duration, last.time + hold + settings.zoomOutDuration)
            guard end - start >= settings.zoomInDuration + settings.zoomOutDuration else { continue }
            events.append(ZoomEvent(startTime: MediaTime(seconds: start), endTime: MediaTime(seconds: end),
                                    scale: settings.defaultZoomScale, targetX: first.x, targetY: first.y,
                                    easing: settings.easing, isAutomatic: true, followsCursor: true,
                                    transitionIn: settings.zoomInDuration, transitionOut: settings.zoomOutDuration))
        }
        return merge(events)
    }

    /// Merges events that overlap or sit closer than `minimumGap`. The merged event keeps the first event's
    /// target (the camera then follows the cursor to later ones) and the larger scale.
    public static func merge(_ events: [ZoomEvent]) -> [ZoomEvent] {
        var result: [ZoomEvent] = []
        for event in events.sorted(by: { $0.startTime < $1.startTime }) {
            if var last = result.last, event.startTime.seconds - last.endTime.seconds < minimumGap {
                last.endTime = max(last.endTime, event.endTime)
                last.scale = max(last.scale, event.scale)
                last.followsCursor = true
                result[result.count - 1] = last
            } else {
                result.append(event)
            }
        }
        return result
    }
}

/// The camera move for a project, ready to evaluate.
public struct ResolvedMotion: Sendable, Equatable {
    /// The zoom events that are actually in effect, after conflict resolution.
    public var events: [ZoomEvent]
    public var path: CameraPath

    public static let none = ResolvedMotion(events: [], path: .empty)
}

public enum MotionEngine {
    /// Replaces the project's automatic zooms with fresh suggestions. Manual zooms are never touched, and no
    /// suggestion is placed over a manual zoom, a keyframed span, or a range where the user deleted a suggestion.
    public static func regenerateAutomaticZooms(in timeline: inout Timeline, cursor: TimelineCursor, settings: MotionSettings) {
        let manual = timeline.zoomEvents.filter { !$0.isAutomatic }
        guard settings.autoZoomEnabled else {
            timeline.zoomEvents = manual
            return
        }
        let duration = timeline.duration.seconds
        var blocked = manual.map(\.range) + timeline.suppressedAutoZoomRanges
        if let first = timeline.keyframes.first, let last = timeline.keyframes.last {
            blocked.append(MediaRange(start: first.timestamp - MediaTime(seconds: CameraPath.keyframeLead),
                                      end: last.timestamp + MediaTime(seconds: CameraPath.keyframeLead)))
        }
        // Keep clear of manual zooms by the merge gap as well, so the camera has time to settle between them.
        let margin = MediaTime(seconds: AutoZoomGenerator.minimumGap)
        let candidates = AutoZoomGenerator.generate(clicks: cursor.clicks, duration: duration, settings: settings)
        let accepted = candidates.filter { candidate in
            let padded = MediaRange(start: candidate.startTime - margin, end: candidate.endTime + margin)
            return !blocked.contains { $0.overlaps(padded) }
        }
        timeline.zoomEvents = (manual + accepted).sorted { $0.startTime < $1.startTime }
    }

    /// Resolves conflicts and builds the camera path:
    /// 1. manual events win over automatic ones that overlap them;
    /// 2. overlapping automatic events are merged;
    /// 3. overlapping manual events are trimmed so they follow one another;
    /// 4. events inside a keyframed span are dropped (keyframes win);
    /// 5. times, transitions and targets are clamped so the move is continuous and stays inside the picture.
    public static func resolve(timeline: Timeline, cursor: TimelineCursor) -> ResolvedMotion {
        let duration = timeline.duration.seconds
        let keyframes = timeline.keyframes.sorted { $0.timestamp < $1.timestamp }.map {
            ResolvedKeyframe(time: $0.timestamp.seconds,
                             state: CameraState(scale: $0.scale, centerX: $0.positionX, centerY: $0.positionY).clamped(),
                             easing: $0.easing)
        }
        var path = CameraPath(zooms: [], keyframes: keyframes)
        let keyframeSpan = path.keyframeSpan

        let manual = timeline.zoomEvents.filter { !$0.isAutomatic }.sorted { $0.startTime < $1.startTime }
        let automatic = AutoZoomGenerator.merge(timeline.zoomEvents.filter { $0.isAutomatic }).filter { auto in
            !manual.contains { $0.range.overlaps(auto.range) }
        }

        var ordered: [ZoomEvent] = []
        for var event in (manual + automatic).sorted(by: { $0.startTime < $1.startTime }) {
            if let previous = ordered.last, event.startTime < previous.endTime {
                event.startTime = previous.endTime
            }
            event.startTime = max(event.startTime, .zero)
            if duration > 0 { event.endTime = min(event.endTime, MediaTime(seconds: duration)) }
            guard event.duration.seconds >= 2 * CameraPath.minimumTransition else { continue }
            if let span = keyframeSpan, event.startTime.seconds < span.upperBound, event.endTime.seconds > span.lowerBound {
                continue
            }
            ordered.append(event)
        }

        path.zooms = ordered.map { event in
            let start = event.startTime.seconds
            let end = event.endTime.seconds
            // Bigger zooms need longer transitions; if the event is too short for its zoom, the zoom is reduced
            // rather than letting the camera snap.
            var scale = min(max(event.scale, 1), TimelineValidator.zoomScaleRange.upperBound)
            if 2 * CameraPath.minimumTransition(forScale: scale) > end - start {
                scale = max(1, CameraPath.maximumScale(forTransition: (end - start) / 2))
            }
            let floor = CameraPath.minimumTransition(forScale: scale)
            var transitionIn = max(event.transitionIn, floor)
            var transitionOut = max(event.transitionOut, floor)
            let total = transitionIn + transitionOut
            if total > end - start {
                let factor = (end - start) / total
                transitionIn *= factor
                transitionOut *= factor
            }
            return ResolvedZoom(id: event.id, start: start, end: end, scale: scale,
                                transitionIn: transitionIn, transitionOut: transitionOut, easing: event.easing,
                                targets: followTargets(for: event, start: start, end: end, scale: scale, cursor: cursor))
        }
        return ResolvedMotion(events: ordered, path: path)
    }

    /// The camera target over an event: fixed, or a critically damped spring chasing the cursor.
    /// The spring starts at rest on the event's own target, so the camera never jumps when the event begins.
    static func followTargets(for event: ZoomEvent, start: Double, end: Double, scale: Double,
                              cursor: TimelineCursor) -> [SIMD2<Double>] {
        let half = 0.5 / scale
        func clamp(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(min(max(p.x, half), 1 - half), min(max(p.y, half), 1 - half))
        }
        let origin = clamp(SIMD2(event.targetX, event.targetY))
        guard event.followsCursor, cursor.rawPosition(at: start) != nil else { return [origin] }

        let omega = 3.2                       // rad/s — settles in roughly 1.5 s
        let substeps = 4
        let dt = 1 / (CameraPath.followRate * Double(substeps))
        let count = Int(((end - start) * CameraPath.followRate).rounded(.up)) + 1
        var position = origin
        var velocity = SIMD2<Double>(0, 0)
        var samples: [SIMD2<Double>] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            samples.append(clamp(position))
            for s in 0..<substeps {
                let time = start + (Double(i) + Double(s) / Double(substeps)) / CameraPath.followRate
                var goal = position
                if let raw = cursor.rawPosition(at: time) {
                    goal = clamp(SIMD2(raw.x, raw.y))
                    // Ignore small movements so the camera does not drift with every twitch of the hand.
                    let offset = goal - position
                    let dead = 0.12 / scale
                    if abs(offset.x) < dead && abs(offset.y) < dead { goal = position }
                }
                let acceleration = (goal - position) * (omega * omega) - velocity * (2 * omega)
                velocity += acceleration * dt
                position += velocity * dt
            }
        }
        return samples
    }
}
