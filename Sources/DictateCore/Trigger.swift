import Foundation

/// Modifier keys of a key combination. Raw values match NSEvent.ModifierFlags.
public struct ComboModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift = ComboModifiers(rawValue: 1 << 17)
    public static let control = ComboModifiers(rawValue: 1 << 18)
    public static let option = ComboModifiers(rawValue: 1 << 19)
    public static let command = ComboModifiers(rawValue: 1 << 20)
    public static let all: ComboModifiers = [.shift, .control, .option, .command]

    /// Keep only the four modifiers, from raw NSEvent flags.
    public init(eventFlags: UInt) {
        self.init(rawValue: eventFlags & ComboModifiers.all.rawValue)
    }

    /// Carbon `RegisterEventHotKey` modifier bits.
    public var carbon: UInt32 {
        var out: UInt32 = 0
        if contains(.command) { out |= 0x0100 } // cmdKey
        if contains(.shift) { out |= 0x0200 } // shiftKey
        if contains(.option) { out |= 0x0800 } // optionKey
        if contains(.control) { out |= 0x1000 } // controlKey
        return out
    }

    /// Apple's order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A recorded key combination such as ⌥Space or ⌃⇧D.
public struct KeyCombo: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ComboModifiers
    /// Key name captured at record time ("Space", "D", "F5").
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: ComboModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var label: String { modifiers.symbols + keyLabel }

    /// F1–F20 by virtual key code.
    public static let functionKeyCodes: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Names for keys whose characters are not printable.
    public static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// Label for a key: function/named keys from the tables, otherwise the typed character.
    public static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        if let name = functionKeyCodes[keyCode] ?? namedKeys[keyCode] { return name }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.isEmpty ? "Key \(keyCode)" : c
    }

    /// A plain letter would swallow normal typing, so a combo needs a modifier,
    /// unless it is a function key. Esc is reserved for cancel.
    public var isValid: Bool {
        guard keyCode != 53 else { return false }
        return !modifiers.isEmpty || Self.functionKeyCodes[keyCode] != nil
    }
}

public enum TriggerKind: String, CaseIterable, Sendable {
    case modifier
    case combo
}

/// What starts and stops recording.
public enum Trigger: Equatable, Sendable {
    case modifier(TriggerKey)
    case combo(KeyCombo)

    public var label: String {
        switch self {
        case .modifier(let key): key.label
        case .combo(let combo): combo.label
        }
    }
}
