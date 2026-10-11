import AppKit
import AVFoundation
import DictateCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings = DictateSettings.load(from: .standard)
    private var machine = HotkeyMachine(mode: .hold)
    private var monitor: HotkeyMonitor!
    private let recorder = Recorder()
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController?
    private var axPoll: Timer?
    private var maxDurationWork: DispatchWorkItem?
    /// Last queued transcription. Each new one waits for it, so text lands in speaking order.
    private var pending: Task<Void, Never>?
    private var inFlight = 0
    private var history = TranscriptHistory(capacity: 10)

    /// Recordings shorter than this, or quieter than `silenceDB`, are dropped.
    private let minDuration: TimeInterval = 0.4
    private let silenceDB: Float = -45
    private let maxDuration: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make()
        machine.mode = settings.mode
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        recorder.onLevel = { [weak self] level in self?.hud.level(level) }

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
        play("Tink")
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
        play("Pop")
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
        history.add(text)
        if TextInserter.insert(text) == .clipboardOnly {
            hud.show(.message("沒有「輔助使用」權限，文字已拷貝，請按 ⌘V"), autoHide: 5)
            ensureAccessibility(prompt: false)
        }
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

    private func play(_ name: String) {
        guard settings.playSounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }

    /// Rebuilt every time it opens, so permission state and history are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = settings.mode == .hold ? "按住\(settings.trigger.label)說話" : "按一下\(settings.trigger.label)開始或送出"
        let status = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
        status.image = symbol("mic")
        status.isEnabled = false
        menu.addItem(status)

        if !AXIsProcessTrusted() {
            let warn = item("需要「輔助使用」權限…", "exclamationmark.triangle", #selector(openSettings))
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let recent = NSMenuItem(title: "最近的轉錄", action: nil, keyEquivalent: "")
        recent.image = symbol("clock.arrow.circlepath")
        let sub = NSMenu()
        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "沒有紀錄", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            sub.addItem(.sectionHeader(title: "按一下拷貝"))
            for (index, entry) in history.entries.enumerated() {
                let row = NSMenuItem(title: TranscriptHistory.title(for: entry.text), action: #selector(copyEntry(_:)), keyEquivalent: "")
                row.target = self
                row.tag = index
                row.toolTip = entry.text
                if index < 9 {
                    row.keyEquivalent = "\(index + 1)"
                    row.keyEquivalentModifierMask = .command
                }
                sub.addItem(row)
            }
            sub.addItem(.separator())
            sub.addItem(item("清除紀錄", "trash", #selector(clearHistory)))
        }
        recent.submenu = sub
        menu.addItem(recent)

        menu.addItem(.separator())
        menu.addItem(item("設定…", "gearshape", #selector(openSettings), key: ","))
        menu.addItem(item("結束 Dictate", nil, #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func item(_ title: String, _ image: String?, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.image = image.flatMap(symbol)
        return item
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard history.entries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history.entries[sender.tag].text, forType: .string)
    }

    @objc private func clearHistory() {
        history.clear()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(settings: settings)
            model.onChange = { [weak self] new in self?.apply(new) }
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    private func apply(_ new: DictateSettings) {
        let old = settings
        settings = new
        guard new.mode != old.mode || new.trigger != old.trigger else { return }
        if machine.isRecording { cancelRecording() }
        machine = HotkeyMachine(mode: new.mode)
        monitor.trigger = new.trigger
        monitor.start()
    }
}
