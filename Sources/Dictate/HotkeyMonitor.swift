import AppKit
import DictateCore

/// Watches the trigger modifier globally and feeds `HotkeyMachine`.
/// Global key monitors only receive events when the app is trusted for Accessibility.
final class HotkeyMonitor {
    var trigger: TriggerKey
    var onEvent: (HotkeyEvent) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var triggerIsDown = false

    init(trigger: TriggerKey, onEvent: @escaping (HotkeyEvent) -> Void) {
        self.trigger = trigger
        self.onEvent = onEvent
    }

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
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        triggerIsDown = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            onEvent(event.keyCode == 53 ? .escape : .otherKey)
        case .flagsChanged:
            if event.keyCode == trigger.keyCode {
                let down = event.modifierFlags.rawValue & trigger.deviceMask != 0
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
}
