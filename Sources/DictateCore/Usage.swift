import Foundation

/// Usage a provider reports with a transcription. Every field is optional:
/// OpenRouter sends `cost` in US dollars, OpenAI sends tokens or seconds, some servers send nothing.
public struct TranscriptionUsage: Equatable, Sendable {
    public var seconds: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Charged amount in US dollars, when the provider reports it.
    public var cost: Double?

    public init(seconds: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, cost: Double? = nil) {
        self.seconds = seconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        self.init(
            seconds: number("seconds"),
            inputTokens: number("input_tokens").map { Int($0) },
            outputTokens: number("output_tokens").map { Int($0) },
            cost: number("cost"))
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public let text: String
    public let usage: TranscriptionUsage?
}

/// List prices for estimating cost when the provider does not report it.
/// US dollars per audio minute, from public price listings in October 2026.
public enum Pricing {
    static let perMinute: [String: Double] = [
        "gpt-transcribe": 0.0045,
        "gpt-4o-transcribe": 0.006,
        "gpt-4o-mini-transcribe": 0.003,
        "whisper-1": 0.006,
    ]

    /// Price for a model ID, ignoring a provider prefix such as `openai/`. Nil if unknown.
    public static func perMinute(for model: String) -> Double? {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return perMinute[id.split(separator: "/").last.map(String.init) ?? id]
    }
}

/// Usage added up over some period.
public struct UsageTotal: Codable, Equatable, Sendable {
    public var count = 0
    public var seconds: Double = 0
    /// Cost the provider reported.
    public var reportedCost: Double = 0
    /// Cost estimated from audio length and `Pricing`.
    public var estimatedCost: Double = 0
    /// Transcriptions with neither a reported cost nor a known price.
    public var unpriced = 0

    public init(count: Int = 0, seconds: Double = 0, reportedCost: Double = 0, estimatedCost: Double = 0, unpriced: Int = 0) {
        self.count = count
        self.seconds = seconds
        self.reportedCost = reportedCost
        self.estimatedCost = estimatedCost
        self.unpriced = unpriced
    }

    public var cost: Double { reportedCost + estimatedCost }

    mutating func add(_ other: UsageTotal) {
        count += other.count
        seconds += other.seconds
        reportedCost += other.reportedCost
        estimatedCost += other.estimatedCost
        unpriced += other.unpriced
    }
}

public enum UsagePeriod: CaseIterable, Sendable {
    case today, week, month, all
}

/// Transcription usage kept as one total per local calendar day. No text is stored.
public struct UsageLedger: Codable, Equatable, Sendable {
    /// Keyed by local date, "yyyy-MM-dd", so keys sort by date.
    public private(set) var days: [String: UsageTotal] = [:]

    public init() {}

    public mutating func record(model: String, recordedSeconds: Double, usage: TranscriptionUsage?,
                                at date: Date = Date(), calendar: Calendar = .current) {
        var entry = UsageTotal(count: 1, seconds: usage?.seconds ?? recordedSeconds)
        if let cost = usage?.cost {
            entry.reportedCost = cost
        } else if let rate = Pricing.perMinute(for: model) {
            entry.estimatedCost = entry.seconds / 60 * rate
        } else {
            entry.unpriced = 1
        }
        days[Self.key(date, calendar), default: UsageTotal()].add(entry)
    }

    public func total(_ period: UsagePeriod, now: Date = Date(), calendar: Calendar = .current) -> UsageTotal {
        let component: Calendar.Component? = switch period {
        case .today: .day
        case .week: .weekOfYear
        case .month: .month
        case .all: nil
        }
        var range: Range<String>?
        if let component, let interval = calendar.dateInterval(of: component, for: now) {
            range = Self.key(interval.start, calendar)..<Self.key(interval.end, calendar)
        }
        var sum = UsageTotal()
        for (key, value) in days where range?.contains(key) ?? true { sum.add(value) }
        return sum
    }

    public mutating func reset() {
        days.removeAll()
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `~/Library/Application Support/Dictate/usage.json`
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Dictate/usage.json")
    }

    /// An empty ledger if the file is missing or unreadable.
    public static func load(from url: URL = defaultURL) -> UsageLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(UsageLedger.self, from: data) else { return UsageLedger() }
        return ledger
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
