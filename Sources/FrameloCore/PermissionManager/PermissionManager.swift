import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import Speech

public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case screenRecording, microphone, camera, speechRecognition
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .speechRecognition: "Speech Recognition"
        }
    }

    /// Deep link to the matching pane of System Settings.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: String, Sendable {
    case granted, denied, notDetermined
}

/// Reads and requests the privacy permissions Framelo needs. Stateless; safe from any thread.
public enum PermissionManager {
    public static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            // The system offers no "not determined" state for screen capture.
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    /// Asks for a permission, showing the system prompt when it has not been decided yet.
    /// Screen recording can only be granted in System Settings; this registers the app there and returns the current state.
    public static func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .speechRecognition:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized ? .granted : .denied)
                }
            }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
