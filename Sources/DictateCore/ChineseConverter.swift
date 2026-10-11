import Foundation

/// Simplified → Traditional (Taiwan) conversion that leaves code and URLs alone.
/// Masks protected spans with private-use placeholders, converts the rest with
/// `opencc -c s2twp`, then restores the spans.
public enum ChineseConverter {
    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"

    private static let protected = try! NSRegularExpression(pattern: [
        "```[\\s\\S]*?(?:```|$)", // fenced code (unterminated runs to the end)
        "`[^`\\n]*`", // inline code
        "[A-Za-z][A-Za-z0-9+.-]*://\\S+", // URLs
    ].joined(separator: "|"))

    private static let slot = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")

    public static func needsConversion(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
        }
    }

    public static func protect(_ text: String) -> (masked: String, slots: [String]) {
        var slots: [String] = []
        var masked = ""
        let ns = text as NSString
        var cursor = 0
        for match in protected.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            masked += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            masked += "\(open)\(slots.count)\(close)"
            slots.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        masked += ns.substring(from: cursor)
        return (masked, slots)
    }

    /// Returns nil when the converter damaged a placeholder.
    public static func restore(_ masked: String, slots: [String]) -> String? {
        let ns = masked as NSString
        var out = ""
        var cursor = 0
        var seen = 0
        for match in slot.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(ns.substring(with: match.range(at: 1))) ?? -1
            guard slots.indices.contains(index) else { return nil }
            out += slots[index]
            seen += 1
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        guard seen == slots.count, !out.contains(open), !out.contains(close) else { return nil }
        return out
    }

    /// Converts `text` with `run`; returns the original text when anything goes wrong.
    public static func convert(_ text: String, run: (String) throws -> String) -> String {
        guard needsConversion(text) else { return text }
        let (masked, slots) = protect(text)
        guard let converted = try? run(masked), let out = restore(converted, slots: slots) else { return text }
        return out
    }
}

/// Runs the `opencc` CLI (Homebrew). Missing binary means no conversion.
public struct OpenCC: Sendable {
    public let executable: URL

    public static let searchPaths = ["/opt/homebrew/bin/opencc", "/usr/local/bin/opencc", "/usr/bin/opencc"]

    public static func find() -> OpenCC? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { OpenCC(executable: URL(fileURLWithPath: $0)) }
    }

    public init(executable: URL) {
        self.executable = executable
    }

    public struct Failed: Error {}

    public func run(_ input: String, config: String = "s2twp") throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", config]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed() }
        var text = String(decoding: output, as: UTF8.self)
        // opencc appends a newline the input did not have.
        if text.hasSuffix("\n"), !input.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
