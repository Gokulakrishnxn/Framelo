@preconcurrency import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var name: String
    /// Size in points.
    public var width: Int
    public var height: Int
    public var isMain: Bool
}

public struct WindowInfo: Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var title: String
    public var appName: String
    public var width: Int
    public var height: Int
}

public struct CaptureDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
}

/// Lists what can be recorded right now.
public enum CaptureCatalog {
    public static func displays() async throws -> [DisplayInfo] {
        let content = try await shareableContent()
        let main = CGMainDisplayID()
        return content.displays.enumerated().map { index, display in
            DisplayInfo(id: display.displayID,
                        name: display.displayID == main ? "Main Display" : "Display \(index + 1)",
                        width: display.width, height: display.height, isMain: display.displayID == main)
        }.sorted { $0.isMain && !$1.isMain }
    }

    /// Normal, on-screen application windows that are large enough to be worth recording.
    public static func windows() async throws -> [WindowInfo] {
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, window.isOnScreen,
                  let app = window.owningApplication, app.processID != ownPID,
                  window.frame.width >= 160, window.frame.height >= 120 else { return nil }
            let title = (window.title ?? "").trimmingCharacters(in: .whitespaces)
            return WindowInfo(id: window.windowID, title: title.isEmpty ? app.applicationName : title,
                              appName: app.applicationName,
                              width: Int(window.frame.width), height: Int(window.frame.height))
        }
    }

    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw RecordingError.permissionDenied(.screenRecording) }
            throw error
        }
    }

    public static func cameras() -> [CaptureDeviceInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func microphones() -> [CaptureDeviceInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Core Audio device ID for a capture device's unique ID (needed to point `AVAudioEngine` at a specific input).
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &valueSize, $0)
            }
            if status == noErr, let string = value?.takeRetainedValue() as String?, string == uid { return id }
        }
        return nil
    }
}
