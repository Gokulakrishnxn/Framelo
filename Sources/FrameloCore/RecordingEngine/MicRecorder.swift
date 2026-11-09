@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Records the microphone with `AVAudioEngine`, optionally through Apple's voice processing (noise reduction).
///
/// Timestamps: the first buffer is anchored to the session clock via its host time; later buffers are placed by
/// sample count so the audio is gap-free. The difference between sample-count time and host time at the end
/// is the device's clock drift, reported as `rateCorrection`.
///
/// Concurrency: state is confined to `queue` (`@unchecked Sendable` invariant).
final class MicRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.framelo.recorder.microphone", qos: .userInitiated)
    private let clock: RecordingClock
    private let onFirstSample: @Sendable (Double) -> Void
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?
    private var sampleRate = 48_000.0
    private var anchor: CMTime?
    private var framesWritten: Int64 = 0
    private var lastSessionEnd: CMTime?
    private var running = false

    init(clock: RecordingClock, onFirstSample: @escaping @Sendable (Double) -> Void) {
        self.clock = clock
        self.onFirstSample = onFirstSample
    }

    func start(url: URL, deviceID: String?, noiseReduction: Bool) throws {
        let input = engine.inputNode
        if let deviceID, let audioDevice = CaptureCatalog.audioDeviceID(forUID: deviceID), let unit = input.audioUnit {
            var device = audioDevice
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if noiseReduction {
            // Voice processing = noise suppression + echo cancellation. If the device refuses it, record unprocessed.
            if (try? input.setVoiceProcessingEnabled(true)) != nil {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.sourceUnavailable("The microphone")
        }
        let writer = try TrackWriter.audio(url: url, sampleRate: format.sampleRate,
                                           channels: Int(format.channelCount), formatHint: format.formatDescription)
        let firstSample = onFirstSample
        writer.onFirstSample = { firstSample($0.seconds) }
        queue.sync {
            self.writer = writer
            self.sampleRate = format.sampleRate
            self.running = true
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.queue.sync { self?.handle(buffer, time: time) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            queue.sync { self.running = false; self.writer = nil }
            writer.abandon()
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.sourceUnavailable("The microphone (\(error.localizedDescription))")
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard running, let writer else { return }
        let host = time.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(time.hostTime) : RecordingClock.hostNow()
        guard let session = clock.sessionTime(forHost: host) else { return }
        if anchor == nil { anchor = session }
        guard let anchor else { return }
        let pts = anchor + CMTime(value: framesWritten, timescale: CMTimeScale(sampleRate))
        guard let sampleBuffer = CMSampleBuffer.make(from: buffer, at: pts) else { return }
        if writer.append(audio: sampleBuffer, at: pts) {
            framesWritten += Int64(buffer.frameLength)
            lastSessionEnd = session + CMTime(value: Int64(buffer.frameLength), timescale: CMTimeScale(sampleRate))
        }
    }

    /// Stops recording and closes the file. `rateCorrection` is `nil` when drift is negligible.
    func stop() async -> (result: TrackResult?, rateCorrection: Double?) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let (writer, correction) = queue.sync { () -> (TrackWriter?, Double?) in
            self.running = false
            let writer = self.writer
            self.writer = nil
            var correction: Double?
            if let anchor = self.anchor, let end = self.lastSessionEnd {
                correction = DriftAnalysis.rateCorrection(
                    mediaDuration: Double(self.framesWritten) / self.sampleRate,
                    wallDuration: (end - anchor).seconds)
            }
            return (writer, correction)
        }
        return (await writer?.finish(), correction)
    }
}

/// Decides whether an audio track needs a corrective playback rate to stay in sync with the video.
public enum DriftAnalysis {
    /// Drift below one 60 fps frame is inaudible and left alone.
    public static let tolerance = 1.0 / 60.0

    /// - Parameters:
    ///   - mediaDuration: length of the audio as written (sample count ÷ sample rate).
    ///   - wallDuration: length of the same audio measured on the session clock.
    /// - Returns: the rate to play the audio at so it spans `wallDuration`, or `nil` if no correction is needed.
    public static func rateCorrection(mediaDuration: Double, wallDuration: Double) -> Double? {
        guard mediaDuration > 5, wallDuration > 5 else { return nil }
        guard abs(mediaDuration - wallDuration) > tolerance else { return nil }
        let rate = mediaDuration / wallDuration
        // Real device drift is tiny (tens of ppm). A larger mismatch means dropped buffers, not drift;
        // stretching the audio would make things worse.
        guard (0.995...1.005).contains(rate) else { return nil }
        return rate
    }
}
