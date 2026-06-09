import Foundation

/// A normalized, decoded message ready to be written into index.db.
public struct IndexedMessage: Sendable {
    public let id: Int64           // mirrors chat.db message.ROWID (the watermark)
    public let chatID: Int
    public let tsUnix: Double
    public let sender: String      // handle.id or "me"
    public let senderName: String? // optional friendly name
    public let isFromMe: Bool
    public let body: String?       // decoded text; nil for non-text rows (media)
    public let hasMedia: Bool
    public let replyTo: Int64?
    public let mediaText: String?  // image tags + OCR (from the Vision pass), if any

    public init(id: Int64, chatID: Int, tsUnix: Double, sender: String, senderName: String?,
                isFromMe: Bool, body: String?, hasMedia: Bool, replyTo: Int64?, mediaText: String? = nil) {
        self.id = id; self.chatID = chatID; self.tsUnix = tsUnix
        self.sender = sender; self.senderName = senderName; self.isFromMe = isFromMe
        self.body = body; self.hasMedia = hasMedia; self.replyTo = replyTo
        self.mediaText = mediaText
    }
}
