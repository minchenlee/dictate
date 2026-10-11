import Foundation
@testable import DictateCore

// Foundation lives here, not in the test file: importing Foundation and Testing together needs
// _Testing_Foundation, which Command Line Tools does not ship.
enum Support {
    struct Sent {
        let method: String?
        let authorization: String?
        let contentType: String?
        let body: String
    }

    static func request(_ config: TranscriptionConfig, boundary: String = "B") throws -> Sent {
        let req = try Transcription.makeRequest(config, audio: Data([0x00, 0x01, 0x02]), boundary: boundary)
        return Sent(
            method: req.httpMethod,
            authorization: req.value(forHTTPHeaderField: "Authorization"),
            contentType: req.value(forHTTPHeaderField: "Content-Type"),
            body: String(decoding: req.httpBody ?? Data(), as: UTF8.self))
    }

    static func parse(_ body: String, status: Int) throws -> String {
        try Transcription.parse(data: Data(body.utf8), status: status)
    }

    // Stand-in for `opencc -c s2twp`.
    static let map: [String: String] = ["软件": "軟體", "网络": "網路", "这": "這", "开": "開", "发": "發"]
    static func fakeOpenCC(_ s: String) -> String {
        map.reduce(s) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    static func dropOpenMarker(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{E000}", with: "")
    }

    /// Saves `settings` to a throwaway UserDefaults suite and loads it back.
    static func roundTrip(_ settings: DictateSettings?) -> (fresh: DictateSettings, loaded: DictateSettings) {
        let defaults = UserDefaults(suiteName: "dictate-tests-\(UUID().uuidString)")!
        let fresh = DictateSettings.load(from: defaults)
        settings?.save(to: defaults)
        return (fresh, DictateSettings.load(from: defaults))
    }
}

extension Support {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func table(_ code: String) -> [String: String] {
        Localizer.parse(repo.appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings"))
    }

    static func sources() -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
        }
    }

    /// String literals passed to `L(`, or given as a `nameKey:` (looked up later), in Sources.
    static func localizedKeys() -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"(?:\bL\(|nameKey: )"((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for (_, text) in sources() {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return keys
    }

    static func placeholders(_ s: String) -> Int {
        s.components(separatedBy: "%@").count - 1
    }

    /// String literals with CJK text, outside the allowed ones.
    static func chineseLiterals() -> [String] {
        let allowed = ["以下是繁體中文的口述，可能夾雜英文詞彙。", "繁體中文"]
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        var out: [String] = []
        for (path, text) in sources() {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let literal = ns.substring(with: m.range(at: 1))
                if ChineseConverter.needsConversion(literal), !allowed.contains(literal) {
                    out.append("\(path): \(literal)")
                }
            }
        }
        return out
    }
}

import AppKit

extension Support {
    /// ⌘-key → action selector name for every item in the app's main menu.
    @MainActor static func editShortcuts() -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub) }
                if let action = item.action, item.keyEquivalentModifierMask == .command {
                    out[item.keyEquivalent] = NSStringFromSelector(action)
                }
            }
        }
        walk(MainMenu.make())
        return out
    }
}
