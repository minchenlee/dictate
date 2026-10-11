import Foundation

/// How the trigger key controls recording.
public enum RecordingMode: String, CaseIterable, Sendable {
    /// Hold the key while speaking; release to transcribe.
    case hold
    /// Tap once to start, tap again to transcribe.
    case toggle
}

/// A single modifier key that triggers recording on its own.
/// `deviceMask` is the device-dependent bit in NSEvent/CGEvent modifier flags,
/// which tells the right-hand key apart from the left-hand one.
public enum TriggerKey: String, CaseIterable, Sendable {
    case rightCommand, rightOption, rightControl, rightShift

    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        case .rightShift: 60
        }
    }

    public var deviceMask: UInt {
        switch self {
        case .rightCommand: 0x0000_0010
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        case .rightShift: 0x0000_0004
        }
    }

    public var label: String {
        switch self {
        case .rightCommand: "右 ⌘"
        case .rightOption: "右 ⌥"
        case .rightControl: "右 ⌃"
        case .rightShift: "右 ⇧"
        }
    }
}

public enum HotkeyEvent: Equatable, Sendable {
    case triggerDown(TimeInterval)
    case triggerUp(TimeInterval)
    /// Any other key or modifier changed. While the trigger is held this means
    /// the user is typing a shortcut (for example ⌘C), not dictating.
    case otherKey
    case escape
}

public enum HotkeyAction: Equatable, Sendable {
    case none
    case start
    case stop
    case cancel
}

/// Pure state machine for a single-modifier trigger key. No AppKit, so it is unit-testable.
public struct HotkeyMachine: Sendable {
    public var mode: RecordingMode
    /// Hold mode: a press shorter than this is discarded as accidental.
    public var minHold: TimeInterval = 0.3
    /// Toggle mode: a press longer than this is not a tap.
    public var maxTap: TimeInterval = 0.4

    enum State: Equatable {
        case idle
        /// Hold mode: trigger down, recording.
        case holding(since: TimeInterval)
        /// Toggle mode: trigger down while idle; a quick release starts recording.
        case armedStart(since: TimeInterval)
        /// Toggle mode: recording, trigger up.
        case recording
        /// Toggle mode: trigger down while recording; a quick release stops.
        case armedStop(since: TimeInterval)
        /// Toggle mode: trigger was used as a shortcut modifier while recording.
        case recordingSuppressed
        /// Trigger was used as a shortcut modifier; ignore until it is released.
        case suppressed
    }

    private(set) var state: State = .idle

    public init(mode: RecordingMode) {
        self.mode = mode
    }

    public var isRecording: Bool {
        switch state {
        case .holding, .recording, .armedStop, .recordingSuppressed: true
        default: false
        }
    }

    /// Drop back to idle, for example after the app stopped recording on its own.
    public mutating func reset() {
        state = .idle
    }

    public mutating func handle(_ event: HotkeyEvent) -> HotkeyAction {
        switch mode {
        case .hold: handleHold(event)
        case .toggle: handleToggle(event)
        }
    }

    private mutating func handleHold(_ event: HotkeyEvent) -> HotkeyAction {
        switch (state, event) {
        case (.idle, .triggerDown(let t)):
            state = .holding(since: t)
            return .start
        case (.holding, .otherKey), (.holding, .escape):
            state = .suppressed
            return .cancel
        case (.holding(let since), .triggerUp(let t)):
            state = .idle
            return t - since < minHold ? .cancel : .stop
        case (.suppressed, .triggerUp):
            state = .idle
            return .none
        default:
            return .none
        }
    }

    private mutating func handleToggle(_ event: HotkeyEvent) -> HotkeyAction {
        switch (state, event) {
        case (.idle, .triggerDown(let t)):
            state = .armedStart(since: t)
            return .none
        case (.armedStart, .otherKey):
            state = .suppressed
            return .none
        case (.armedStart(let since), .triggerUp(let t)):
            if t - since <= maxTap {
                state = .recording
                return .start
            }
            state = .idle
            return .none
        case (.recording, .triggerDown(let t)):
            state = .armedStop(since: t)
            return .none
        case (.recording, .escape), (.armedStop, .escape), (.recordingSuppressed, .escape):
            state = .idle
            return .cancel
        case (.armedStop, .otherKey):
            state = .recordingSuppressed
            return .none
        case (.armedStop(let since), .triggerUp(let t)):
            if t - since <= maxTap {
                state = .idle
                return .stop
            }
            state = .recording
            return .none
        case (.recordingSuppressed, .triggerUp):
            state = .recording
            return .none
        case (.suppressed, .triggerUp):
            state = .idle
            return .none
        default:
            return .none
        }
    }
}
