import Foundation

/// Everything the renderer needs to draw one frame. Computed only by `FrameStateEvaluator`,
/// so preview and export cannot disagree.
public struct FrameState: Sendable, Equatable {
    public struct Screen: Sendable, Equatable {
        public var sourceID: UUID
        public var sourceTime: MediaTime
        /// 0…1 — clip transitions fade the screen card.
        public var opacity: Double
        /// Extra scale from clip transitions (1 = none).
        public var transitionScale: Double
    }

    public struct Cursor: Sendable, Equatable {
        /// Normalised to the screen content.
        public var x: Double
        public var y: Double
        public var scale: Double
        public var opacity: Double
        public var kind: CursorKind
    }

    public struct Ripple: Sendable, Equatable {
        public var x: Double
        public var y: Double
        /// 0 at the click, 1 when the effect has finished.
        public var progress: Double
    }

    public struct Pip: Sendable, Equatable {
        /// Centre and height, normalised to the canvas.
        public var centerX: Double
        public var centerY: Double
        public var height: Double
        /// Session time of the camera frame to show.
        public var sourceID: UUID
        public var sourceTime: MediaTime
    }

    public struct Overlay: Sendable, Equatable {
        public var id: UUID
        public var opacity: Double
    }

    public var time: MediaTime
    /// `nil` in a gap: only the background is drawn.
    public var screen: Screen?
    public var camera: CameraState
    /// Camera movement in content units per second (x, y) and scale units per second.
    public var cameraVelocityX: Double
    public var cameraVelocityY: Double
    public var cameraVelocityScale: Double
    public var cursor: Cursor?
    /// Cursor movement in content units per second, for cursor motion blur.
    public var cursorVelocityX: Double
    public var cursorVelocityY: Double
    public var ripples: [Ripple]
    public var pip: Pip?
    public var overlays: [Overlay]
    public var captionID: UUID?
}

/// Immutable snapshot of a project prepared for rendering. Cheap to copy, safe to share between threads.
public struct RenderPlan: Sendable {
    public let project: Project
    public let timeMap: TimeMap
    public let motion: ResolvedMotion
    public let cursor: TimelineCursor
    /// Bumped whenever the plan changes; used to invalidate frame caches.
    public let revision: Int

    public init(project: Project, cursorTracks: [UUID: CursorTrack], revision: Int = 0) {
        self.project = project
        self.timeMap = TimeMap(project: project)
        self.cursor = TimelineCursor(timeMap: timeMap, tracks: cursorTracks)
        self.motion = MotionEngine.resolve(timeline: project.timeline, cursor: cursor)
        self.revision = revision
    }

    public var evaluator: FrameStateEvaluator { FrameStateEvaluator(plan: self) }
}

/// The only code that turns (project, time) into a `FrameState`. Pure and deterministic.
public struct FrameStateEvaluator: Sendable {
    public static let rippleDuration = 0.55
    public static let pressDuration = 0.09

    public let plan: RenderPlan

    public init(plan: RenderPlan) { self.plan = plan }

    public func evaluate(at time: MediaTime) -> FrameState {
        let project = plan.project
        let settings = project.settings
        let seconds = time.seconds

        // Screen
        var screen: FrameState.Screen?
        var segment: TimeMap.Segment?
        if case .clip(let index, let sourceTime) = plan.timeMap.locate(time) {
            let s = plan.timeMap.segments[index]
            segment = s
            let clip = project.timeline.videoClips.first { $0.id == s.clipID }
            let (opacity, scale) = transition(for: clip, at: seconds, segment: s)
            screen = FrameState.Screen(sourceID: s.sourceID, sourceTime: sourceTime, opacity: opacity, transitionScale: scale)
        }

        // Camera
        let camera = plan.motion.path.state(at: seconds)
        let velocity = plan.motion.path.velocity(at: seconds)

        // Cursor and clicks
        var cursor: FrameState.Cursor?
        var cursorVelocity = (x: 0.0, y: 0.0)
        var ripples: [FrameState.Ripple] = []
        if screen != nil, let (track, sourceTime) = plan.cursor.lookup(time) {
            let style = settings.cursor
            if style.isVisible, let p = CursorSmoother.position(in: track, at: sourceTime, smoothing: style.smoothing) {
                var opacity = 1.0
                if style.hidesWhenIdle {
                    let idle = CursorSmoother.idleTime(in: track, at: sourceTime, limit: style.idleDelay + 0.5)
                    opacity = 1 - min(max((idle - style.idleDelay) / 0.4, 0), 1)
                }
                if opacity > 0, p.x > -0.05, p.x < 1.05, p.y > -0.05, p.y < 1.05 {
                    cursor = FrameState.Cursor(x: p.x, y: p.y, scale: style.size * pressScale(track, sourceTime, style),
                                               opacity: opacity, kind: track.kind(at: sourceTime))
                    let dt = 1.0 / 120
                    if let a = CursorSmoother.position(in: track, at: sourceTime - dt, smoothing: style.smoothing),
                       let b = CursorSmoother.position(in: track, at: sourceTime + dt, smoothing: style.smoothing) {
                        let speed = segment?.speed ?? 1
                        cursorVelocity = ((b.x - a.x) / (2 * dt) * speed, (b.y - a.y) / (2 * dt) * speed)
                    }
                }
            }
            if style.clickEffect != .none {
                for click in track.clicks where sourceTime >= click.t && sourceTime < click.t + Self.rippleDuration {
                    ripples.append(FrameState.Ripple(x: click.x, y: click.y, progress: (sourceTime - click.t) / Self.rippleDuration))
                }
            }
        }

        // Camera picture-in-picture
        var pip: FrameState.Pip?
        if let screen, settings.camera.isVisible, project.timeline.track(.camera)?.isVisible ?? true,
           let source = project.source(screen.sourceID), let file = source.camera {
            let local = screen.sourceTime.seconds - file.startOffset
            if local >= 0, local <= file.duration {
                let zoomAmount = min(max((camera.scale - 1) / 0.5, 0), 1)
                let shrink = lerp(1, settings.camera.zoomedScale, zoomAmount)
                pip = FrameState.Pip(centerX: settings.camera.positionX, centerY: settings.camera.positionY,
                                     height: settings.camera.size * shrink,
                                     sourceID: source.id, sourceTime: screen.sourceTime)
            }
        }

        // Text and captions
        var overlays: [FrameState.Overlay] = []
        for overlay in project.timeline.textOverlays where overlay.range.contains(time) {
            let fade = max(overlay.fadeDuration, 0)
            var opacity = 1.0
            if fade > 0 {
                opacity = min(1, (seconds - overlay.startTime.seconds) / fade, (overlay.endTime.seconds - seconds) / fade)
            }
            overlays.append(FrameState.Overlay(id: overlay.id, opacity: max(0, opacity)))
        }
        let caption = settings.captions.isVisible ? project.timeline.captions.first { $0.range.contains(time) }?.id : nil

        return FrameState(time: time, screen: screen, camera: camera,
                          cameraVelocityX: velocity.centerX, cameraVelocityY: velocity.centerY, cameraVelocityScale: velocity.scale,
                          cursor: cursor, cursorVelocityX: cursorVelocity.x, cursorVelocityY: cursorVelocity.y,
                          ripples: ripples, pip: pip, overlays: overlays, captionID: caption)
    }

    private func transition(for clip: VideoClip?, at seconds: Double, segment: TimeMap.Segment) -> (opacity: Double, scale: Double) {
        guard let clip else { return (1, 1) }
        var amount = 1.0   // 1 = fully shown
        var kind = ClipTransition.Kind.fade
        if let t = clip.transitionIn, t.duration > 0 {
            let p = (seconds - segment.timeline.start.seconds) / t.duration
            if p < 1 { amount = min(amount, Easing.easeOut.value(p)); kind = t.kind }
        }
        if let t = clip.transitionOut, t.duration > 0 {
            let p = (segment.timeline.end.seconds - seconds) / t.duration
            if p < 1 { amount = min(amount, Easing.easeOut.value(p)); kind = t.kind }
        }
        let scale = kind == .zoomFade ? lerp(0.94, 1, amount) : 1
        return (amount, scale)
    }

    private func pressScale(_ track: CursorTrack, _ time: Double, _ style: CursorStyle) -> Double {
        var amount = 0.0   // 1 = fully pressed
        for click in track.clicks {
            if click.t > time { break }
            let release = max(click.releaseTime, click.t + Self.pressDuration)
            if time <= release {
                amount = max(amount, min(1, (time - click.t) / Self.pressDuration))
            } else if time <= release + Self.pressDuration {
                amount = max(amount, 1 - (time - release) / Self.pressDuration)
            }
        }
        return lerp(1, style.pressScale, amount)
    }
}
