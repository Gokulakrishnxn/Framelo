import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon hot keys, which work while another app is in front
/// and need no Accessibility permission.
@MainActor
final class HotKeyCenter {
    enum Shortcut: UInt32, CaseIterable {
        case toggleRecording = 1
        case togglePause = 2

        var keyCode: UInt32 {
            switch self {
            case .toggleRecording: UInt32(kVK_ANSI_2)
            case .togglePause: UInt32(kVK_ANSI_P)
            }
        }

        var modifiers: UInt32 { UInt32(cmdKey | shiftKey) }

        var display: String {
            switch self {
            case .toggleRecording: "⇧⌘2"
            case .togglePause: "⇧⌘P"
            }
        }
    }

    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef] = []
    private var installed = false

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[shortcut.rawValue] = handler
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x46524D4C), id: shortcut.rawValue)   // 'FRML'
        if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr,
           let reference {
            references.append(reference)
        }
    }

    /// Removes every registered shortcut (Settings › General › Global shortcuts off).
    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr {
                let value = id.id
                // Carbon delivers hot-key events on the main thread.
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(value) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
