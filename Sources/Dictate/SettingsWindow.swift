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
                self.captureHint = "需要搭配 ⌘、⌥、⌃ 或 ⇧（F1–F20 除外）"
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
        add("一般", "gearshape", GeneralTab(model: model))
        add("轉錄", "waveform", ServiceTab(model: model))
        add("快捷鍵", "keyboard", HotkeyTab(model: model))

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
                Toggle("登入時自動開啟", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginNeedsApproval {
                    LabeledContent("需要在系統設定中允許") {
                        Button("開啟登入項目") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("開始與結束錄音時播放提示音", isOn: $model.draft.playSounds)
            }
            Section {
                Toggle("簡體轉繁體（台灣用語）", isOn: $model.draft.convertToTraditional)
            } footer: {
                Text(model.openCCPath.map { "使用 \($0)" } ?? "找不到 opencc，會輸出原文。安裝：brew install opencc")
            }
            Section("權限") {
                PermissionRow(title: "麥克風", detail: "錄下你的語音", granted: model.micGranted, pane: "Privacy_Microphone")
                PermissionRow(title: "輔助使用", detail: "偵測觸發鍵並貼上文字", granted: model.axGranted, pane: "Privacy_Accessibility")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

private struct ServiceTab: View {
    @ObservedObject var model: SettingsModel
    private let languages: [(String, String)] = [("", "自動偵測"), ("zh", "中文"), ("en", "English"), ("ja", "日本語")]

    var body: some View {
        Form {
            Section {
                Picker("服務", selection: Binding(get: { model.draft.providerID }, set: { model.selectProvider($0) })) {
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
                }
                TextField("API base URL", text: $model.draft.baseURL, prompt: Text("https://…/v1"))
                    .disabled(model.draft.providerID != ProviderPreset.custom.id)
                SecureField("API key", text: $model.apiKey, prompt: Text("sk-…"))
            } footer: {
                Text("API key 存在「鑰匙圈」，每個服務各存一把。")
            }
            Section {
                TextField("模型", text: $model.draft.model)
                Picker("語言", selection: $model.draft.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("提示詞", text: $model.draft.prompt, prompt: Text("選填"), axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text("中英混合時，「自動偵測」通常比固定語言準。")
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
                Picker("觸發方式", selection: $model.draft.triggerKind) {
                    Text("單一修飾鍵").tag(TriggerKind.modifier)
                    Text("組合鍵").tag(TriggerKind.combo)
                }
                .pickerStyle(.segmented)

                if model.draft.triggerKind == .modifier {
                    Picker("按鍵", selection: $model.draft.trigger) {
                        ForEach(TriggerKey.allCases.filter { !$0.isBusy }, id: \.self) { Text($0.label).tag($0) }
                        Divider()
                        ForEach(TriggerKey.allCases.filter(\.isBusy), id: \.self) { Text($0.label).tag($0) }
                    }
                } else {
                    LabeledContent("組合鍵") {
                        ComboRecorder(model: model)
                    }
                }

                Picker("模式", selection: $model.draft.mode) {
                    Text("按住說話").tag(RecordingMode.hold)
                    Text("按一下切換").tag(RecordingMode.toggle)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.draft.mode == .hold
                         ? "按住 \(model.draft.activeTrigger.label) 說話，放開後送出。"
                         : "按一下 \(model.draft.activeTrigger.label) 開始，再按一下送出。")
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
                ? "還沒錄製組合鍵，暫時使用 \(model.draft.trigger.label)。錄音中按 Esc 取消。"
                : "錄音中按 Esc 取消。組合鍵被其他 app 佔用時會沒有反應，請換一組。"
        }
        switch model.draft.trigger {
        case .fn: return "Fn／🌐 只在 Apple 鍵盤上有效。請把「系統設定 › 鍵盤 › 按下 🌐 鍵時」設為「不執行任何動作」。"
        case let key where key.isBusy: return "左側修飾鍵常用在快捷鍵，容易誤觸。跟其他鍵一起按時不會錄音。錄音中按 Esc 取消。"
        default: return "錄音中按 Esc 取消。觸發鍵跟其他鍵一起按（例如 ⌘C）不會錄音。"
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
                    Text(model.isCapturing ? "請按下組合鍵…" : (model.draft.combo?.label ?? "按此錄製"))
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
                    .help("清除組合鍵")
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
                Label("已允許", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button("開啟系統設定") {
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
