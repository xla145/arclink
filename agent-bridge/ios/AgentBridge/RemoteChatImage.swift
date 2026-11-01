import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes the actual remote payload once; the same bytes are sent and saved.
/// Limits leave room for Base64, JSON and text within the native NDJSON record.
enum RemoteChatImage {
    static let maximumCount = 4
    static let maximumBytes = 256 * 1024
    static let maximumTotalBytes = 1024 * 1024

    enum PreparationError: Error, LocalizedError {
        case tooMany, invalid, cannotCompress
        var errorDescription: String? {
            switch self {
            case .tooMany: "最多发送 4 张图片。"
            case .invalid: "图片无法读取或超过 10 MB，请重新选择。"
            case .cannotCompress: "图片无法压缩到发送限制，请选择较小的图片。"
            }
        }
    }

    static func prepare(_ images: [Data]) throws -> [Data] {
        guard images.count <= maximumCount else { throw PreparationError.tooMany }
        let prepared = try images.map { try prepareOne($0) }
        guard prepared.reduce(0, { $0 + $1.count }) <= maximumTotalBytes else {
            throw PreparationError.cannotCompress
        }
        return prepared
    }

    private static func prepareOne(_ data: Data) throws -> Data {
        guard ChatAttachment.isValid(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PreparationError.invalid }
        for dimension in [2048, 1536, 1024, 768, 512, 384, 256] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
            ] as CFDictionary) else { throw PreparationError.invalid }
            for quality in [0.85, 0.70, 0.55, 0.40, 0.25] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw PreparationError.cannotCompress
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), encoded.length <= maximumBytes {
                    return encoded as Data
                }
            }
        }
        throw PreparationError.cannotCompress
    }
}
