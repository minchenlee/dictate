import Foundation

/// Recent transcripts, newest first. Memory only: never written to disk.
public struct TranscriptHistory: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let date: Date
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []

    public init(capacity: Int = 10) {
        self.capacity = capacity
    }

    public mutating func add(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Entry(text: trimmed, date: date), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// One-line menu title: newlines folded, cut to `limit` characters.
    public static func title(for text: String, limit: Int = 48) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
