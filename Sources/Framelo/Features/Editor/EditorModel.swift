@preconcurrency import AVFoundation
import AppKit
import FrameloCore
import Observation
import SwiftUI

/// What is selected on the timeline; drives the contextual part of the inspector.
enum Selection: Equatable {
    case clip(UUID)
    case zoom(UUID)
    case keyframe(UUID)
    case text(UUID)
    case caption(UUID)
    case audioClip(UUID)
}

enum PreviewQuality: String, CaseIterable, Identifiable {
    case full, half, quarter
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var shortSide: Int {
        switch self {
        case .full: 1080
        case .half: 720
        case .quarter: 480
        }
    }
}

/// State and actions of one open project. Every change to the project goes through `CommandStack`,
/// so it is validated, undoable and autosaved.
@MainActor @Observable
final class EditorModel {
    private(set) var project: Project
    let store: ProjectStore
    let package: URL

    // Playback
    let player = AVPlayer()
    private(set) var currentTime = 0.0
    private(set) var isPlaying = false
    var playbackRate: Float = 1 {
        didSet { if isPlaying { player.rate = playbackRate } }
    }
    var quality = PreviewQuality.half {
        didSet { refreshVideoComposition() }
    }

    // UI state
    var selection: Selection?
    var showExport = false
    var showMotionEditor = false
    var pixelsPerSecond: Double = 60
    private(set) var loadError: String?
    private(set) var isLoading = true
    var errorMessage: String?
    private(set) var cursorTracks: [UUID: CursorTrack] = [:]
    private(set) var thumbnails: [UUID: [(time: Double, image: CGImage)]] = [:]
    private(set) var waveforms: [String: [Float]] = [:]
    private(set) var isTranscribing = false

    private var commands = CommandStack()
    private var built: BuiltComposition?
    private var context: RenderContext?
    private var builtSignature: Int?
    private var timeObserver: Any?
    private var autosaveTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        self.package = store.location.packageURL(for: project.id)
        player.actionAtItemEnd = .pause
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                let playing = self.player.rate != 0
                if playing != self.isPlaying { self.isPlaying = playing }
            }
        }
        timeObserver = observer
    }

    var duration: Double { project.duration.seconds }
    var canUndo: Bool { commands.canUndo }
    var canRedo: Bool { commands.canRedo }
    var undoTitle: String { commands.undoName.map { "Undo \($0)" } ?? "Undo" }
    var redoTitle: String { commands.redoName.map { "Redo \($0)" } ?? "Redo" }
    var timeMap: TimeMap { TimeMap(project: project) }
    var resolvedMotion: ResolvedMotion {
        RenderPlan(project: project, cursorTracks: cursorTracks, revision: commands.revision).motion
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        for source in project.sources {
            if let path = source.cursorPath {
                cursorTracks[source.id] = CursorTrack.load(from: ProjectPackage.resolve(path, in: package))
            }
        }
        // First open of a recording: suggest zooms from the recorded clicks.
        if project.timeline.zoomEvents.isEmpty, project.timeline.suppressedAutoZoomRanges.isEmpty,
           project.settings.motion.autoZoomEnabled, !cursorTracks.isEmpty {
            MotionEngine.regenerateAutomaticZooms(in: &project.timeline, cursor: timelineCursor, settings: project.settings.motion)
            scheduleAutosave()
        }
        await rebuild()
        loadThumbnailsAndWaveforms()
    }

    private var timelineCursor: TimelineCursor { TimelineCursor(timeMap: timeMap, tracks: cursorTracks) }

    private func loadThumbnailsAndWaveforms() {
        for source in project.sources {
            if let file = source.screen, source.kind != .importedAudio {
                let url = ProjectPackage.resolve(file.relativePath, in: package)
                let step = max(1, file.duration / 120)
                let times = Array(stride(from: 0, to: file.duration, by: step))
                let offset = file.startOffset
                Task { [weak self] in
                    let strip = await ThumbnailGenerator.strip(for: url, times: times)
                    self?.thumbnails[source.id] = strip.map { (time: $0.time + offset, image: $0.image) }
                }
            }
            for file in [source.microphone, source.systemAudio, source.kind != .recording ? source.screen : nil].compactMap({ $0 }) {
                let url = ProjectPackage.resolve(file.relativePath, in: package)
                let key = file.relativePath
                Task { [weak self] in
                    let peaks = await WaveformGenerator.peaks(url: url)
                    self?.waveforms[key] = peaks
                }
            }
        }
    }

    /// Hash of everything that affects the AVComposition (clips, sources, audio). Styling, zooms and
    /// overlays only change the render plan, which updates without rebuilding.
    private var compositionSignature: Int {
        var hasher = Hasher()
        hasher.combine(project.timeline.tracks)
        hasher.combine(project.sources)
        hasher.combine(project.settings.audio)
        return hasher.finalize()
    }

    private func makePlan() -> RenderPlan {
        RenderPlan(project: project, cursorTracks: cursorTracks, revision: commands.revision)
    }

    private func rebuild() async {
        let signature = compositionSignature
        do {
            let built = try await CompositionBuilder.build(project: project, package: package)
            guard signature == compositionSignature else { return }   // a newer edit superseded this build
            let context = built.makeContext(plan: makePlan())
            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = built.audioMix
            item.audioTimePitchAlgorithm = .spectral
            self.built = built
            self.context = context
            builtSignature = signature
            item.videoComposition = videoComposition()
            let time = CMTime(seconds: min(currentTime, max(0, built.duration.seconds - 0.01)), preferredTimescale: 600)
            player.replaceCurrentItem(with: item)
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            player.replaceCurrentItem(with: nil)
            built = nil
            context = nil
        }
    }

    private func videoComposition() -> AVVideoComposition? {
        guard let built, let context else { return nil }
        let size = ExportSettings.canvasSize(shortSide: quality.shortSide, aspect: project.canvasAspect)
        return built.videoComposition(context: context, renderSize: CGSize(width: size.width, height: size.height), frameRate: 30)
    }

    /// Pushes the latest plan to the compositor and asks the player to redraw the current frame.
    private func refreshVideoComposition() {
        context?.plan = makePlan()
        player.currentItem?.videoComposition = videoComposition()
    }

    private func projectChanged() {
        if compositionSignature != builtSignature {
            rebuildTask?.cancel()
            rebuildTask = Task { await rebuild() }
        } else {
            refreshVideoComposition()
        }
        if case .clip(let id) = selection, !project.timeline.videoClips.contains(where: { $0.id == id }) { selection = nil }
        if case .zoom(let id) = selection, !project.timeline.zoomEvents.contains(where: { $0.id == id }) { selection = nil }
        scheduleAutosave()
    }

    // MARK: Saving

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        autosaveTask?.cancel()
        do {
            try await store.save(project)
        } catch {
            errorMessage = "Your changes could not be saved: \(error.localizedDescription)"
        }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        rebuildTask?.cancel()
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: any TimelineCommand) -> Bool {
        do {
            try commands.perform(command, on: &project)
            projectChanged()
            return true
        } catch {
            errorMessage = error.localizedDescription
            NSSound.beep()
            return false
        }
    }

    /// A binding that edits a project value through an undoable, coalesced command.
    func binding<Value>(_ keyPath: WritableKeyPath<Project, Value>, _ name: String) -> Binding<Value> {
        Binding(get: { self.project[keyPath: keyPath] },
                set: { self.perform(SetValueCommand(name, keyPath, $0, coalescingKey: name)) })
    }

    func endGesture() { commands.breakCoalescing() }

    func undo() {
        do {
            if try commands.undo(on: &project) != nil { projectChanged() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func redo() {
        do {
            if try commands.redo(on: &project) != nil { projectChanged() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.rate = playbackRate
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration - 0.001, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        player.pause()
        seek(to: currentTime + Double(frames) / 30)
    }

    private var playhead: MediaTime { MediaTime(seconds: currentTime) }

    // MARK: Clip edits

    func splitAtPlayhead() {
        perform(TimelineEditCommand.split(at: playhead))
    }

    func deleteSelection() {
        guard let selection else { return }
        switch selection {
        case .clip(let id):
            perform(TimelineEditCommand.delete(clipID: id))
        case .zoom(let id):
            perform(TimelineEditCommand("Delete Zoom") { TimelineEditor.removeZoom(&$0, id: id) })
        case .keyframe(let id):
            perform(TimelineEditCommand("Delete Keyframe") { $0.keyframes.removeAll { $0.id == id } })
        case .text(let id):
            perform(TimelineEditCommand("Delete Text") { $0.textOverlays.removeAll { $0.id == id } })
        case .caption(let id):
            perform(TimelineEditCommand("Delete Caption") { $0.captions.removeAll { $0.id == id } })
        case .audioClip(let id):
            perform(TimelineEditCommand("Delete Audio") { timeline in
                for index in timeline.tracks.indices { timeline.tracks[index].audioClips.removeAll { $0.id == id } }
                timeline.tracks.removeAll { $0.type == .audio && $0.audioClips.isEmpty }
            })
        }
        self.selection = nil
    }

    func trim(clipID: UUID, sourceStart: MediaTime? = nil, sourceEnd: MediaTime? = nil) {
        perform(TimelineEditCommand.trim(clipID: clipID, sourceStart: sourceStart, sourceEnd: sourceEnd))
    }

    func moveClip(_ id: UUID, by offset: Int) {
        guard let index = project.timeline.videoClips.firstIndex(where: { $0.id == id }) else { return }
        perform(TimelineEditCommand.reorder(clipID: id, toIndex: index + offset))
    }

    func closeGaps() { perform(TimelineEditCommand.closeGaps()) }

    func clip(_ id: UUID) -> VideoClip? { project.timeline.videoClips.first { $0.id == id } }

    /// Binding to one property of a clip, applied as an undoable edit.
    func clipBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<VideoClip, Value>, _ name: String) -> Binding<Value>? {
        guard let clip = clip(id) else { return nil }
        return Binding(get: { self.clip(id)?[keyPath: keyPath] ?? clip[keyPath: keyPath] },
                       set: { value in
                           self.perform(TimelineEditCommand(name, coalescingKey: "\(name)-\(id)") { timeline in
                               var clips = timeline.videoClips
                               guard let index = clips.firstIndex(where: { $0.id == id }) else { throw TimelineEditError.clipNotFound }
                               clips[index][keyPath: keyPath] = value
                               timeline.videoClips = clips
                           })
                       })
    }

    func setSpeed(_ id: UUID, _ speed: Double) {
        perform(TimelineEditCommand.setSpeed(clipID: id, speed: speed))
    }

    // MARK: Zooms and keyframes

    func addZoom() {
        let start = playhead
        let end = min(start + MediaTime(seconds: 3), project.duration)
        guard end - start >= MediaTime(seconds: 1) else { NSSound.beep(); return }
        var target = (x: 0.5, y: 0.5)
        if let position = timelineCursor.rawPosition(at: currentTime) { target = (position.x, position.y) }
        let event = ZoomEvent(startTime: start, endTime: end, scale: project.settings.motion.defaultZoomScale,
                              targetX: min(max(target.x, 0), 1), targetY: min(max(target.y, 0), 1),
                              easing: project.settings.motion.easing, isAutomatic: false,
                              transitionIn: project.settings.motion.zoomInDuration, transitionOut: project.settings.motion.zoomOutDuration)
        if perform(TimelineEditCommand("Add Zoom") { TimelineEditor.upsertZoom(&$0, event) }) { selection = .zoom(event.id) }
    }

    func zoom(_ id: UUID) -> ZoomEvent? { project.timeline.zoomEvents.first { $0.id == id } }

    /// Edits a zoom. Any edit turns an automatic suggestion into a manual zoom, so regeneration keeps it.
    func updateZoom(_ id: UUID, name: String = "Edit Zoom", _ change: @escaping (inout ZoomEvent) -> Void) {
        guard var event = zoom(id) else { return }
        change(&event)
        event.isAutomatic = false
        if event.endTime - event.startTime < MediaTime(seconds: 0.3) { return }
        let updated = event
        perform(TimelineEditCommand(name, coalescingKey: "zoom-\(id)") { TimelineEditor.upsertZoom(&$0, updated) })
    }

    func zoomBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<ZoomEvent, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.zoom(id)?[keyPath: keyPath] ?? fallback },
                set: { value in self.updateZoom(id) { $0[keyPath: keyPath] = value } })
    }

    func regenerateAutoZoom() {
        let cursor = timelineCursor
        let settings = project.settings.motion
        perform(TimelineEditCommand("Regenerate Zooms") {
            MotionEngine.regenerateAutomaticZooms(in: &$0, cursor: cursor, settings: settings)
        })
    }

    func clearSuppressedZooms() {
        perform(TimelineEditCommand("Allow Removed Zooms") { $0.suppressedAutoZoomRanges = [] })
        regenerateAutoZoom()
    }

    func addKeyframe() {
        let state = resolvedMotion.path.state(at: currentTime)
        let keyframe = MotionKeyframe(timestamp: playhead, scale: max(state.scale, 1.5), positionX: state.centerX,
                                      positionY: state.centerY, easing: project.settings.motion.easing)
        if perform(TimelineEditCommand("Add Keyframe") { TimelineEditor.upsertKeyframe(&$0, keyframe) }) {
            selection = .keyframe(keyframe.id)
        }
    }

    func keyframe(_ id: UUID) -> MotionKeyframe? { project.timeline.keyframes.first { $0.id == id } }

    func keyframeBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<MotionKeyframe, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.keyframe(id)?[keyPath: keyPath] ?? fallback },
                set: { value in
                    guard var keyframe = self.keyframe(id) else { return }
                    keyframe[keyPath: keyPath] = value
                    let updated = keyframe
                    self.perform(TimelineEditCommand("Edit Keyframe", coalescingKey: "kf-\(id)") { TimelineEditor.upsertKeyframe(&$0, updated) })
                })
    }

    // MARK: Text and captions

    func addText() {
        let end = min(playhead + MediaTime(seconds: 3), project.duration)
        guard end > playhead else { NSSound.beep(); return }
        let overlay = TextOverlay(text: "Your title", startTime: playhead, endTime: end)
        if perform(TimelineEditCommand("Add Text") { $0.textOverlays.append(overlay) }) { selection = .text(overlay.id) }
    }

    func text(_ id: UUID) -> TextOverlay? { project.timeline.textOverlays.first { $0.id == id } }

    func textBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<TextOverlay, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.text(id)?[keyPath: keyPath] ?? fallback },
                set: { value in
                    self.perform(TimelineEditCommand("Edit Text", coalescingKey: "text-\(id)") { timeline in
                        guard let index = timeline.textOverlays.firstIndex(where: { $0.id == id }) else { return }
                        timeline.textOverlays[index][keyPath: keyPath] = value
                    })
                })
    }

    func captionBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Caption, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.project.timeline.captions.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
                set: { value in
                    self.perform(TimelineEditCommand("Edit Caption", coalescingKey: "caption-\(id)") { timeline in
                        guard let index = timeline.captions.firstIndex(where: { $0.id == id }) else { return }
                        timeline.captions[index][keyPath: keyPath] = value
                    })
                })
    }

    /// Moves every caption by `seconds` (subtitle timing adjustment).
    func shiftCaptions(by seconds: Double) {
        let delta = MediaTime(seconds: seconds)
        perform(TimelineEditCommand("Shift Captions") { timeline in
            timeline.captions = timeline.captions.compactMap { caption in
                var copy = caption
                copy.startTime = max(.zero, caption.startTime + delta)
                copy.endTime = caption.endTime + delta
                return copy.endTime > copy.startTime ? copy : nil
            }
        })
    }

    /// Transcribes the voice track on-device and turns it into captions on the timeline.
    func generateCaptions() {
        guard !isTranscribing else { return }
        guard let source = project.sources.first(where: { $0.microphone != nil || $0.screen?.hasAudio == true || $0.systemAudio != nil }),
              let file = source.microphone ?? (source.kind == .recording ? source.systemAudio : source.screen) else {
            errorMessage = TranscriptionError.noAudio.localizedDescription
            return
        }
        isTranscribing = true
        let url = ProjectPackage.resolve(file.relativePath, in: package)
        let temp = store.location.exportTempDirectory
        let map = timeMap
        Task {
            defer { isTranscribing = false }
            do {
                let words = try await TranscriptionService.transcribe(url, tempDirectory: temp)
                var captions: [Caption] = []
                for line in TranscriptionService.captionLines(from: words) {
                    // File time → session time → every place that moment appears on the timeline.
                    let start = MediaTime(seconds: file.startOffset + line.start)
                    let end = MediaTime(seconds: file.startOffset + line.end)
                    for timelineStart in map.timelineTimes(forSource: start, sourceID: source.id) {
                        captions.append(Caption(text: line.text, startTime: timelineStart,
                                                endTime: timelineStart + (end - start)))
                    }
                }
                guard !captions.isEmpty else {
                    errorMessage = "No speech was recognised in this recording."
                    return
                }
                let sorted = captions.sorted { $0.startTime < $1.startTime }
                perform(TimelineEditCommand("Generate Captions") { $0.captions = sorted })
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Audio and media

    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.message = "Choose music or a voice-over to add at the playhead."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let position = playhead
        Task {
            do {
                let source = try await MediaImporter.audioSource(url)
                // The source must exist before a clip may reference it. Sources are project media, not edits,
                // so adding one is not an undo step of its own (an unused source is harmless).
                if !project.sources.contains(where: { $0.id == source.id }) { project.sources.append(source) }
                let clip = AudioClip(sourceID: source.id, sourceStart: .zero, sourceEnd: MediaTime(seconds: source.duration),
                                     timelinePosition: position, fadeIn: 0.5, fadeOut: 1)
                perform(TimelineEditCommand("Add Audio") { timeline in
                    if let index = timeline.tracks.firstIndex(where: { $0.type == .audio }) {
                        // Place after the last clip if it would overlap.
                        var placed = clip
                        if let last = timeline.tracks[index].audioClips.map(\.timelineEnd).max(), last > placed.timelinePosition {
                            placed.timelinePosition = last
                        }
                        timeline.tracks[index].audioClips.append(placed)
                    } else {
                        timeline.tracks.append(TimelineTrack(name: "Music", type: .audio, audioClips: [clip]))
                    }
                })
                loadThumbnailsAndWaveforms()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func trackBinding<Value>(_ kind: TimelineTrack.Kind, _ keyPath: WritableKeyPath<TimelineTrack, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.project.timeline.track(kind)?[keyPath: keyPath] ?? fallback },
                set: { value in
                    self.perform(TimelineEditCommand("Track Settings", coalescingKey: "track-\(kind)") { timeline in
                        guard let index = timeline.tracks.firstIndex(where: { $0.type == kind }) else { return }
                        timeline.tracks[index][keyPath: keyPath] = value
                    })
                })
    }

    func audioClipBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<AudioClip, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
                    self.project.timeline.tracks.lazy.flatMap(\.audioClips).first { $0.id == id }?[keyPath: keyPath] ?? fallback
                },
                set: { value in
                    self.perform(TimelineEditCommand("Edit Audio", coalescingKey: "audio-\(id)") { timeline in
                        for t in timeline.tracks.indices {
                            if let c = timeline.tracks[t].audioClips.firstIndex(where: { $0.id == id }) {
                                timeline.tracks[t].audioClips[c][keyPath: keyPath] = value
                            }
                        }
                    })
                })
    }

    // MARK: Styling

    func apply(_ preset: StylePreset) {
        var settings = project.settings
        settings.background = preset.background
        settings.screen = preset.screen
        perform(SetValueCommand("Apply \(preset.name)", \Project.settings, settings))
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var background = project.settings.background
        background.kind = .image
        background.imagePath = url.path
        perform(SetValueCommand("Background Image", \Project.settings.background, background))
    }

    func useDesktopWallpaper() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            errorMessage = "The desktop picture could not be read."
            return
        }
        var background = project.settings.background
        background.kind = .wallpaper
        background.imagePath = url.path
        perform(SetValueCommand("Desktop Background", \Project.settings.background, background))
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        perform(SetValueCommand("Rename", \Project.name, trimmed))
    }

    var sourceForExport: (project: Project, package: URL, cursors: [UUID: CursorTrack]) {
        (project, package, cursorTracks)
    }
}
