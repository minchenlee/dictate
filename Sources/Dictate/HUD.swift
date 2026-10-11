import AppKit
import SwiftUI
import DictateCore

/// Small floating pill near the bottom of the screen: recording / transcribing / message.
/// Non-activating and click-through, so it never steals focus from the target field.
@MainActor
final class HUD {
    enum Status: Equatable {
        case recording
        case transcribing
        case message(String)
    }

    private final class Model: ObservableObject {
        @Published var status: Status = .recording
        /// Recent input levels, oldest first, 0…1.
        @Published var levels: [CGFloat] = Array(repeating: 0, count: HUD.barCount)
    }

    nonisolated fileprivate static let barCount = 7
    private let model = Model()
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show, so a fade-out that finishes late does not hide a newer pill.
    private var generation = 0

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        return panel
    }()

    func show(_ status: Status, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        generation += 1
        if status == .recording { model.levels = Array(repeating: 0, count: Self.barCount) }
        withAnimation(.snappy(duration: 0.2)) { model.status = status }
        position()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func level(_ value: Float) {
        guard model.status == .recording else { return }
        model.levels.removeFirst()
        model.levels.append(CGFloat(value))
    }

    /// A detached pill view for screenshot mode.
    static func snapshotView(_ status: Status, levels: [CGFloat] = []) -> NSView {
        let model = Model()
        model.status = status
        if levels.count == barCount { model.levels = levels }
        return NSHostingView(rootView: PillView(model: model))
    }

    func hide() {
        hideWork?.cancel()
        guard panel.isVisible else { return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 160, height: 40)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 56))
    }

    private struct PillView: View {
        @ObservedObject var model: Model

        var body: some View {
            HStack(spacing: 10) {
                switch model.status {
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    LevelBars(levels: model.levels)
                case .transcribing:
                    ProgressView().controlSize(.small)
                    Text(L("Transcribing"))
                case .message(let text):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text(text).lineLimit(2)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 40)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .fixedSize()
            .padding(8) // room for the shadow
        }
    }

    private struct LevelBars: View {
        let levels: [CGFloat]

        var body: some View {
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 3, height: 4 + 16 * levels[i])
                }
            }
            .frame(height: 20)
            .animation(.linear(duration: 0.05), value: levels)
        }
    }
}
