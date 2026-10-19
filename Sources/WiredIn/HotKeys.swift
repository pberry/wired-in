import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey (no accessibility permission needed).
///
/// Fixed bindings, all with ⌃⌥⌘:
/// - 1…9: apply preset 1…9
/// - 0: turn the sign off
/// - W: bring the Wired In window forward
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let digitKeyCodes: [Int] = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                       kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    static let windowHotKeyID: UInt32 = 100

    var onPreset: ((Int) -> Void)?
    var onOff: (() -> Void)?
    var onShowWindow: (() -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            MainActor.assumeIsolated { HotKeys.shared.fire(number) }
            return noErr
        }, 1, &spec, nil, &handler)

        for (digit, keyCode) in Self.digitKeyCodes.enumerated() {
            add(keyCode: keyCode, id: UInt32(digit))
        }
        add(keyCode: kVK_ANSI_W, id: Self.windowHotKeyID)
    }

    private func add(keyCode: Int, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5749_524E), id: id)  // 'WIRN'
        if RegisterEventHotKey(UInt32(keyCode), Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
        }
    }

    private func fire(_ id: UInt32) {
        switch id {
        case 0: onOff?()
        case 1...9: onPreset?(Int(id) - 1)
        case Self.windowHotKeyID: onShowWindow?()
        default: break
        }
    }
}
