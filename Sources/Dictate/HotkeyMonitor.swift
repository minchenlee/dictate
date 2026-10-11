import AppKit
import Carbon.HIToolbox
import DictateCore

/// Turns the configured trigger into `HotkeyEvent`s for `HotkeyMachine`.
/// - Modifier key: watched through NSEvent monitors (global ones need Accessibility).
/// - Key combo: a Carbon global hotkey, which reports both press and release and
///   swallows the keystroke so it never reaches the focused field.
final class HotkeyMonitor {
    var trigger: Trigger
    var onEvent: (HotkeyEvent) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var triggerIsDown = false
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(trigger: Trigger, onEvent: @escaping (HotkeyEvent) -> Void) {
        self.trigger = trigger
        self.onEvent = onEvent
    }

    deinit { stop() }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        if case .combo(let combo) = trigger { registerHotKey(combo) }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        triggerIsDown = false
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        if let ref = handlerRef { RemoveEventHandler(ref) }
        handlerRef = nil
    }

    private func handle(_ event: NSEvent) {
        switch trigger {
        case .modifier(let key):
            handleModifier(event, key: key)
        case .combo:
            // The combo itself arrives through Carbon. Only Esc matters here; modifier
            // changes are expected while a combo is held (releasing ⌥ before Space).
            if event.type == .keyDown, event.keyCode == 53 { onEvent(.escape) }
        }
    }

    private func handleModifier(_ event: NSEvent, key: TriggerKey) {
        switch event.type {
        case .keyDown:
            onEvent(event.keyCode == 53 ? .escape : .otherKey)
        case .flagsChanged:
            if event.keyCode == key.keyCode {
                let down = event.modifierFlags.rawValue & key.deviceMask != 0
                guard down != triggerIsDown else { return }
                triggerIsDown = down
                onEvent(down ? .triggerDown(event.timestamp) : .triggerUp(event.timestamp))
            } else {
                onEvent(.otherKey)
            }
        default:
            break
        }
    }

    // MARK: Carbon hotkey

    private func registerHotKey(_ combo: KeyCombo) {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let time = GetEventTime(event)
            DispatchQueue.main.async { monitor.comboChanged(pressed: pressed, time: time) }
            return noErr
        }, types.count, &types, context, &handlerRef)
        guard status == noErr else {
            NSLog("Dictate: InstallEventHandler failed \(status)")
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4454_4354), id: 1) // 'DTCT'
        let reg = RegisterEventHotKey(UInt32(combo.keyCode), combo.modifiers.carbon, id,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        if reg != noErr {
            hotKeyRef = nil
            NSLog("Dictate: RegisterEventHotKey failed \(reg) for \(combo.label)")
        }
    }

    private func comboChanged(pressed: Bool, time: TimeInterval) {
        guard pressed != triggerIsDown else { return }
        triggerIsDown = pressed
        onEvent(pressed ? .triggerDown(time) : .triggerUp(time))
    }

    /// False when another app already owns the combo.
    var isComboRegistered: Bool { hotKeyRef != nil }
}
