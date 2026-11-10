@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

public struct TranscribedSegment: Sendable, Equatable {
    public var text: String
    /// Seconds from the start of the audio file.
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case permissionDenied
    case unavailable
    case noAudio
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech Recognition access is turned off for Framelo. Allow it in System Settings › Privacy & Security."
        case .unavailable:
            "Speech recognition is not available for your language on this Mac right now."
        case .noAudio:
            "This project has no voice audio to transcribe."
        case .failed(let reason):
            "Transcription failed: \(reason)"
        }
    }
}

/// Optional speech-to-text for captions. Uses on-device recognition whenever the system supports it,
/// so audio does not leave the Mac.
public enum TranscriptionService {
    /// Transcribes an audio (or movie) file and returns word-level segments.
    public static func transcribe(_ url: URL, tempDirectory: URL, locale: Locale = .current) async throws -> [TranscribedSegment] {
        var status = PermissionManager.status(.speechRecognition)
        if status == .notDetermined { status = await PermissionManager.request(.speechRecognition) }
        guard status == .granted else { throw TranscriptionError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw TranscriptionError.unavailable }

        // The recogniser wants a plain audio file; extract the audio track to a temporary .m4a.
        let asset = AVURLAsset(url: url)
        guard let hasAudio = try? await asset.loadTracks(withMediaType: .audio), !hasAudio.isEmpty else {
            throw TranscriptionError.noAudio
        }
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let audioURL = tempDirectory.appendingPathComponent("transcribe-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.failed("the audio could not be prepared")
        }
        do {
            try await session.export(to: audioURL, as: .m4a)
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let box = ContinuationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranscribedSegment], Error>) in
                box.set(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let segments = result.bestTranscription.segments.map {
                            TranscribedSegment(text: $0.substring, start: $0.timestamp, end: $0.timestamp + max($0.duration, 0.05))
                        }
                        box.resume(.success(segments))
                    } else if let error {
                        box.resume(.failure(TranscriptionError.failed(error.localizedDescription)))
                    }
                }
                // `SFSpeechRecognitionTask.cancel()` is documented as callable from any thread.
                nonisolated(unsafe) let cancellable = task
                box.setCancel { cancellable.cancel() }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Groups word segments into readable caption lines: a new line starts after a pause, at sentence
    /// punctuation, or when the line gets too long.
    public static func captionLines(from words: [TranscribedSegment], maxWords: Int = 8,
                                    maxDuration: Double = 3.6, pause: Double = 0.7) -> [TranscribedSegment] {
        var lines: [TranscribedSegment] = []
        var current: [TranscribedSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(TranscribedSegment(text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end))
            current.removeAll()
        }
        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last, let first = current.first {
                let endsSentence = last.text.last.map { ".!?".contains($0) } ?? false
                if word.start - last.end > pause || endsSentence || current.count >= maxWords || word.end - first.start > maxDuration {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        // Captions must not overlap: end each line no later than the next one starts.
        for index in lines.indices.dropLast() where lines[index].end > lines[index + 1].start {
            lines[index].end = lines[index + 1].start
        }
        return lines.filter { $0.end > $0.start }
    }
}

/// Makes sure a continuation is resumed exactly once, from whichever thread gets there first.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscribedSegment], Error>?
    private var cancelAction: (@Sendable () -> Void)?
    private var cancelled = false

    func set(_ continuation: CheckedContinuation<[TranscribedSegment], Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func setCancel(_ action: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            cancelAction = action
            return cancelled
        }
        if runNow { action() }
    }

    func resume(_ result: Result<[TranscribedSegment], Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<[TranscribedSegment], Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            cancelled = true
            return cancelAction
        }
        action?()
        resume(.failure(CancellationError()))
    }
}
