import AppKit
import AVFoundation
import DictateCore
import SwiftUI

/// Edits a draft of the settings; "儲存" writes UserDefaults + Keychain and notifies the app.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var draft: DictateSettings
    @Published var apiKey: String
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var saved = false
    let openCCPath: String?

    var onSave: (DictateSettings) -> Void = { _ in }

    init(settings: DictateSettings) {
        draft = settings
        apiKey = Keychain.read(account: settings.keychainAccount) ?? ""
        openCCPath = OpenCC.find()?.executable.path
        refreshPermissions()
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    func selectProvider(_ id: String) {
        let preset = ProviderPreset.byID(id)
        draft.providerID = id
        if id != ProviderPreset.custom.id {
            draft.baseURL = preset.baseURL
            draft.model = preset.defaultModel
        }
        apiKey = Keychain.read(account: draft.keychainAccount) ?? ""
    }

    func save() {
        Keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: draft.keychainAccount)
        draft.save(to: .standard)
        onSave(draft)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.saved = false }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private let languages: [(String, String)] = [("", "自動偵測"), ("zh", "中文"), ("en", "English"), ("ja", "日本語")]

    var body: some View {
        Form {
            Section("轉錄服務") {
                Picker("服務", selection: Binding(get: { model.draft.providerID }, set: { model.selectProvider($0) })) {
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
                }
                TextField("API base URL", text: $model.draft.baseURL)
                    .disabled(model.draft.providerID != ProviderPreset.custom.id)
                SecureField("API key", text: $model.apiKey)
                TextField("模型", text: $model.draft.model)
                Picker("語言", selection: $model.draft.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("提示詞（選填）", text: $model.draft.prompt)
            }
            Section("快捷鍵") {
                Picker("觸發鍵", selection: $model.draft.trigger) {
                    ForEach(TriggerKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("模式", selection: $model.draft.mode) {
                    Text("按住說話，放開送出").tag(RecordingMode.hold)
                    Text("按一下開始，再按一下送出").tag(RecordingMode.toggle)
                }
                Text("錄音中按 Esc 取消。觸發鍵和其他鍵一起按（例如 ⌘C）不會錄音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文字") {
                Toggle("簡體轉繁體（台灣用語）", isOn: $model.draft.convertToTraditional)
                Text(model.openCCPath.map { "使用 \($0)" } ?? "找不到 opencc，會輸出原文。安裝：brew install opencc")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("權限") {
                permissionRow("麥克風", granted: model.micGranted, pane: "Privacy_Microphone")
                permissionRow("輔助使用（快捷鍵與貼上）", granted: model.axGranted, pane: "Privacy_Accessibility")
            }
            HStack {
                Spacer()
                if model.saved { Text("已儲存").foregroundStyle(.secondary) }
                Button("儲存") { model.save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted {
                Button("開啟系統設定") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
