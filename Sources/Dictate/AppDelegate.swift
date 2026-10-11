import AppKit
import AVFoundation
import DictateCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = DictateSettings.load(from: .standard)
    private var machine = HotkeyMachine(mode: .hold)
    private var monitor: HotkeyMonitor!
    private let recorder = Recorder()
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var axPoll: Timer?
    private var maxDurationWork: DispatchWorkItem?
    /// Last queued transcription. Each new one waits for it, so text lands in speaking order.
    private var pending: Task<Void, Never>?
    private var inFlight = 0
    private var lastTranscript: String?

    /// Recordings shorter than this, or quieter than `silenceDB`, are dropped.
    private let minDuration: TimeInterval = 0.4
    private let silenceDB: Float = -45
    private let maxDuration: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        machine.mode = settings.mode
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        rebuildMenu()

        monitor = HotkeyMonitor(trigger: settings.trigger) { [weak self] event in
            self?.handle(event)
        }
        monitor.start()
        ensureAccessibility(prompt: true)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if Keychain.read(account: settings.keychainAccount)?.isEmpty ?? true {
            openSettings()
        }
    }

    // MARK: Hotkey → actions

    private func handle(_ event: HotkeyEvent) {
        switch machine.handle(event) {
        case .none: break
        case .start: startRecording()
        case .stop: stopAndTranscribe()
        case .cancel: cancelRecording()
        }
    }

    private func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            machine.reset()
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            hud.show(.message("需要麥克風權限"), autoHide: 2.5)
            return
        }
        do {
            try recorder.start()
        } catch {
            machine.reset()
            hud.show(.message(error.localizedDescription), autoHide: 2.5)
            return
        }
        setIcon(.recording)
        hud.show(.recording)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.machine.reset()
            self.stopAndTranscribe()
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration, execute: work)
    }

    private func cancelRecording() {
        maxDurationWork?.cancel()
        recorder.stop()
        setIcon(.idle)
        hud.hide()
    }

    private func stopAndTranscribe() {
        maxDurationWork?.cancel()
        guard let take = recorder.stop() else { return }
        guard take.duration >= minDuration, take.peakPower > silenceDB else {
            setIcon(.idle)
            hud.show(.message("沒有聽到聲音"), autoHide: 1.5)
            return
        }
        guard let audio = try? Data(contentsOf: take.url) else {
            setIcon(.idle)
            hud.show(.message("讀不到錄音檔"), autoHide: 2.5)
            return
        }
        let config = TranscriptionConfig(
            baseURL: settings.baseURL,
            apiKey: Keychain.read(account: settings.keychainAccount) ?? "",
            model: settings.model,
            language: settings.language,
            prompt: settings.prompt)
        let convert = settings.convertToTraditional
        setIcon(.busy)
        hud.show(.transcribing)
        inFlight += 1
        let previous = pending
        pending = Task { [weak self] in
            let result: Result<String, Error>
            do {
                var text = try await Transcription.transcribe(config, audio: audio)
                if convert, let opencc = OpenCC.find() {
                    text = await Task.detached { ChineseConverter.convert(text) { try opencc.run($0) } }.value
                }
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            await previous?.value
            guard let self else { return }
            self.inFlight -= 1
            switch result {
            case .success(let text): self.finish(text)
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }

    private func finish(_ text: String) {
        settleIndicators()
        guard !text.isEmpty else { return }
        lastTranscript = text
        rebuildMenu()
        TextInserter.insert(text)
    }

    private func fail(_ message: String) {
        guard !recorder.isRecording else { return }
        if inFlight == 0 { setIcon(.idle) }
        hud.show(.message(message), autoHide: 4)
    }

    /// Back to idle, unless a newer recording or transcription is still running.
    private func settleIndicators() {
        guard !recorder.isRecording, inFlight == 0 else { return }
        setIcon(.idle)
        hud.hide()
    }

    // MARK: Permissions

    private func ensureAccessibility(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        // Global monitors added before trust is granted stay deaf; re-add them once it is.
        axPoll?.invalidate()
        axPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.monitor.start()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: Menu bar

    private enum IconState { case idle, recording, busy }

    private func setIcon(_ state: IconState) {
        let name = switch state {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .busy: "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dictate")
        image?.isTemplate = state != .recording
        if state == .recording {
            statusItem.button?.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else {
            statusItem.button?.image = image
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let modeText = settings.mode == .hold ? "按住 \(settings.trigger.label) 說話" : "按一下 \(settings.trigger.label) 開始／結束"
        menu.addItem(withTitle: modeText, action: nil, keyEquivalent: "").isEnabled = false
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "⚠︎ 需要輔助使用權限…", action: #selector(openSettings), keyEquivalent: "").target = self
        }
        if let last = lastTranscript {
            menu.addItem(.separator())
            let preview = last.count > 40 ? String(last.prefix(40)) + "…" : last
            let item = menu.addItem(withTitle: "複製上一次：\(preview)", action: #selector(copyLast), keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "結束 Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func copyLast() {
        guard let last = lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last, forType: .string)
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SettingsModel(settings: settings)
        model.onSave = { [weak self] new in self?.apply(new) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Dictate 設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func apply(_ new: DictateSettings) {
        settings = new
        if machine.isRecording { cancelRecording() }
        machine = HotkeyMachine(mode: new.mode)
        monitor.trigger = new.trigger
        monitor.start()
        rebuildMenu()
    }
}
