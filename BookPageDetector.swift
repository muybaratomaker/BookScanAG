import UIKit
import CoreImage
import CoreVideo

// Experimental bright-paper detector for an open book against a darker background.
// All coordinates are normalized, top-left origin. Does NOT claim to flatten curvature.
enum BookPageDetector {
    struct Result {
        let pages: [LivePage]
        let split: CGFloat
    }

    static func detect(pixelBuffer: CVPixelBuffer) -> Result? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return detect(ciImage: ci, context: context)
    }

    static func detect(image: UIImage) -> Result? {
        guard let cg = image.cgImage else { return nil }
        return detect(ciImage: CIImage(cgImage: cg), context: CIContext())
    }

    private static func detect(ciImage: CIImage, context: CIContext) -> Result? {
        let width = 192, height = 256
        let source = ciImage.extent
        guard source.width > 0, source.height > 0 else { return nil }
        let transformed = ciImage.transformed(by:
            CGAffineTransform(translationX: -source.minX, y: -source.minY)
                .scaledBy(x: CGFloat(width) / source.width,
                          y: CGFloat(height) / source.height))
        let rgb = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                context.render(transformed, toBitmap: base,
                               rowBytes: width * 4,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height),
                               format: .RGBA8, colorSpace: rgb)
            }
        }

        // CIImage rows are bottom-to-top. Convert explicitly to top-left coordinates.
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = ((height - 1 - y) * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i+1]), Int(bytes[i+2]))
        }
        func isPaper(_ x: Int, _ y: Int) -> Bool {
            let (r,g,b) = pixel(x,y)
            let mx = max(r,max(g,b)), mn = min(r,min(g,b))
            // Warm/gray paper under ordinary room lighting.
            return (r+g+b) / 3 >= 145 && mx-mn <= 90
        }

        // Use only rows with long, mostly continuous light spans crossing
        // the central gutter; isolated keys and light desk are rejected by
        // requiring repeated evidence through the book's central height.
        var rows: [(y: Int, left: Int, right: Int)] = []
        let mid = width / 2
        for y in 12..<(height - 12) {
            let leftStart = max(0, mid - 12)
            let rightEnd = min(width-1, mid + 12)
            let centerHits = (leftStart...rightEnd).reduce(0) {
                $0 + (isPaper($1,y) ? 1 : 0)
            }
            guard centerHits >= 15 else { continue }
            var left = mid, right = mid
            var gap = 0
            for x in stride(from: mid, through: 3, by: -1) {
                gap = isPaper(x,y) ? 0 : gap + 1
                if gap >= 7 { break }
                left = x
            }
            gap = 0
            for x in mid..<(width-3) {
                gap = isPaper(x,y) ? 0 : gap + 1
                if gap >= 7 { break }
                right = x
            }
            if left < width / 3 && right > width * 2 / 3 {
                rows.append((y,left,right))
            }
        }
        guard rows.count >= 65 else { return nil }
        // Largest uninterrupted run, allowing a few missing scanlines.
        var groups: [[(y: Int, left: Int, right: Int)]] = []
        for row in rows {
            if let last = groups.last?.last, row.y - last.y <= 4 {
                groups[groups.count-1].append(row)
            } else { groups.append([row]) }
        }
        guard let main = groups.max(by: { $0.count < $1.count }),
              main.count >= 60,
              let first = main.first, let last = main.last else { return nil }
        let top = CGFloat(first.y) / CGFloat(height)
        let bottom = CGFloat(last.y) / CGFloat(height)
        guard bottom-top >= 0.30 else { return nil }
        let leftValues = main.map { $0.left }.sorted()
        let rightValues = main.map { $0.right }.sorted()
        // Robust percentiles avoid the hand and isolated background.
        let left = CGFloat(leftValues[leftValues.count / 4]) / CGFloat(width)
        let right = CGFloat(rightValues[rightValues.count * 3 / 4]) / CGFloat(width)
        guard left < 0.32, right > 0.68 else { return nil }
        let seam: CGFloat = 0.5
        let inset: CGFloat = 0.007
        func quad(_ l: CGFloat, _ r: CGFloat) -> LivePage {
            LivePage(points: [
                CGPoint(x:l, y:top), CGPoint(x:r, y:top),
                CGPoint(x:r, y:bottom), CGPoint(x:l, y:bottom)
            ])
        }
        return Result(pages: [quad(left, seam-inset), quad(seam+inset, right)],
                      split: seam)
    }
}
