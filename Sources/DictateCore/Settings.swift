import Foundation

public struct ProviderPreset: Equatable, Sendable, Identifiable {
    public let id: String
    /// English name; shown through `L` so "Custom" is translated.
    public let nameKey: String
    public var name: String { L(nameKey) }
    public let baseURL: String
    public let defaultModel: String

    public static let openAI = ProviderPreset(
        id: "openai", nameKey: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-transcribe")
    public static let openRouter = ProviderPreset(
        id: "openrouter", nameKey: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-transcribe")
    public static let custom = ProviderPreset(id: "custom", nameKey: "Custom", baseURL: "", defaultModel: "")

    public static let all: [ProviderPreset] = [.openAI, .openRouter, .custom]

    public static func byID(_ id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? .openAI
    }
}

/// Persisted user settings. The API key is not here; it lives in the Keychain.
public struct DictateSettings: Equatable, Sendable {
    public var providerID: String = ProviderPreset.openAI.id
    public var baseURL: String = ProviderPreset.openAI.baseURL
    public var model: String = ProviderPreset.openAI.defaultModel
    /// ISO-639-1 code, or empty for auto-detect.
    public var language: String = ""
    /// Context hint sent with the audio. A fresh install gets `defaultPrompt(for:)`.
    public var prompt: String = ""
    public var mode: RecordingMode = .hold
    public var triggerKind: TriggerKind = .modifier
    /// Used when `triggerKind == .modifier`.
    public var trigger: TriggerKey = .rightCommand
    /// Used when `triggerKind == .combo`.
    public var combo: KeyCombo? = nil
    public var convertToTraditional: Bool = true
    public var playSounds: Bool = true
    public var uiLanguage: AppLanguage = .system

    public init() {}

    /// Nudges the model toward Traditional Chinese for Chinese users; English needs no hint.
    public static func defaultPrompt(for languageCode: String) -> String {
        languageCode == "zh-Hant" ? "以下是繁體中文的口述，可能夾雜英文詞彙。" : ""
    }

    /// The trigger in effect. A combo kind without a recorded combo falls back to the modifier key.
    public var activeTrigger: Trigger {
        if triggerKind == .combo, let combo, combo.isValid { return .combo(combo) }
        return .modifier(trigger)
    }

    /// Keychain account for the key: one key per API host, so switching providers keeps both.
    public var keychainAccount: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "default"
    }

    enum Key {
        static let provider = "provider", baseURL = "baseURL", model = "model", language = "language"
        static let prompt = "prompt", mode = "mode", trigger = "trigger", convert = "convertToTraditional"
        static let sounds = "playSounds", triggerKind = "triggerKind", uiLanguage = "uiLanguage"
        static let comboKeyCode = "comboKeyCode", comboModifiers = "comboModifiers", comboLabel = "comboLabel"
    }

    public static func load(from defaults: UserDefaults) -> DictateSettings {
        var s = DictateSettings()
        if let v = defaults.string(forKey: Key.provider) { s.providerID = v }
        if let v = defaults.string(forKey: Key.baseURL) { s.baseURL = v }
        if let v = defaults.string(forKey: Key.model) { s.model = v }
        if let v = defaults.string(forKey: Key.language) { s.language = v }
        if let v = defaults.string(forKey: Key.mode).flatMap(RecordingMode.init(rawValue:)) { s.mode = v }
        if let v = defaults.string(forKey: Key.trigger).flatMap(TriggerKey.init(rawValue:)) { s.trigger = v }
        if defaults.object(forKey: Key.convert) != nil { s.convertToTraditional = defaults.bool(forKey: Key.convert) }
        if defaults.object(forKey: Key.sounds) != nil { s.playSounds = defaults.bool(forKey: Key.sounds) }
        if let v = defaults.string(forKey: Key.uiLanguage).flatMap(AppLanguage.init(rawValue:)) { s.uiLanguage = v }
        s.prompt = defaults.string(forKey: Key.prompt) ?? defaultPrompt(for: Localizer.resolve(s.uiLanguage))
        if let v = defaults.string(forKey: Key.triggerKind).flatMap(TriggerKind.init(rawValue:)) { s.triggerKind = v }
        if defaults.object(forKey: Key.comboKeyCode) != nil, let label = defaults.string(forKey: Key.comboLabel) {
            s.combo = KeyCombo(
                keyCode: UInt16(clamping: defaults.integer(forKey: Key.comboKeyCode)),
                modifiers: ComboModifiers(rawValue: UInt(clamping: defaults.integer(forKey: Key.comboModifiers))),
                keyLabel: label)
        }
        return s
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(providerID, forKey: Key.provider)
        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(model, forKey: Key.model)
        defaults.set(language, forKey: Key.language)
        defaults.set(prompt, forKey: Key.prompt)
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(trigger.rawValue, forKey: Key.trigger)
        defaults.set(convertToTraditional, forKey: Key.convert)
        defaults.set(playSounds, forKey: Key.sounds)
        defaults.set(triggerKind.rawValue, forKey: Key.triggerKind)
        defaults.set(uiLanguage.rawValue, forKey: Key.uiLanguage)
        if let combo {
            defaults.set(Int(combo.keyCode), forKey: Key.comboKeyCode)
            defaults.set(Int(combo.modifiers.rawValue), forKey: Key.comboModifiers)
            defaults.set(combo.keyLabel, forKey: Key.comboLabel)
        } else {
            for key in [Key.comboKeyCode, Key.comboModifiers, Key.comboLabel] { defaults.removeObject(forKey: key) }
        }
    }
}
