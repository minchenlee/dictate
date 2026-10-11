import AppKit
import AVFoundation
import Combine
import DictateCore
import ServiceManagement
import SwiftUI

/// Shared state for all settings tabs. Changes save automatically, like native macOS settings.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var draft: DictateSettings
    @Published var apiKey: String
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    let openCCPath: String?

    /// True while the combo recorder waits for a key press.
    @Published var isCapturing = false
    @Published var captureHint: String?

    var onChange: (DictateSettings) -> Void = { _ in }
    /// Lets the app pause its own hotkey while the recorder listens.
    var onCaptureChange: (Bool) -> Void = { _ in }
    private var captureMonitor: Any?
    private var bag: Set<AnyCancellable> = []
    /// Set while switching provider, so the key of the old host is not written to the new one.
    private var switchingProvider = false

    init(settings: DictateSettings) {
        draft = settings
        apiKey = Keychain.read(account: settings.keychainAccount) ?? ""
        openCCPath = OpenCC.find()?.executable.path
        refreshSystemState()

        $draft.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] new in
                new.save(to: .standard)
                self?.onChange(new)
            }
            .store(in: &bag)
        $apiKey.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] key in
                guard let self, !self.switchingProvider else { return }
                Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: self.draft.keychainAccount)
            }
            .store(in: &bag)
    }

    func refreshSystemState() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    func selectProvider(_ id: String) {
        // Flush a pending key edit to the old host before switching.
        Keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: draft.keychainAccount)
        switchingProvider = true
        let preset = ProviderPreset.byID(id)
        draft.providerID = id
        if id != ProviderPreset.custom.id {
            draft.baseURL = preset.baseURL
            draft.model = preset.defaultModel
        }
        apiKey = Keychain.read(account: draft.keychainAccount) ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.switchingProvider = false }
    }

    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureHint = nil
        onCaptureChange(true)
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, ComboModifiers(eventFlags: event.modifierFlags.rawValue).isEmpty {
                self.stopCapture() // Esc cancels
                return nil
            }
            let combo = KeyCombo(
                keyCode: event.keyCode,
                modifiers: ComboModifiers(eventFlags: event.modifierFlags.rawValue),
                keyLabel: KeyCombo.keyLabel(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
            guard combo.isValid else {
                self.captureHint = L("Add ⌘, ⌥, ⌃ or ⇧ (not needed for F1–F20)")
                return nil
            }
            self.draft.combo = combo
            self.draft.triggerKind = .combo
            self.stopCapture()
            return nil
        }
    }

    func stopCapture() {
        if let m = captureMonitor { NSEvent.removeMonitor(m) }
        captureMonitor = nil
        guard isCapturing else { return }
        isCapturing = false
        onCaptureChange(false)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Dictate: login item \(on ? "register" : "unregister") failed: \(error)")
        }
        refreshSystemState()
    }
}

// MARK: Window

/// Native settings window: toolbar tabs, each tab a SwiftUI form; the window resizes per tab.
@MainActor
final class SettingsWindowController: NSWindowController {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            // NSTabViewController shows the selected child's title as the window title.
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add(L("General"), "gearshape", GeneralTab(model: model))
        add(L("Transcription"), "waveform", ServiceTab(model: model))
        add(L("Shortcut"), "keyboard", HotkeyTab(model: model))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshSystemState() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.refreshSystemState()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: Tabs

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: $model.draft.uiLanguage) {
                    Text(L("System")).tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "繁體中文").tag(AppLanguage.traditionalChinese)
                }
                Toggle(L("Open at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginNeedsApproval {
                    LabeledContent(L("Allow it in System Settings")) {
                        Button(L("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle(L("Play sounds when recording starts and ends"), isOn: $model.draft.playSounds)
            }
            Section {
                Toggle(L("Convert Simplified to Traditional Chinese (Taiwan)"), isOn: $model.draft.convertToTraditional)
            } footer: {
                Text(model.openCCPath.map { L("Using %@", $0) } ?? L("opencc not found, so text is left as is. Install: brew install opencc"))
            }
            Section(L("Permissions")) {
                PermissionRow(title: L("Microphone"), detail: L("Records your voice"), granted: model.micGranted, pane: "Privacy_Microphone")
                PermissionRow(title: L("Accessibility"), detail: L("Detects the trigger key and pastes text"), granted: model.axGranted, pane: "Privacy_Accessibility")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

private struct ServiceTab: View {
    @ObservedObject var model: SettingsModel
    private var languages: [(String, String)] { [("", L("Auto-detect")), ("zh", L("Chinese")), ("en", L("English")), ("ja", L("Japanese"))] }

    var body: some View {
        Form {
            Section {
                Picker(L("Service"), selection: Binding(get: { model.draft.providerID }, set: { model.selectProvider($0) })) {
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
                }
                TextField("API base URL", text: $model.draft.baseURL, prompt: Text("https://…/v1"))
                    .disabled(model.draft.providerID != ProviderPreset.custom.id)
                SecureField("API key", text: $model.apiKey, prompt: Text("sk-…"))
            } footer: {
                Text(L("API keys are stored in the Keychain, one per service."))
            }
            Section {
                TextField(L("Model"), text: $model.draft.model)
                Picker(L("Spoken language"), selection: $model.draft.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField(L("Prompt"), text: $model.draft.prompt, prompt: Text(L("Optional")), axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text(L("For mixed languages, Auto-detect is usually more accurate than a fixed language."))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

private struct HotkeyTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(L("Trigger"), selection: $model.draft.triggerKind) {
                    Text(L("Single modifier")).tag(TriggerKind.modifier)
                    Text(L("Key combo")).tag(TriggerKind.combo)
                }
                .pickerStyle(.segmented)

                if model.draft.triggerKind == .modifier {
                    Picker(L("Key"), selection: $model.draft.trigger) {
                        ForEach(TriggerKey.allCases.filter { !$0.isBusy }, id: \.self) { Text($0.label).tag($0) }
                        Divider()
                        ForEach(TriggerKey.allCases.filter(\.isBusy), id: \.self) { Text($0.label).tag($0) }
                    }
                } else {
                    LabeledContent(L("Key combo")) {
                        ComboRecorder(model: model)
                    }
                }

                Picker(L("Mode"), selection: $model.draft.mode) {
                    Text(L("Hold to talk")).tag(RecordingMode.hold)
                    Text(L("Press to toggle")).tag(RecordingMode.toggle)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.draft.mode == .hold
                         ? L("Hold %@ and speak. Release to send.", model.draft.activeTrigger.label)
                         : L("Press %@ to start, press again to send.", model.draft.activeTrigger.label))
                    Text(footnote)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onDisappear { model.stopCapture() }
    }

    private var footnote: String {
        if model.draft.triggerKind == .combo {
            return model.draft.combo == nil
                ? L("No combo recorded yet, so %@ is used. Press Esc to cancel a recording.", model.draft.trigger.label)
                : L("Press Esc to cancel a recording. If another app uses the combo, nothing happens; choose another.")
        }
        switch model.draft.trigger {
        case .fn: return L("Fn / 🌐 works only on Apple keyboards. Set System Settings › Keyboard › Press 🌐 key to Do Nothing.")
        case let key where key.isBusy: return L("Left-side modifiers are common in shortcuts, so accidental presses are likely. Pressed with another key, they do not record. Press Esc to cancel a recording.")
        default: return L("Press Esc to cancel a recording. The trigger pressed with another key (such as ⌘C) does not record.")
        }
    }
}

private struct ComboRecorder: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    model.isCapturing ? model.stopCapture() : model.startCapture()
                } label: {
                    Text(model.isCapturing ? L("Press a combo…") : (model.draft.combo?.label ?? L("Click to Record")))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .tint(model.isCapturing ? .accentColor : nil)
                if model.draft.combo != nil, !model.isCapturing {
                    Button {
                        model.draft.combo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Clear combo"))
                }
            }
            if let hint = model.captureHint, model.isCapturing {
                Text(hint).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let pane: String

    var body: some View {
        LabeledContent {
            if granted {
                Label(L("Allowed"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button(L("Open System Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
