import UIKit
import CoreImage
import CoreVideo

struct PageSegmentationResult {
    let contour: [CGPoint]
    let bounds: CGRect
    /// A heuristic evidence score, not a probability calibrated on a book dataset.
    let confidence: Double
    let needsReview: Bool
    let mask: [UInt8]
    let maskWidth: Int
    let maskHeight: Int
    let clippedEdges: [String]
}

/// Native paper-surface proposal. No neural network or rectangle detector is hidden here.
/// A white desk, two connected pages or a large occlusion can remain ambiguous.
final class PageSegmentationService {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func detect(image: UIImage) -> PageSegmentationResult? {
        guard let cg = ScanRaster.upright(image).cgImage else { return nil }
        return detect(cgImage: cg)
    }

    func detect(pixelBuffer: CVPixelBuffer) -> PageSegmentationResult? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return detect(cgImage: cg)
    }

    private func detect(cgImage: CGImage) -> PageSegmentationResult? {
        guard let raster = ScanRaster(cgImage: cgImage, maxDimension: 256),
              let surface = ScanGeometry.segment(rgba: raster.bytes, width: raster.width, height: raster.height) else { return nil }
        return PageSegmentationResult(contour: surface.contour, bounds: surface.bounds,
                                      confidence: surface.confidence,
                                      needsReview: surface.confidence < 0.80 || !surface.clippedEdges.isEmpty,
                                      mask: surface.mask, maskWidth: raster.width, maskHeight: raster.height,
                                      clippedEdges: surface.clippedEdges)
    }
}

/// Shared bounded-memory raster conversion. Bitmap row zero corresponds to image top.
struct ScanRaster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    static func upright(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.cgImage != nil { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    init?(cgImage: CGImage, maxDimension: Int) {
        let scale = min(1, Double(maxDimension)/Double(max(cgImage.width,cgImage.height)))
        width = max(1, Int((Double(cgImage.width)*scale).rounded()))
        height = max(1, Int((Double(cgImage.height)*scale).rounded()))
        var data = [UInt8](repeating: 255, count: width*height*4)
        let w=width, h=height
        let success = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w*4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            // Core Graphics draws image scanlines in their natural order into a bitmap.
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard success else { return nil }
        bytes = data
    }

    var gray: [Double] {
        stride(from: 0, to: bytes.count, by: 4).map {
            0.299*Double(bytes[$0])+0.587*Double(bytes[$0+1])+0.114*Double(bytes[$0+2])
        }
    }

    static func image(bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: width*4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
