import Carbon.HIToolbox
import Foundation

final class HotKeyManager {
    static let signature = OSType(0x53434C42) // 'SCLB'

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    init(identifier: UInt32, action: @escaping () -> Void) {
        self.identifier = identifier
        self.action = action
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(_ choice: HotKeyChoice) -> Bool {
        unregister()

        let eventHotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: identifier
        )

        let status = RegisterEventHotKey(
            choice.keyCode,
            choice.modifiers,
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog(
                "ScreenshotLab: could not register hotkey %@: %d",
                choice.name,
                status
            )
        }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotKeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()
            guard hotKeyID.signature == HotKeyManager.signature,
                  hotKeyID.id == manager.identifier else {
                // Another manager owns this hotkey; let its handler run.
                return OSStatus(eventNotHandledErr)
            }

            DispatchQueue.main.async {
                manager.action()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}
