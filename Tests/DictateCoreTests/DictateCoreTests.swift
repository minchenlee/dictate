import Testing
@testable import DictateCore

@Suite struct HoldModeTests {
    @Test func holdThenReleaseTranscribes() {
        var m = HotkeyMachine(mode: .hold)
        #expect(m.handle(.triggerDown(1.0)) == .start)
        #expect(m.isRecording)
        #expect(m.handle(.triggerUp(2.0)) == .stop)
        #expect(!m.isRecording)
    }

    @Test func shortPressIsDiscarded() {
        var m = HotkeyMachine(mode: .hold)
        #expect(m.handle(.triggerDown(1.0)) == .start)
        #expect(m.handle(.triggerUp(1.1)) == .cancel)
    }

    @Test func shortcutWithTriggerCancelsAndWaitsForRelease() {
        var m = HotkeyMachine(mode: .hold)
        #expect(m.handle(.triggerDown(1.0)) == .start)
        #expect(m.handle(.otherKey) == .cancel) // ⌘C
        #expect(m.handle(.otherKey) == .none)
        #expect(m.handle(.triggerUp(3.0)) == .none)
        #expect(m.handle(.triggerDown(4.0)) == .start)
    }

    @Test func escapeCancels() {
        var m = HotkeyMachine(mode: .hold)
        _ = m.handle(.triggerDown(1.0))
        #expect(m.handle(.escape) == .cancel)
        #expect(m.handle(.triggerUp(5.0)) == .none)
    }

    @Test func keysWhileIdleDoNothing() {
        var m = HotkeyMachine(mode: .hold)
        #expect(m.handle(.otherKey) == .none)
        #expect(m.handle(.escape) == .none)
        #expect(m.handle(.triggerUp(1.0)) == .none)
    }
}

@Suite struct ToggleModeTests {
    @Test func tapStartsTapStops() {
        var m = HotkeyMachine(mode: .toggle)
        #expect(m.handle(.triggerDown(1.0)) == .none)
        #expect(m.handle(.triggerUp(1.1)) == .start)
        #expect(m.isRecording)
        #expect(m.handle(.otherKey) == .none) // typing while recording is fine
        #expect(m.handle(.triggerDown(5.0)) == .none)
        #expect(m.handle(.triggerUp(5.1)) == .stop)
        #expect(!m.isRecording)
    }

    @Test func longPressIsNotATap() {
        var m = HotkeyMachine(mode: .toggle)
        _ = m.handle(.triggerDown(1.0))
        #expect(m.handle(.triggerUp(2.0)) == .none)
        #expect(!m.isRecording)
    }

    @Test func shortcutDoesNotStart() {
        var m = HotkeyMachine(mode: .toggle)
        _ = m.handle(.triggerDown(1.0))
        #expect(m.handle(.otherKey) == .none)
        #expect(m.handle(.triggerUp(1.1)) == .none)
        #expect(!m.isRecording)
    }

    @Test func shortcutWhileRecordingKeepsRecording() {
        var m = HotkeyMachine(mode: .toggle)
        _ = m.handle(.triggerDown(1.0)); _ = m.handle(.triggerUp(1.1))
        _ = m.handle(.triggerDown(2.0))
        #expect(m.handle(.otherKey) == .none) // ⌘Tab
        #expect(m.handle(.triggerUp(2.1)) == .none)
        #expect(m.isRecording)
        _ = m.handle(.triggerDown(3.0))
        #expect(m.handle(.triggerUp(3.1)) == .stop)
    }

    @Test func escapeCancelsRecording() {
        var m = HotkeyMachine(mode: .toggle)
        _ = m.handle(.triggerDown(1.0)); _ = m.handle(.triggerUp(1.1))
        #expect(m.handle(.escape) == .cancel)
        #expect(!m.isRecording)
    }
}

@Suite struct TranscriptionTests {
    let config = TranscriptionConfig(
        baseURL: "https://openrouter.ai/api/v1/", apiKey: " sk-test ", model: "openai/gpt-transcribe",
        language: "zh", prompt: "繁體中文")

    @Test func endpointJoinsPath() {
        #expect(config.endpoint?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions")
        #expect(TranscriptionConfig(baseURL: "not a url", apiKey: "k", model: "m").endpoint == nil)
        #expect(TranscriptionConfig(baseURL: "", apiKey: "k", model: "m").endpoint == nil)
        #expect(TranscriptionConfig(baseURL: "ftp://x.com", apiKey: "k", model: "m").endpoint == nil)
    }

    @Test func requestIsOpenAIMultipart() throws {
        let req = try Support.request(config)
        #expect(req.method == "POST")
        #expect(req.authorization == "Bearer sk-test")
        #expect(req.contentType == "multipart/form-data; boundary=B")
        let body = req.body
        #expect(body.contains("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nopenai/gpt-transcribe\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nzh\r\n"))
        #expect(body.contains("name=\"prompt\"\r\n\r\n繁體中文\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(body.contains("name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"))
        #expect(body.hasSuffix("\r\n--B--\r\n"))
    }

    @Test func emptyOptionalFieldsAreOmitted() throws {
        let c = TranscriptionConfig(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-transcribe")
        let body = try Support.request(c).body
        #expect(!body.contains("name=\"language\""))
        #expect(!body.contains("name=\"prompt\""))
    }

    @Test func missingKeyOrURLThrows() {
        #expect(throws: TranscriptionError.missingAPIKey) {
            try Support.request(TranscriptionConfig(baseURL: "https://a.com/v1", apiKey: "  ", model: "m"))
        }
        #expect(throws: TranscriptionError.invalidEndpoint) {
            try Support.request(TranscriptionConfig(baseURL: "", apiKey: "k", model: "m"))
        }
    }

    @Test func parsesText() throws {
        #expect(try Support.parse(#"{"text":"  你好 world \n","usage":{"seconds":2}}"#, status: 200) == "你好 world")
    }

    @Test func parsesErrors() {
        #expect(throws: TranscriptionError.http(status: 401, message: "Invalid API key")) {
            try Support.parse(#"{"error":{"message":"Invalid API key"}}"#, status: 401)
        }
        #expect(throws: TranscriptionError.http(status: 502, message: "Bad Gateway")) {
            try Support.parse("Bad Gateway", status: 502)
        }
        #expect(throws: TranscriptionError.http(status: 200, message: "quota")) {
            try Support.parse(#"{"error":{"message":"quota"}}"#, status: 200)
        }
        #expect(throws: TranscriptionError.invalidResponse) {
            try Support.parse("{}", status: 200)
        }
    }
}

@Suite struct ChineseConverterTests {
    @Test func convertsSimplified() {
        #expect(ChineseConverter.convert("这个软件的网络") { Support.fakeOpenCC($0) } == "這个軟體的網路")
    }

    @Test func englishOnlySkipsConverter() {
        var called = false
        let out = ChineseConverter.convert("run the tests") { called = true; return $0 }
        #expect(out == "run the tests")
        #expect(!called)
    }

    @Test func codeAndURLsAreKept() {
        let text = "看这个 `软件` 与 https://x.cn/软件\n```\n软件 = 网络\n```\n开发"
        #expect(ChineseConverter.convert(text) { Support.fakeOpenCC($0) }
            == "看這个 `软件` 与 https://x.cn/软件\n```\n软件 = 网络\n```\n開發")
    }

    @Test func damagedPlaceholderFallsBack() {
        let text = "软件 `x`"
        #expect(ChineseConverter.convert(text) { Support.dropOpenMarker($0) } == text)
    }

    @Test func throwingConverterFallsBack() {
        struct Boom: Error {}
        #expect(ChineseConverter.convert("软件") { _ in throw Boom() } == "软件")
    }

    @Test(.enabled(if: OpenCC.find() != nil)) func realOpenCC() throws {
        let opencc = try #require(OpenCC.find())
        #expect(ChineseConverter.convert("这个软件的网络设置") { try opencc.run($0) } == "這個軟體的網路設定")
    }
}

@Suite struct SettingsTests {
    @Test func roundTrip() {
        #expect(Support.roundTrip(nil).fresh == DictateSettings())
        var s = DictateSettings()
        s.providerID = "openrouter"; s.baseURL = ProviderPreset.openRouter.baseURL
        s.model = "openai/gpt-transcribe"; s.mode = .toggle; s.trigger = .rightOption
        s.convertToTraditional = false; s.language = "zh"; s.playSounds = false
        #expect(Support.roundTrip(s).loaded == s)
        #expect(s.keychainAccount == "openrouter.ai")
    }

    @Test func defaultsMatchUserChoice() {
        let s = DictateSettings()
        #expect(s.mode == .hold && s.trigger == .rightCommand && s.model == "gpt-transcribe")
        #expect(s.language.isEmpty && s.convertToTraditional)
    }
}

@Suite struct EditMenuTests {
    // Menu-bar-only apps have no main menu by default, so ⌘V/⌘C/⌘A in text fields do nothing.
    @Test @MainActor func mainMenuRoutesStandardEditShortcuts() {
        let shortcuts = Support.editShortcuts()
        #expect(shortcuts["v"] == "paste:")
        #expect(shortcuts["c"] == "copy:")
        #expect(shortcuts["x"] == "cut:")
        #expect(shortcuts["a"] == "selectAll:")
        #expect(shortcuts["z"] == "undo:")
    }
}

@Suite struct HistoryTests {
    @Test func newestFirstAndCapped() {
        var h = TranscriptHistory(capacity: 3)
        for t in ["一", "二", "三", "四"] { h.add(t) }
        #expect(h.entries.map(\.text) == ["四", "三", "二"])
    }

    @Test func blankIsIgnoredAndTextTrimmed() {
        var h = TranscriptHistory()
        h.add("  \n ")
        h.add("  你好 \n")
        #expect(h.entries.map(\.text) == ["你好"])
        h.clear()
        #expect(h.entries.isEmpty)
    }

    @Test func menuTitleIsOneShortLine() {
        #expect(TranscriptHistory.title(for: "第一行\n第二行") == "第一行 第二行")
        #expect(TranscriptHistory.title(for: "abcdef", limit: 3) == "abc…")
        #expect(TranscriptHistory.title(for: "abc", limit: 3) == "abc")
    }
}

@Suite struct InsertPlanTests {
    // Without Accessibility, a posted ⌘V is dropped silently and the text is lost.
    @Test func untrustedKeepsTextOnClipboard() {
        #expect(InsertPlan.decide(accessibilityTrusted: false) == .clipboardOnly)
    }

    @Test func trustedPastes() {
        #expect(InsertPlan.decide(accessibilityTrusted: true) == .pasteAndRestore)
    }
}
