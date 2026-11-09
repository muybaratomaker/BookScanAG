import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Classical, image-based gutter estimation. It is not a two-page neural model.
/// All coordinates use the upright photograph, normalized with a top-left origin.
enum ScanSpreadGeometry {
    struct Region {
        let bounds: CGRect
        let contour: [CGPoint]
        let isLeft: Bool
    }
    struct Spread {
        let left: Region
        let right: Region
        let seam: [CGPoint]
        let confidence: Double
        let needsReview: Bool
    }

    static func detect(rgba: [UInt8], width: Int, height: Int,
                       surface: ScanGeometry.Surface? = nil) -> Spread? {
        guard width >= 80, height >= 80, rgba.count == width * height * 4 else { return nil }
        let gray = stride(from: 0, to: rgba.count, by: 4).map {
            0.299 * Double(rgba[$0]) + 0.587 * Double(rgba[$0 + 1]) + 0.114 * Double(rgba[$0 + 2])
        }
        let sorted = gray.sorted()
        let paper = sorted[sorted.count * 3 / 4]
        guard paper > 120 else { return nil }
        let threshold = max(100, paper - 40)
        // Row envelopes deliberately bridge an internal dark gutter, unlike a single
        // connected component that may return only one half of an open book.
        let table = ScanGeometry.summedArea(gray.map { $0 >= threshold ? 1 : 0 }, width: width, height: height)
        let radius = max(2, width / 70)
        var envelopes: [(y: Int, left: Int, right: Int)] = []
        for y in 0..<height {
            var hits: [Int] = []
            for x in radius..<(width - radius) {
                let x0 = x - radius, x1 = x + radius + 1
                let y0 = max(0, y - 1), y1 = min(height, y + 2)
                let fraction = ScanGeometry.sum(table, width: width, x0: x0, y0: y0, x1: x1, y1: y1) / Double((x1 - x0) * (y1 - y0))
                if fraction >= 0.70 { hits.append(x) }
            }
            if let left = hits.first, let right = hits.last, right - left >= width / 3 {
                envelopes.append((y, left, right))
            }
        }
        var groups: [[(y: Int, left: Int, right: Int)]] = []
        for row in envelopes {
            if let last = groups.last?.last, row.y - last.y <= max(3, height / 30) {
                groups[groups.count - 1].append(row)
            } else { groups.append([row]) }
        }
        guard let rows = groups.max(by: { $0.count < $1.count }), rows.count >= height / 3,
              let first = rows.first, let last = rows.last else { return nil }
        // Preserve every observed outer extent; percentiles can cut bowed text.
        let left = rows.map(\.left).min()!
        let right = rows.map(\.right).max()!
        let top = first.y, bottom = last.y
        let span = right - left
        guard span >= width / 3, bottom - top >= height / 3 else { return nil }
        // Reject featureless/full-frame paper and backgrounds without two visible surfaces.
        // A clipped outer edge remains a review case if the gutter evidence is strong.
        let searchStart = left + span / 5, searchEnd = right - span / 5
        let flank = max(5, span / 12), gutterRadius = max(1, span / 150)
        var observations: [(x: Double, y: Double, score: Double)] = []
        var ambiguous = 0
        for band in 0..<9 {
            let y0 = top + (bottom - top) * (band + 1) / 11
            let y1 = top + (bottom - top) * (band + 2) / 11
            guard y1 > y0 else { continue }
            var scores: [(x: Int, score: Double)] = []
            for x in searchStart...searchEnd {
                var center = 0.0, l = 0.0, r = 0.0
                for y in y0..<y1 {
                    for d in -gutterRadius...gutterRadius {
                        center += gray[y * width + x + d]
                        l += gray[y * width + x - flank + d]
                        r += gray[y * width + x + flank + d]
                    }
                }
                let divisor = Double((y1 - y0) * (2 * gutterRadius + 1))
                center /= divisor; l /= divisor; r /= divisor
                let score = min(l, r) - center
                if min(l, r) >= threshold - 15 { scores.append((x, score)) }
            }
            guard let best = scores.max(by: { $0.score < $1.score }), best.score >= 22 else { continue }
            if let rival = scores.filter({ abs($0.x - best.x) > flank }).map(\.score).max(), rival > best.score * 0.85 {
                ambiguous += 1
            }
            observations.append((Double(best.x), Double(y0 + y1) / 2, best.score))
        }
        // A persistent gutter, not merely a dark word or a page edge, must appear
        // in at least seven vertical bands with bright paper on both sides.
        guard observations.count >= 7, ambiguous <= 2 else { return nil }
        let meanX = observations.map(\.x).reduce(0, +) / Double(observations.count)
        let meanY = observations.map(\.y).reduce(0, +) / Double(observations.count)
        let denominator = observations.reduce(0) { $0 + pow($1.y - meanY, 2) }
        guard denominator > 0 else { return nil }
        let slope = observations.reduce(0) { $0 + ($1.y - meanY) * ($1.x - meanX) } / denominator
        let residual = observations.map { abs($0.x - (meanX + slope * ($0.y - meanY))) }.max() ?? .infinity
        guard residual <= max(3, Double(span) * 0.025), abs(slope) < 0.25 else { return nil }
        let seamTop = (meanX + slope * (Double(top) - meanY)) / Double(width)
        let seamBottom = (meanX + slope * (Double(bottom + 1) - meanY)) / Double(width)
        let bounds = CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height),
                            width: Double(span + 1) / Double(width), height: Double(bottom - top + 1) / Double(height))
        guard let split = manual(bounds: bounds, seamTop: seamTop, seamBottom: seamBottom) else { return nil }
        // Validate both halves contain substantial light surface, rather than creating
        // a second output when only one page is in view.
        for region in [split.left, split.right] {
            let x0 = max(0, Int(region.bounds.minX * Double(width)))
            let x1 = min(width, Int(region.bounds.maxX * Double(width)))
            let count = ScanGeometry.sum(table, width: width, x0: x0, y0: top, x1: x1, y1: bottom + 1)
            guard count / Double(max(1, (x1 - x0) * (bottom - top + 1))) >= 0.62 else { return nil }
        }
        let clipped = left <= radius + 1 || right >= width - radius - 2 || top <= 1 || bottom >= height - 2
        let confidence = min(0.95, 0.64 + Double(observations.count) * 0.025 - residual / Double(span) - Double(ambiguous) * 0.06)
        // Preserve varying outer contours; the enclosing rectangles do not cut off bowed text.
        let sampled = rows.enumerated().filter { $0.offset % max(1, rows.count / 24) == 0 }.map(\.element)
        let leftContour = sampled.map { CGPoint(x: Double($0.left) / Double(width), y: Double($0.y) / Double(height)) }
            + split.seam.reversed()
        let rightContour = split.seam + sampled.reversed().map { CGPoint(x: Double($0.right + 1) / Double(width), y: Double($0.y + 1) / Double(height)) }
        return Spread(left: Region(bounds: split.left.bounds, contour: leftContour, isLeft: true),
                      right: Region(bounds: split.right.bounds, contour: rightContour, isLeft: false),
                      seam: split.seam, confidence: confidence, needsReview: clipped || confidence < 0.80)
    }

    /// Explicit user-chosen fallback. Calling this does not claim two pages were detected.
    static func manual(bounds: CGRect, seamTop: Double, seamBottom: Double) -> Spread? {
        let b = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.2, b.height > 0.2, seamTop.isFinite, seamBottom.isFinite,
              min(seamTop, seamBottom) > b.minX + b.width * 0.15,
              max(seamTop, seamBottom) < b.maxX - b.width * 0.15 else { return nil }
        let seam = [CGPoint(x: seamTop, y: b.minY), CGPoint(x: seamBottom, y: b.maxY)]
        // Enclosing rectangles plus a tiny overlap preserve all visible text at a tilted
        // binding. Do not crop each half to the average seam, which would cut letters.
        let overlap = min(0.004, b.width * 0.006)
        let lx = min(b.maxX, max(seamTop, seamBottom) + overlap)
        let rx = max(b.minX, min(seamTop, seamBottom) - overlap)
        let l = CGRect(x: b.minX, y: b.minY, width: lx - b.minX, height: b.height)
        let r = CGRect(x: rx, y: b.minY, width: b.maxX - rx, height: b.height)
        return Spread(left: Region(bounds: l, contour: [CGPoint(x: b.minX, y: b.minY)] + seam + [CGPoint(x: b.minX, y: b.maxY)], isLeft: true),
                      right: Region(bounds: r, contour: [seam[0], CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), seam[1]], isLeft: false),
                      seam: seam, confidence: 0, needsReview: true)
    }

    /// Margin grows only outwards at the gutter. Returns an integral, clipped pixel rect.
    static func cropBounds(region: Region, margin: Double, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .null }
        let b = region.bounds
        guard !b.isNull, b.width > 0, b.height > 0,
              [b.minX, b.minY, b.width, b.height, imageSize.width, imageSize.height].allSatisfy({ $0.isFinite }),
              margin.isFinite else { return .null }
        var expanded = b.insetBy(dx: -b.width * max(0, margin), dy: -b.height * max(0, margin))
        if region.isLeft { expanded.size.width = b.maxX - expanded.minX }
        else { expanded.origin.x = b.minX; expanded.size.width = b.width * (1 + max(0, margin)) }
        let safe = expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGRect(x: safe.minX * imageSize.width, y: safe.minY * imageSize.height,
                      width: safe.width * imageSize.width, height: safe.height * imageSize.height)
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
}
