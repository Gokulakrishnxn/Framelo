import CoreGraphics
import CoreMedia
import Foundation

/// Coordinates one recording: owns the lifecycle state machine, the journal and the individual recorders.
public actor RecordingSession {
    public enum Phase: Sendable, Equatable {
        case idle, preparing, recording, paused, finalizing, finished
        /// Capture stopped on its own (display unplugged, window closed, disk error). What was captured is being saved.
        case interrupted(String)
        case failed(String)
    }

    public nonisolated let id: UUID
    /// Shared session clock; read `clock.elapsed` for the duration indicator.
    public nonisolated let clock = RecordingClock()
    /// Emits every phase change. Safe to iterate from the main actor.
    public nonisolated let phases: AsyncStream<Phase>

    private let phaseContinuation: AsyncStream<Phase>.Continuation
    private let config: RecordingConfig
    private let store: ProjectStore
    private var journal: RecordingJournal
    private var package: URL?
    private var phase = Phase.idle
    private var screen: ScreenRecorder?
    private var microphone: MicRecorder?
    private var camera: CameraRecorder?
    private var cursor: CursorRecorder?
    private var heartbeat: Task<Void, Never>?
    private var finalizeTask: Task<Project, Error>?
    /// Non-fatal problems the user should know about (e.g. microphone unavailable).
    public private(set) var notices: [String] = []

    public init(config: RecordingConfig, name: String, store: ProjectStore) {
        let id = UUID()
        self.id = id
        self.config = config
        self.store = store
        self.journal = RecordingJournal(id: id, name: name, config: config)
        (phases, phaseContinuation) = AsyncStream.makeStream(of: Phase.self, bufferingPolicy: .unbounded)
    }

    public var currentPhase: Phase { phase }

    private func setPhase(_ new: Phase) {
        phase = new
        phaseContinuation.yield(new)
    }

    private func writeJournal() {
        guard let package else { return }
        journal.heartbeat = Date()
        try? journal.write(to: package)
    }

    // MARK: Start

    /// Starts capture. Returns only after the first screen frame has been written to disk,
    /// so "recording" is never reported before it is true.
    public func start() async throws {
        guard phase == .idle else { throw RecordingError.alreadyRunning }
        guard PermissionManager.status(.screenRecording) == .granted else {
            throw RecordingError.permissionDenied(.screenRecording)
        }
        setPhase(.preparing)
        do {
            let package = try await store.createPackage(for: id)
            self.package = package
            writeJournal()

            let screen = ScreenRecorder(
                clock: clock,
                onFirstSample: { [weak self] kind, offset in Task { await self?.noteFirstSample(kind, offset) } },
                onInterruption: { [weak self] reason in Task { await self?.handleInterruption(reason) } })
            self.screen = screen
            let wantsAudioFile = config.captureSystemAudio
            let prepared = try await screen.prepare(
                config: config,
                videoURL: package.appendingPathComponent(RecordingJournal.TrackKind.screen.relativePath),
                audioURL: wantsAudioFile ? package.appendingPathComponent(RecordingJournal.TrackKind.systemAudio.relativePath) : nil)
            journal.capture = prepared.capture
            writeJournal()

            let micAllowed = config.captureMicrophone ? await ensure(.microphone) : false
            let cameraAllowed = config.captureCamera ? await ensure(.camera) : false

            clock.begin()
            try await screen.startCapture()

            if micAllowed {
                let mic = MicRecorder(clock: clock) { [weak self] offset in Task { await self?.noteFirstSample(.microphone, offset) } }
                do {
                    try mic.start(url: package.appendingPathComponent(RecordingJournal.TrackKind.microphone.relativePath),
                                  deviceID: config.microphoneID, noiseReduction: config.noiseReduction)
                    microphone = mic
                } catch {
                    notices.append("Microphone was not recorded: \(error.localizedDescription)")
                }
            }
            if cameraAllowed {
                let cam = CameraRecorder(clock: clock) { [weak self] offset in Task { await self?.noteFirstSample(.camera, offset) } }
                do {
                    try cam.start(url: package.appendingPathComponent(RecordingJournal.TrackKind.camera.relativePath),
                                  deviceID: config.cameraID)
                    camera = cam
                } catch {
                    notices.append("Camera was not recorded: \(error.localizedDescription)")
                }
            }

            let cursor = CursorRecorder(clock: clock)
            var windowID: CGWindowID?
            if case .window(let id) = config.target { windowID = id }
            let rect = CGRect(x: prepared.capture.x, y: prepared.capture.y,
                              width: prepared.capture.width, height: prepared.capture.height)
            if (try? cursor.start(url: package.appendingPathComponent(ProjectPackage.cursorFile),
                                  captureRect: rect, windowID: windowID)) != nil {
                self.cursor = cursor
            }

            try await screen.waitForFirstFrame()
            guard phase == .preparing else { return }   // interrupted while starting
            journal.state = .recording
            writeJournal()
            setPhase(.recording)
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    await self?.beat()
                }
            }
        } catch {
            await tearDownAfterFailure(error.localizedDescription)
            throw error
        }
    }

    private func ensure(_ kind: PermissionKind) async -> Bool {
        var status = PermissionManager.status(kind)
        if status == .notDetermined { status = await PermissionManager.request(kind) }
        if status != .granted {
            notices.append("\(kind.displayName) access is off, so it was not recorded. You can allow it in System Settings › Privacy & Security.")
        }
        return status == .granted
    }

    private func beat() {
        guard phase == .recording || phase == .paused else { return }
        writeJournal()
    }

    private func noteFirstSample(_ kind: RecordingJournal.TrackKind, _ offset: Double) {
        journal.setOffset(offset, for: kind)
        writeJournal()
    }

    private func tearDownAfterFailure(_ reason: String) async {
        heartbeat?.cancel()
        let end = clock.stop()
        cursor?.stop()
        _ = await screen?.stop(endTime: end)
        _ = await microphone?.stop()
        _ = await camera?.stop()
        screen = nil; microphone = nil; camera = nil; cursor = nil
        journal.state = .failed
        journal.failureReason = reason
        writeJournal()
        setPhase(.failed(reason))
        phaseContinuation.finish()
    }

    // MARK: Pause / resume

    public func pause() throws {
        guard phase == .recording else { throw RecordingError.notRecording }
        clock.pause()
        journal.state = .paused
        writeJournal()
        setPhase(.paused)
    }

    public func resume() throws {
        guard phase == .paused else { throw RecordingError.notRecording }
        clock.resume()
        journal.state = .recording
        writeJournal()
        setPhase(.recording)
    }

    // MARK: Stop

    /// Stops capture, closes all files and returns the saved project.
    /// If capture was interrupted earlier, returns the project that was saved at that point.
    public func stop() async throws -> Project {
        if let finalizeTask { return try await finalizeTask.value }
        guard phase == .recording || phase == .paused else { throw RecordingError.notRecording }
        return try await beginFinalize(interruption: nil).value
    }

    private func handleInterruption(_ reason: String) async {
        guard finalizeTask == nil else { return }
        switch phase {
        case .recording, .paused:
            notices.append(RecordingError.captureInterrupted(reason).localizedDescription)
            _ = try? await beginFinalize(interruption: reason).value
        case .preparing:
            // `start()` is still running and will report the failure itself.
            break
        default:
            break
        }
    }

    private func beginFinalize(interruption: String?) -> Task<Project, Error> {
        setPhase(interruption.map { .interrupted($0) } ?? .finalizing)
        let task = Task { try await self.finalize() }
        finalizeTask = task
        return task
    }

    private func finalize() async throws -> Project {
        heartbeat?.cancel()
        journal.state = .finalizing
        writeJournal()
        let end = clock.stop()
        cursor?.stop()

        let screenResult = await screen?.stop(endTime: end)
        let micResult = await microphone?.stop()
        let cameraResult = await camera?.stop()
        screen = nil; microphone = nil; camera = nil; cursor = nil

        if let video = screenResult?.video { journal.setOffset(video.startOffset, for: .screen) }
        if let audio = screenResult?.audio { journal.setOffset(audio.startOffset, for: .systemAudio) }
        if let mic = micResult?.result {
            journal.setOffset(mic.startOffset, for: .microphone)
            if let index = journal.tracks.firstIndex(where: { $0.kind == .microphone }) {
                journal.tracks[index].rateCorrection = micResult?.rateCorrection
            }
        }
        if let cam = cameraResult { journal.setOffset(cam.startOffset, for: .camera) }
        if let dropped = screenResult?.video?.droppedCount, dropped > 0 {
            notices.append("\(dropped) frames were skipped because the disk or encoder could not keep up.")
        }

        guard let package else { throw RecordingError.notRecording }
        do {
            let project = try await RecordingFinalizer.buildProject(package: package, journal: journal, recovered: false)
            try await store.save(project)
            await ThumbnailGenerator.writePoster(for: project, package: package)
            journal.state = .complete
            writeJournal()
            setPhase(.finished)
            phaseContinuation.finish()
            return project
        } catch {
            let reason = screenResult?.failure ?? error.localizedDescription
            journal.state = .failed
            journal.failureReason = reason
            writeJournal()
            setPhase(.failed(reason))
            phaseContinuation.finish()
            throw RecordingError.writerFailed(reason)
        }
    }

    /// Stops and discards the recording (moved to the Trash, so it can still be rescued).
    public func discard() async {
        if phase == .recording || phase == .paused {
            _ = try? await beginFinalize(interruption: nil).value
        } else if let finalizeTask {
            _ = try? await finalizeTask.value
        }
        try? await store.trash(id: id)
    }
}
