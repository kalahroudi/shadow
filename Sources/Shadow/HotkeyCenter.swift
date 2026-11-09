// SPDX-License-Identifier: Apache-2.0

import Carbon.HIToolbox
import ShadowKit

/// Global shortcuts through Carbon `RegisterEventHotKey`, which needs no permission prompt (R18).
/// Registered for as long as the app runs, so click-through can always be turned off (R15).
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private static let signature: OSType = 0x53484457   // 'SHDW'

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onAction: (@MainActor (HotkeyAction) -> Void)?
    private var lastMap: HotkeyMap?
    private var copyEnabled = false

    /// ⌘⇧C is claimed only while an answer is on screen, so it never steals the shortcut system-wide (R18).
    func setCopyAnswerEnabled(_ on: Bool) {
        guard on != copyEnabled else { return }
        copyEnabled = on
        guard let lastMap else { return }
        let failed = register(lastMap)
        if on { AppModel.shared.reportHotkeyConflicts(failed.keys) }
    }

    /// Replaces every registration. Returns one friendly message per action macOS refused (the shortcut is taken elsewhere).
    @discardableResult
    func register(_ map: HotkeyMap) -> [HotkeyAction: UserFacingError] {
        installHandlerIfNeeded()
        lastMap = map
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        var failed: [HotkeyAction: UserFacingError] = [:]
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let key = map[action], action != .copyAnswer || copyEnabled else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, Self.carbonModifiers(key.modifiers),
                                             EventHotKeyID(signature: Self.signature, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else {
                AppLog.info("hotkey \(action.rawValue) not registered, status \(status)")
                failed[action] = UserFacingError("Another app already uses that shortcut for “\(action.label)”.")
            }
        }
        return failed
    }

    /// Drops every registration and the event handler.
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    static func carbonModifiers(_ m: Hotkey.Modifiers) -> UInt32 {
        var out: UInt32 = 0
        if m.contains(.command) { out |= UInt32(cmdKey) }
        if m.contains(.shift) { out |= UInt32(shiftKey) }
        if m.contains(.option) { out |= UInt32(optionKey) }
        if m.contains(.control) { out |= UInt32(controlKey) }
        return out
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(0x686B6964 /* typeEventHotKey, "hkid": a C macro Swift cannot import */), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let index = Int(id.id)
            Task { @MainActor in HotkeyCenter.shared.fire(index) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ index: Int) {
        guard HotkeyAction.allCases.indices.contains(index) else { return }
        onAction?(HotkeyAction.allCases[index])
    }
}
