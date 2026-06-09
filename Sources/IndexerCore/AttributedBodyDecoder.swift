import Foundation

/// Decodes Messages' `attributedBody` BLOB (Apple's legacy `streamtyped`
/// NSArchiver format) into plain text. Proven on macOS 26 — see PLAN §6.
///
/// `NSUnarchiver` is deprecated since 10.13 but remains functional and is the
/// pragmatic choice for a personal app. Resolution order at the call site is:
/// use `text` if non-empty; else decode `attributedBody`; else treat as non-text.
public enum AttributedBodyDecoder {
    @available(macOS, deprecated: 10.13)
    public static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let s = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString {
            return s.string
        }
        // Some payloads unarchive to a plain NSString.
        if let s = NSUnarchiver.unarchiveObject(with: data) as? String {
            return s
        }
        return nil
    }
}
