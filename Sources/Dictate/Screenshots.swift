import AppKit
import DictateCore

/// Screenshot mode for the README: `DICTATE_SCREENSHOTS=<dir> Dictate.app/Contents/MacOS/Dictate`
/// renders the HUD states and a usage scene offscreen to PNGs (light and dark), then quits. Nothing is shown on screen.
/// The text is English unless `DICTATE_LANGUAGE=zh-Hant` is set.
@MainActor
enum Screenshots {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["DICTATE_SCREENSHOTS"] else { return false }
        let env = ProcessInfo.processInfo.environment["DICTATE_LANGUAGE"] ?? ""
        Localizer.language = AppLanguage(rawValue: env) ?? .english
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let levels: [CGFloat] = [0.15, 0.4, 0.75, 1.0, 0.6, 0.35, 0.2]
        let states: [(String, HUD.Status)] = [("recording", .recording), ("transcribing", .transcribing)]
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, status) in states {
                let view = HUD.snapshotView(status, levels: levels)
                view.appearance = NSAppearance(named: appearance)
                view.setFrameSize(view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent("hud-\(name)-\(suffix).png"))
            }
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = scene(levels: levels)
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: out.appendingPathComponent("scene-\(suffix).png"))
        }
        print("screenshots: \(out.path)")
        return true
    }

    /// A plain document with text already typed, the caret at the end, and the
    /// recording HUD where it appears on screen: bottom center.
    private static func scene(levels: [CGFloat]) -> NSView {
        let size = NSSize(width: 720, height: 330)
        let root = SceneView(frame: NSRect(origin: .zero, size: size))

        let page = SceneView(frame: NSRect(x: 40, y: 96, width: size.width - 80, height: size.height - 136))
        page.fill = .textBackgroundColor
        page.stroke = .separatorColor
        page.radius = 12
        root.addSubview(page)

        // Opening of Moby-Dick (Herman Melville, 1851; public domain).
        let text = "Call me Ishmael. Some years ago—never mind how long precisely—having little or no "
            + "money in my purse, and nothing particular to interest me on shore, I thought I would "
            + "sail about a little and see the watery part of the world."
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: 17).fontDescriptor.withDesign(.serif)!, size: 17)!
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        let textView = NSTextView(frame: page.bounds.insetBy(dx: 28, dy: 24))
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style,
        ]))
        page.addSubview(textView)

        // Caret after the last character.
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            let last = layout.glyphRange(forCharacterRange: NSRange(location: text.utf16.count - 1, length: 1),
                                         actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: last, in: container)
            let caret = SceneView(frame: NSRect(x: textView.frame.minX + rect.maxX + 2,
                                                y: textView.frame.maxY - rect.maxY + 2,
                                                width: 2, height: font.ascender - font.descender))
            caret.fill = .controlAccentColor
            caret.radius = 1
            page.addSubview(caret)
        }

        let hud = HUD.snapshotView(.recording, levels: levels)
        let hudSize = hud.fittingSize
        // The pill sits 8 pt inside the view (room for its shadow). Clip to the pill
        // itself; offscreen, the material otherwise leaves marks at the view's edges.
        let inset: CGFloat = 8
        let clip = NSView(frame: NSRect(x: (size.width - hudSize.width) / 2 + inset, y: 24,
                                        width: hudSize.width - 2 * inset, height: hudSize.height - 2 * inset))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = clip.frame.height / 2
        clip.layer?.masksToBounds = true
        hud.frame = NSRect(x: -inset, y: -inset, width: hudSize.width, height: hudSize.height)
        clip.addSubview(hud)
        root.addSubview(clip)
        return root
    }
}

/// Plain view that paints a rounded fill, re-resolving colors per appearance.
private final class SceneView: NSView {
    var fill: NSColor = .windowBackgroundColor
    var stroke: NSColor?
    var radius: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let rect = stroke == nil ? bounds : bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.stroke()
        }
    }
}
