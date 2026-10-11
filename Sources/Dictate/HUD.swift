import AppKit
import SwiftUI

/// Small floating pill near the bottom of the screen: recording / transcribing / error.
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
    }

    private let model = Model()
    private var hideWork: DispatchWorkItem?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
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
        model.status = status
        position()
        panel.orderFrontRegardless()
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 36)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }

    private struct PillView: View {
        @ObservedObject var model: Model

        var body: some View {
            HStack(spacing: 8) {
                switch model.status {
                case .recording:
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("錄音中")
                case .transcribing:
                    ProgressView().controlSize(.small)
                    Text("轉錄中…")
                case .message(let text):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(text).lineLimit(2)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 420)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .fixedSize()
        }
    }
}
