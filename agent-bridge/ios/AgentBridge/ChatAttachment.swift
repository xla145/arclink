import ImageIO
import UIKit

/// Limits both saved attachment size and decoded pixel allocation.
enum ChatAttachment {
    static let maximumCount = 4
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumPixels = 80_000_000

    static func isValid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumPixels / height else { return false }
        return true
    }

    static func prepare(_ data: Data) -> Data? {
        guard isValid(data), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }
}
