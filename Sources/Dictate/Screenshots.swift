import AppKit

/// Screenshot mode for the README: `DICTATE_SCREENSHOTS=<dir> Dictate.app/Contents/MacOS/Dictate`
/// renders the HUD states offscreen to PNGs (light and dark), then quits. Nothing is shown on screen.
@MainActor
enum Screenshots {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["DICTATE_SCREENSHOTS"] else { return false }
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
        print("screenshots: \(out.path)")
        return true
    }
}
