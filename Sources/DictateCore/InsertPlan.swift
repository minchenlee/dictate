/// How to deliver a transcript to the focused field.
public enum InsertPlan: Equatable, Sendable {
    /// Put text on the pasteboard, post ⌘V, then restore the old pasteboard.
    case pasteAndRestore
    /// Posting keys needs Accessibility; without it ⌘V is dropped silently.
    /// Leave the text on the pasteboard so the user can paste it by hand.
    case clipboardOnly

    public static func decide(accessibilityTrusted: Bool) -> InsertPlan {
        accessibilityTrusted ? .pasteAndRestore : .clipboardOnly
    }
}
