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
