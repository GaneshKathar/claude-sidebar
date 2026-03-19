import Carbon
import Foundation
import os.log

private let logger = OSLog(subsystem: "com.claudesidebar", category: "KeyboardShortcutManager")

// MARK: - Keyboard Shortcut Manager (extracted from SidebarController — SRP)

class KeyboardShortcutManager {
    private var hotkeyRefs: [EventHotKeyRef?] = []

    var onToggleSidebar: (() -> Void)?
    var onFocusRepo: ((Int) -> Void)?
    var onActiveOnly: (() -> Void)?     // Opt+Shift+- : show only active repo tabs
    var onShowAll: (() -> Void)?        // Opt+Shift++ : show default (all tabs)

    func setup() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, refcon) -> OSStatus in
                guard let refcon = refcon else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(refcon).takeUnretainedValue()

                var hotkeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

                let repoNum = Int(hotkeyID.id)
                DispatchQueue.main.async {
                    switch repoNum {
                    case 100: manager.onToggleSidebar?()
                    case 101: manager.onActiveOnly?()
                    case 102: manager.onShowAll?()
                    default:  manager.onFocusRepo?(repoNum)
                    }
                }
                return noErr
            },
            1, &eventType, refcon, nil
        )

        // Carbon key codes for 1-9 (top row)
        let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let modifiers: UInt32 = UInt32(optionKey | shiftKey)

        for (index, keyCode) in keyCodes.enumerated() {
            let repoNum = index + 1
            let hotkeyID = EventHotKeyID(signature: OSType(0x434C5349), id: UInt32(repoNum))
            var hotkeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                                             GetApplicationEventTarget(), 0, &hotkeyRef)
            if status == noErr {
                hotkeyRefs.append(hotkeyRef)
            } else {
                hotkeyRefs.append(nil)
            }
        }

        // Register Opt+Shift+0 as sidebar toggle (key code 29 = "0", ID 100)
        let toggleHotkeyID = EventHotKeyID(signature: OSType(0x434C5349), id: UInt32(100))
        var toggleHotkeyRef: EventHotKeyRef?
        let toggleStatus = RegisterEventHotKey(29, modifiers, toggleHotkeyID,
                                               GetApplicationEventTarget(), 0, &toggleHotkeyRef)
        if toggleStatus == noErr {
            hotkeyRefs.append(toggleHotkeyRef)
        } else {
            hotkeyRefs.append(nil)
        }

        // Register Opt+Shift+- as "active only" filter (key code 27 = "-", ID 101)
        let minusHotkeyID = EventHotKeyID(signature: OSType(0x434C5349), id: UInt32(101))
        var minusHotkeyRef: EventHotKeyRef?
        let minusStatus = RegisterEventHotKey(27, modifiers, minusHotkeyID,
                                               GetApplicationEventTarget(), 0, &minusHotkeyRef)
        if minusStatus == noErr {
            hotkeyRefs.append(minusHotkeyRef)
        } else {
            hotkeyRefs.append(nil)
        }

        // Register Opt+Shift+= ("+") as "show all" (key code 24 = "=", ID 102)
        let plusHotkeyID = EventHotKeyID(signature: OSType(0x434C5349), id: UInt32(102))
        var plusHotkeyRef: EventHotKeyRef?
        let plusStatus = RegisterEventHotKey(24, modifiers, plusHotkeyID,
                                              GetApplicationEventTarget(), 0, &plusHotkeyRef)
        if plusStatus == noErr {
            hotkeyRefs.append(plusHotkeyRef)
        } else {
            hotkeyRefs.append(nil)
        }

        let registered = hotkeyRefs.compactMap({ $0 }).count
        try? "Registered \(registered)/12 hotkeys\n".write(toFile: "/tmp/claude-sidebar-hotkey.log", atomically: true, encoding: .utf8)
    }

    deinit {
        for ref in hotkeyRefs {
            if let ref = ref { UnregisterEventHotKey(ref) }
        }
    }
}
