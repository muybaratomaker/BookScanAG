import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
    print("PASS: \(label)")
}
let region = CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
for size in [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000)] {
    let pixels = CropCoordinates.pixels(for: region, imageSize: size)
    check(pixels.width == size.width / 2 && pixels.height == size.height / 2, "Physical crop dimensions, \(size)")
    check(pixels.minX == size.width / 8 && pixels.minY == size.height / 4, "Off-centre normalized origin, \(size)")
}
let lowResolutionMask = CGRect(x: 32.0 / 256, y: 64.0 / 256, width: 128.0 / 256, height: 128.0 / 256)
check(CropCoordinates.pixels(for: lowResolutionMask, imageSize: CGSize(width: 4000, height: 3000)) == CGRect(x: 500, y: 750, width: 2000, height: 1500), "Low-resolution mask maps to full photograph")
let safe = CropCoordinates.expanded(region, margin: 0.03)
check(safe.contains(region) && abs(safe.width - 0.53) < 0.000001, "Safety margin adds 3 percent on each side")
let clipped = CropCoordinates.expanded(CGRect(x: 0, y: 0, width: 1, height: 1), margin: 0.12)
check(clipped == CGRect(x: 0, y: 0, width: 1, height: 1), "Margin cannot escape photograph")
let fractional = CGRect(x: 0.1234, y: 0.2345, width: 0.4567, height: 0.5678)
let size = CGSize(width: 4032, height: 3024)
let p = CropCoordinates.pixels(for: fractional, imageSize: size)
check(abs(p.minX - fractional.minX * size.width) < 1 && abs(p.maxX - fractional.maxX * size.width) < 1, "Pixel rounding tolerance below one pixel per edge")
check(CropCoordinates.pixels(for: region, imageSize: .zero).isNull, "Zero resolution rejected")
check(CropCoordinates.corners(region).first == region.origin, "Saved outline has same top-left origin")
// Preview coordinates are intentionally excluded from the crop API. The photograph's
// own detector supplies normalized coordinates, irrespective of aspect-fit/fill display.
#if canImport(CoreGraphics)
let width = 80, height = 40
var bytes = [UInt8](repeating: 255, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let color: [UInt8] = y < height / 2 ? (x < width / 2 ? [255, 0, 0] : [0, 255, 0]) : (x < width / 2 ? [0, 0, 255] : [255, 255, 0])
        for c in 0..<3 { bytes[(y * width + x) * 4 + c] = color[c] }
    }
}
let provider = CGDataProvider(data: Data(bytes) as CFData)!
let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
func rgb(_ image: CGImage) -> [UInt8] {
    let centre = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { memory in
        let context = CGContext(data: memory.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(centre, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return Array(pixel.prefix(3))
}
let crop = source.cropping(to: CropCoordinates.pixels(for: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), imageSize: CGSize(width: width, height: height)))!
check(crop.width == 40 && crop.height == 20 && rgb(crop) == [0, 255, 0], "CGImage crop physically contains top-right green quadrant")
let encoded = NSMutableData()
let destination = CGImageDestinationCreateWithData(encoded, UTType.tiff.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
check(CGImageDestinationFinalize(destination), "EXIF TIFF fixture encoded")
let imageSource = CGImageSourceCreateWithData(encoded as CFData, nil)!
let upright = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 80] as CFDictionary)!
check(upright.width == 40 && upright.height == 80, "ImageIO normalizes EXIF right orientation before cropping")
let rotatedCrop = upright.cropping(to: CropCoordinates.pixels(for: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), imageSize: CGSize(width: upright.width, height: upright.height)))!
check(rgb(rotatedCrop) == [0, 0, 255], "EXIF-normalized crop selects expected blue pixels, no Y inversion")
#else
print("SKIPPED: actual CGImage/EXIF fixtures require Apple CoreGraphics + ImageIO; run on macOS CI")
#endif
print("\(checks) crop checks passed")
