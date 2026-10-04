import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Global ⌃⌥Space hotkey (no permissions needed) via Carbon.
final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: GlobalHotkey] = [:]
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = id
        GlobalHotkey.instances[id] = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let inst = GlobalHotkey.instances[hk.id] {
                DispatchQueue.main.async { inst.action() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        let hkID = EventHotKeyID(signature: OSType(0x524C4159), id: id) // 'RLAY'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        GlobalHotkey.instances.removeValue(forKey: id)
    }
}

/// Detects a double tap of the Option key anywhere (needs Accessibility permission for other apps).
final class DoubleOptionTap {
    private var globalFlags: Any?
    private var localFlags: Any?
    private var globalKeys: Any?
    private var localKeys: Any?
    private var optionDownAt: TimeInterval?
    private var lastTapAt: TimeInterval = 0
    private var dirty = false
    private let action: () -> Void

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "doubleOptionEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "doubleOptionEnabled") }
    }

    init(action: @escaping () -> Void) {
        self.action = action
        globalFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e) }
        localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e); return e }
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in self?.dirty = true }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.dirty = true; return e }
    }

    private func flags(_ e: NSEvent) {
        guard enabled else { return }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isOptionKey = e.keyCode == 58 || e.keyCode == 61
        let now = e.timestamp
        if isOptionKey && f.contains(.option) && f.subtracting([.option, .capsLock, .function, .numericPad]).isEmpty {
            optionDownAt = now
            dirty = false
            return
        }
        if isOptionKey && !f.contains(.option), let down = optionDownAt {
            optionDownAt = nil
            guard !dirty, now - down < 0.35 else { lastTapAt = 0; return }
            if now - lastTapAt < 0.45 {
                lastTapAt = 0
                DispatchQueue.main.async { self.action() }
            } else {
                lastTapAt = now
            }
            return
        }
        // Any other modifier activity breaks the sequence.
        optionDownAt = nil
        lastTapAt = 0
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
