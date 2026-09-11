import Carbon
import CoreMedia
import Foundation
#if os(macOS)
import AppKit
#endif

/// Global hotkeys that do not steal focus from Keynote or other full-screen apps.
final class HotkeyManager {
    enum Action: UInt32 {
        case pin = 1
        case shot = 2
        case pause = 3
    }

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private weak var controller: SessionController?
    private let captureFreeze: CaptureFreeze
    private let signature: OSType = 0x53547263

    init(controller: SessionController, captureFreeze: CaptureFreeze) {
        self.controller = controller
        self.captureFreeze = captureFreeze
    }

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event)
            },
            1,
            &spec,
            pointer,
            &handler
        )
        register(key: UInt32(kVK_Space), id: Action.pin.rawValue)
        register(key: UInt32(kVK_ANSI_S), id: Action.shot.rawValue)
        register(key: UInt32(kVK_ANSI_P), id: Action.pause.rawValue)
    }

    func unregister() {
        for ref in refs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        refs.removeAll()
        if let handler {
            RemoveEventHandler(handler)
        }
        handler = nil
    }

    private func register(key: UInt32, id: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            key,
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            refs.append(hotKeyRef)
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard hotKeyID.signature == signature, let action = Action(rawValue: hotKeyID.id) else {
            return noErr
        }
        let host = String(format: "%.3f", CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
        if action == .pause {
            AgentLog.event("hotkey_pause", ["host": host])
            // Freeze screen/audio/mic/metadata before the MainActor hop (C1).
            let froze = captureFreeze.freezeForPauseHotkey()
            Task { @MainActor [weak self] in
                self?.controller?.applyHotkeyPause(didFreezeWriters: froze)
            }
            return noErr
        }
        if action == .shot {
            AgentLog.event("hotkey_shot", ["host": host])
        } else if action == .pin {
            AgentLog.event("hotkey_pin", ["host": host])
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.perform(action)
        }
        return noErr
    }

    @MainActor
    private func perform(_ action: Action) {
        switch action {
        case .pin:
            controller?.pin()
        case .shot:
            controller?.openShot()
        case .pause:
            controller?.togglePause()
        }
    }
}
