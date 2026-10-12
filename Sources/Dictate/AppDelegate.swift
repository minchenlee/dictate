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
    /// Sound + HUD wait briefly, so a trigger used as a shortcut modifier (⌘C) shows nothing.
    private var feedbackWork: DispatchWorkItem?
    private let feedbackDelay: TimeInterval = 0.15
    /// Last queued transcription. Each new one waits for it, so text lands in speaking order.
    private var pending: Task<Void, Never>?
    private var inFlight = 0
    private var history = TranscriptHistory(capacity: 10)
    private let usage = UsageStore()

    /// Recordings shorter than this, or quieter than `silenceDB`, are dropped.
    private let minDuration: TimeInterval = 0.4
    private let silenceDB: Float = -45
    private let maxDuration: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Localizer.language = settings.uiLanguage
        if Screenshots.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = MainMenu.make()
        machine.mode = settings.mode
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        recorder.onLevel = { [weak self] level in self?.hud.level(level) }

        monitor = HotkeyMonitor(trigger: settings.activeTrigger) { [weak self] event in
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
            hud.show(.message(L("Microphone access is needed")), autoHide: 2.5)
            return
        }
        do {
            try recorder.start()
        } catch {
            machine.reset()
            hud.show(.message(error.localizedDescription), autoHide: 2.5)
            return
        }
        let feedback = DispatchWorkItem { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.play("Tink")
            self.setIcon(.recording)
            self.hud.show(.recording)
        }
        feedbackWork = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + feedbackDelay, execute: feedback)
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
        feedbackWork?.cancel()
        recorder.stop()
        settleIndicators()
    }

    private func stopAndTranscribe() {
        maxDurationWork?.cancel()
        feedbackWork?.cancel()
        guard let take = recorder.stop() else { return }
        guard take.duration >= minDuration, take.peakPower > silenceDB else {
            setIcon(.idle)
            hud.show(.message(L("No speech detected")), autoHide: 1.5)
            return
        }
        guard let audio = try? Data(contentsOf: take.url) else {
            setIcon(.idle)
            hud.show(.message(L("Could not read the recording")), autoHide: 2.5)
            return
        }
        let config = TranscriptionConfig(
            baseURL: settings.baseURL,
            apiKey: Keychain.read(account: settings.keychainAccount) ?? "",
            model: settings.model,
            language: settings.language,
            prompt: settings.prompt)
        let convert = settings.convertToTraditional
        let model = settings.model
        let seconds = take.duration
        play("Pop")
        setIcon(.busy)
        hud.show(.transcribing)
        inFlight += 1
        let previous = pending
        pending = Task { [weak self] in
            let result: Result<String, Error>
            do {
                let response = try await Transcription.transcribe(config, audio: audio)
                // Billed even if the text turns out empty; record before anything else can fail.
                self?.usage.record(model: model, recordedSeconds: seconds, usage: response.usage)
                var text = response.text
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
            hud.show(.message(L("No Accessibility access. Text copied, press ⌘V")), autoHide: 5)
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

        let label = settings.activeTrigger.label
        let hint = settings.mode == .hold ? L("Hold %@ to talk", label) : L("Press %@ to start or send", label)
        let status = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
        status.image = symbol("mic")
        status.isEnabled = false
        menu.addItem(status)

        if !AXIsProcessTrusted() {
            let warn = item(L("Accessibility access needed…"), "exclamationmark.triangle", #selector(openSettings))
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let recent = NSMenuItem(title: L("Recent Transcripts"), action: nil, keyEquivalent: "")
        recent.image = symbol("clock.arrow.circlepath")
        let sub = NSMenu()
        if history.entries.isEmpty {
            let empty = NSMenuItem(title: L("No Transcripts"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            sub.addItem(.sectionHeader(title: L("Click to Copy")))
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
            sub.addItem(item(L("Clear History"), "trash", #selector(clearHistory)))
        }
        recent.submenu = sub
        menu.addItem(recent)

        menu.addItem(.separator())
        menu.addItem(item(L("Settings…"), "gearshape", #selector(openSettings), key: ","))
        menu.addItem(item(L("Quit Dictate"), nil, #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
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
            model.onCaptureChange = { [weak self] capturing in
                guard let self else { return }
                if capturing {
                    if self.machine.isRecording { self.cancelRecording() }
                    self.machine.reset()
                    self.monitor.stop()
                } else {
                    self.monitor.start()
                }
            }
            settingsWindow = SettingsWindowController(model: model, usage: usage)
        }
        settingsWindow?.show()
    }

    /// SwiftUI views read strings when built, so a language change rebuilds the window in place.
    private func reopenSettingsWindow() {
        guard let old = settingsWindow?.window else { return }
        let origin = old.frame.origin
        let height = old.frame.height
        old.close()
        settingsWindow = nil
        openSettings()
        guard let window = settingsWindow?.window else { return }
        // Keep the top-left corner where it was.
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + height - window.frame.height))
    }

    private func apply(_ new: DictateSettings) {
        let old = settings
        settings = new
        if new.uiLanguage != old.uiLanguage {
            Localizer.language = new.uiLanguage
            reopenSettingsWindow()
        }
        guard new.mode != old.mode || new.activeTrigger != old.activeTrigger else { return }
        if machine.isRecording { cancelRecording() }
        machine = HotkeyMachine(mode: new.mode)
        monitor.trigger = new.activeTrigger
        monitor.start()
        if case .combo(let combo) = new.activeTrigger, !monitor.isComboRegistered {
            hud.show(.message(L("%@ is used by another app. Choose another.", combo.label)), autoHide: 4)
        }
    }
}
