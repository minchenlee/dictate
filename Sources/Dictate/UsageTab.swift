import DictateCore
import SwiftUI

/// Transcription usage, persisted after every change. Shared by the app and the settings window.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var ledger: UsageLedger
    private let url: URL

    init(url: URL = UsageLedger.defaultURL) {
        self.url = url
        ledger = UsageLedger.load(from: url)
    }

    func record(model: String, recordedSeconds: Double, usage: TranscriptionUsage?) {
        ledger.record(model: model, recordedSeconds: recordedSeconds, usage: usage)
        save()
    }

    func reset() {
        ledger.reset()
        save()
    }

    private func save() {
        do { try ledger.save(to: url) } catch { NSLog("Dictate: saving usage failed: \(error)") }
    }
}

struct UsageTab: View {
    @ObservedObject var store: UsageStore
    @State private var confirmReset = false

    private var rows: [(String, UsageTotal)] {
        let now = Date()
        return [
            (L("Today"), store.ledger.total(.today, now: now)),
            (L("This week"), store.ledger.total(.week, now: now)),
            (L("This month"), store.ledger.total(.month, now: now)),
            (L("All time"), store.ledger.total(.all, now: now)),
        ]
    }

    var body: some View {
        let all = store.ledger.total(.all)
        Form {
            Section {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text(verbatim: "").gridColumnAlignment(.leading)
                        Text(L("Transcriptions"))
                        Text(L("Minutes"))
                        Text(L("Cost (USD)"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows, id: \.0) { title, total in
                        GridRow {
                            Text(title)
                            Text(verbatim: "\(total.count)")
                            Text(verbatim: String(format: "%.1f", total.seconds / 60))
                            Text(verbatim: Self.money(total))
                        }
                        .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("OpenRouter reports the actual cost. For other services, ≈ marks an estimate from audio length and list prices."))
                    if all.unpriced > 0 {
                        Text(L("Model price unknown, so not in the cost: %@", "\(all.unpriced)"))
                    }
                    Text(L("Only counts and costs are stored on this Mac, not your text."))
                }
            }
            Section {
                LabeledContent(L("Reset usage")) {
                    Button(L("Reset…")) { confirmReset = true }
                        .disabled(all.count == 0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .confirmationDialog(L("Reset all usage counts?"), isPresented: $confirmReset) {
            Button(L("Reset"), role: .destructive) { store.reset() }
        }
    }

    /// "$0.0123", or "≈$0.0123" when any part is an estimate.
    static func money(_ total: UsageTotal) -> String {
        let cost = total.cost
        let amount = cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost)
        return total.estimatedCost > 0 ? "≈" + amount : amount
    }
}
