import UIKit
import CoreML

/// Offline UVDoc inference. A valid grid is only a *candidate*, never proof of text preservation.
/// Run on the serial processing queue, not the main thread or the live camera queue.
final class UVDocDewarpModel {
    private lazy var model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "UVDoc", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    func correct(_ image: UIImage) -> UIImage? {
        guard image.imageOrientation == .up, let source = image.cgImage, let model else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let input = UIGraphicsImageRenderer(size: CGSize(width: 488, height: 712), format: format)
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 488, height: 712)) }
        guard let inputCG = input.cgImage,
              let feature = try? MLFeatureValue(cgImage: inputCG, pixelsWide: 488, pixelsHigh: 712,
                                                pixelFormatType: kCVPixelFormatType_32BGRA),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": feature]),
              let prediction = try? model.prediction(from: provider),
              let tensor = prediction.featureValue(for: "grid")?.multiArrayValue,
              tensor.shape.map({ $0.intValue }) == [1, 2, 45, 31] else { return nil }
        var points = [UVDocGrid.Point]()
        points.reserveCapacity(45 * 31)
        for y in 0..<45 {
            for x in 0..<31 {
                let sx = tensor[[0, 0, NSNumber(value: y), NSNumber(value: x)]].doubleValue
                let sy = tensor[[0, 1, NSNumber(value: y), NSNumber(value: x)]].doubleValue
                // Symmetric 2% margin around the predicted surface before resampling.
                points.append(.init(x: (sx * 1.04 + 1) / 2, y: (sy * 1.04 + 1) / 2))
            }
        }
        let grid = UVDocGrid(width: 31, height: 45, points: points)
        guard grid.isSafe else { return nil }
        return resample(source, grid: grid)
    }

    private func resample(_ source: CGImage, grid: UVDocGrid) -> UIImage? {
        // Bound per-page memory. The immutable full photo is retained separately on disk.
        let scale = min(1, 2400 / Double(max(source.width, source.height)))
        let width = max(2, Int(Double(source.width) * scale))
        let height = max(2, Int(Double(source.height) * scale))
        let rowBytes = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: rowBytes * height)
        let rendered = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var output = [UInt8](repeating: 255, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                let point = grid.sample(x: Double(x) / Double(width - 1), y: Double(y) / Double(height - 1))
                guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { continue }
                let sx = point.x * Double(width - 1), sy = point.y * Double(height - 1)
                let x0 = Int(sx), y0 = Int(sy)
                let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
                let dx = sx - Double(x0), dy = sy - Double(y0)
                let out = y * rowBytes + x * 4
                for channel in 0..<3 {
                    let a = Double(pixels[y0 * rowBytes + x0 * 4 + channel])
                    let b = Double(pixels[y0 * rowBytes + x1 * 4 + channel])
                    let c = Double(pixels[y1 * rowBytes + x0 * 4 + channel])
                    let d = Double(pixels[y1 * rowBytes + x1 * 4 + channel])
                    output[out + channel] = UInt8(max(0, min(255,
                        ((a * (1 - dx) + b * dx) * (1 - dy) + (c * (1 - dx) + d * dx) * dy).rounded())))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: rowBytes, space: colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: result)
    }
}
