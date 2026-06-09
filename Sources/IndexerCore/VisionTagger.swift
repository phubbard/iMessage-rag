import Foundation
#if canImport(Vision)
import Vision
#endif

/// A processed image attachment row (written to image_meta).
public struct ImageRecord: Sendable {
    public let attachmentID: Int64
    public let messageID: Int64
    public let path: String
    public let mime: String?
    public let status: String      // ok | missing | error | skipped
    public let tags: String?       // comma-joined labels
    public let ocr: String?
    public let processedAt: Double

    public init(attachmentID: Int64, messageID: Int64, path: String, mime: String?,
                status: String, tags: String?, ocr: String?, processedAt: Double) {
        self.attachmentID = attachmentID; self.messageID = messageID; self.path = path
        self.mime = mime; self.status = status; self.tags = tags; self.ocr = ocr
        self.processedAt = processedAt
    }
}

/// Image display info attached to search/context results for the UI.
public struct ImageInfo: Codable, Sendable {
    public let attachmentID: Int64
    public let tags: [String]
    public let hasFile: Bool
    public init(attachmentID: Int64, tags: [String], hasFile: Bool) {
        self.attachmentID = attachmentID; self.tags = tags; self.hasFile = hasFile
    }
}

/// On-device image understanding via Apple's Vision framework: content tags
/// (`VNClassifyImageRequest`) + OCR (`VNRecognizeTextRequest`). Verified on
/// macOS 26 against real HEIC/PNG/GIF attachments.
public struct VisionTagger: Sendable {
    public var minConfidence: Float
    public var maxTags: Int

    public init(minConfidence: Float = 0.3, maxTags: Int = 8) {
        self.minConfidence = minConfidence
        self.maxTags = maxTags
    }

    public struct Analysis: Sendable {
        public let tags: [(label: String, confidence: Float)]
        public let ocr: String
    }

    /// Analyze an image file. Returns nil if Vision can't load/process it.
    public func analyze(url: URL) -> Analysis? {
        #if canImport(Vision)
        let handler = VNImageRequestHandler(url: url, options: [:])
        let classify = VNClassifyImageRequest()
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true
        do {
            try handler.perform([classify, ocr])
        } catch {
            return nil
        }
        let tags = (classify.results ?? [])
            .filter { $0.confidence >= minConfidence }
            .prefix(maxTags)
            .map { (label: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: $0.confidence) }
        let text = (ocr.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmed
        return Analysis(tags: Array(tags), ocr: text)
        #else
        return nil
        #endif
    }
}
