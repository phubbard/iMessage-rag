import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Decodes any ImageIO-supported file (incl. HEIC) and re-encodes a downscaled
/// JPEG. Used to serve family photos as thumbnails over the LAN without shipping
/// multi-MB HEICs to the browser.
enum ImageThumbnailer {
    static func jpeg(path: String, maxPixel: Int, quality: Double = 0.8) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,    // respect EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
