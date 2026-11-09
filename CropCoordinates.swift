import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The same conversion drives the actual CGImage crop and the saved review outline.
/// ImageIO normalizes EXIF before this is called. No preview/aspect-fill coordinates enter it.
enum CropCoordinates {
    static func expanded(_ rect: CGRect, margin: Double) -> CGRect {
        rect.insetBy(dx: -rect.width * max(0, margin), dy: -rect.height * max(0, margin))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    static func pixels(for rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return .null }
        return CGRect(x: rect.minX * imageSize.width, y: rect.minY * imageSize.height,
                      width: rect.width * imageSize.width, height: rect.height * imageSize.height)
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
    static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}
