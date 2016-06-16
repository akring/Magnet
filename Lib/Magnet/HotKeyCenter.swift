//
//  HotKeyCenter.swift
//  Magnet
//
//  Created by 古林俊佑 on 2016/03/09.
//  Copyright © 2016年 Shunsuke Furubayashi. All rights reserved.
//

import Cocoa
import Carbon

public final class HotKeyCenter {

    // MARK: - Properties
    public static let sharedCenter = HotKeyCenter()
    private var hotKeys = [String: HotKey]()
    private var hotKeyMap = [NSNumber: HotKey]()
    private var hotKeyCount: UInt32 = 0

    private var tappedModifierKey = KeyCombo.ModifierKey.None
    private var multiModifiers = false

    // MARK: - Initialize
    init() {
        installEventHandler()
    }

}

// MARK: - Register & Unregister
public extension HotKeyCenter {
    public func register(hotKey: HotKey) -> Bool {
        if HotKeyCenter.sharedCenter.hotKey(hotKey.identifier) != nil { return false }
        if hotKeys.values.contains(hotKey) { unregister(hotKey) }

        if !hotKey.keyCombo.doubledModifiers {
            // Normal HotKey
            let hotKeyId = EventHotKeyID(signature: UTGetOSTypeFromString("Magnet"), id: hotKeyCount)
            var carbonHotKey: EventHotKeyRef = nil
            let error = RegisterEventHotKey(UInt32(hotKey.keyCombo.keyCode),
                                            UInt32(hotKey.keyCombo.modifiers),
                                            hotKeyId,
                                            GetEventDispatcherTarget(),
                                            0,
                                            &carbonHotKey)
            if error != 0 { return false }

            hotKey.hotKeyId = hotKeyId.id
            hotKey.hotKeyRef = carbonHotKey
        }

        let kId = NSNumber(unsignedInt: hotKeyCount)
        hotKeyMap[kId] = hotKey
        hotKeyCount += 1

        hotKeys[hotKey.identifier] = hotKey

        return true
    }
    
    public func unregister(hotKey: HotKey) {
        if !hotKeys.values.contains(hotKey) { return }

        if !hotKey.keyCombo.doubledModifiers {
            // Notmal HotKey
            guard let carbonHotKey = hotKey.hotKeyRef else { return }
            UnregisterEventHotKey(carbonHotKey)
        }

        hotKeys.removeValueForKey(hotKey.identifier)

        hotKey.hotKeyId = nil
        hotKey.hotKeyRef = nil

        hotKeyMap
            .filter { $1 == hotKey }
            .map { $0.0 }
            .forEach { hotKeyMap.removeValueForKey($0) }
    }

    public func unregisterHotKey(identifier: String) {
        guard let hotKey = hotKeys[identifier] else { return }
        unregister(hotKey)
    }

    public func unregisterAll() {
        hotKeys.forEach { unregister($1) }
    }
}

// MARK: - HotKeys
public extension HotKeyCenter {
    public func hotKey(identifier: String) -> HotKey? {
        return hotKeys[identifier]
    }
}

// MARK: - HotKey Events
private extension HotKeyCenter {
    private func installEventHandler() {
        // Press HotKey Event
        var pressedEventType = EventTypeSpec()
        pressedEventType.eventClass = OSType(kEventClassKeyboard)
        pressedEventType.eventKind = OSType(kEventHotKeyPressed)
        InstallEventHandler(GetEventDispatcherTarget(), { (_, inEvent, _) -> OSStatus in
            return HotKeyCenter.sharedCenter.sendCarbonEvent(inEvent)
        }, 1, &pressedEventType, nil, nil)

        // Press Modifiers Event
        let mask = CGEventMask((1 << CGEventType.FlagsChanged.rawValue))
        let event = CGEventTapCreate(.CGHIDEventTap,
                                     .HeadInsertEventTap,
                                     .Default,
                                     mask,
                                     { (_, _, event, _) in return HotKeyCenter.sharedCenter.sendModifiersEvent(event) },
                                     nil)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, event!, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes)
        CGEventTapEnable(event!, true)
        CFRunLoopRun()
    }

    private func sendCarbonEvent(event: EventRef) -> OSStatus {
        assert(Int(GetEventClass(event)) == kEventClassKeyboard, "Unknown event class")

        var hotKeyId = EventHotKeyID()
        let error = GetEventParameter(event,
                                      EventParamName(kEventParamDirectObject),
                                      EventParamName(typeEventHotKeyID),
                                      nil,
                                      sizeof(EventHotKeyID),
                                      nil,
                                      &hotKeyId)

        if error != 0 { return error }

        assert(hotKeyId.signature == UTGetOSTypeFromString("Magnet"), "Invalid hot key id")

        let kId = NSNumber(unsignedInt: hotKeyId.id)
        let hotKey = hotKeyMap[kId]

        switch GetEventKind(event) {
        case EventParamName(kEventHotKeyPressed):
            hotKeyDown(hotKey)
        default:
            assert(false, "Unknown event kind")
        }

        return noErr
    }

    private func hotKeyDown(hotKey: HotKey?) {
        guard let hotKey = hotKey else { return }
        hotKey.invoke()
    }
}

// MARK: - Double Tap Modifier Event
private extension HotKeyCenter {
    private func sendModifiersEvent(event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = CGEventGetFlags(event)

        let commandTapped = flags.rawValue & CGEventFlags.MaskCommand.rawValue == CGEventFlags.MaskCommand.rawValue
        let shiftTapped = flags.rawValue & CGEventFlags.MaskShift.rawValue == CGEventFlags.MaskShift.rawValue
        let controlTapped = flags.rawValue & CGEventFlags.MaskControl.rawValue == CGEventFlags.MaskControl.rawValue
        let altTapped = flags.rawValue & CGEventFlags.MaskAlternate.rawValue == CGEventFlags.MaskAlternate.rawValue

        // Only one modifier key
        let totalHash = commandTapped.hashValue + altTapped.hashValue + shiftTapped.hashValue + controlTapped.hashValue
        if totalHash == 0 { return Unmanaged.passRetained(event) }
        if totalHash > 1 {
            multiModifiers = true
            return Unmanaged.passRetained(event)
        }
        if multiModifiers {
            multiModifiers = false
            return Unmanaged.passRetained(event)
        }

        switch tappedModifierKey {
        case .Command where commandTapped,
             .Shift where shiftTapped,
             .Control where controlTapped,
             .Alt where altTapped:
            doubleTappedHotKey(tappedModifierKey.modifier)
            tappedModifierKey = .None
        default:
            if commandTapped {
                tappedModifierKey = .Command
            } else if shiftTapped {
                tappedModifierKey = .Shift
            } else if controlTapped {
                tappedModifierKey = .Control
            } else if altTapped {
                tappedModifierKey = .Alt
            } else {
                tappedModifierKey = .None
            }
        }

        // Clean Flag
        let delay = 0.3 * Double(NSEC_PER_SEC)
        let time  = dispatch_time(DISPATCH_TIME_NOW, Int64(delay))
        dispatch_after(time, dispatch_get_main_queue(), { [unowned self] in
            self.tappedModifierKey = .None
        })

        return Unmanaged.passRetained(event)
    }

    private func doubleTappedHotKey(key: Int) {
        hotKeys.map { $0.1 }
            .filter { $0.keyCombo.doubledModifiers && $0.keyCombo.modifiers == key }
            .forEach { $0.invoke() }
    }
}
