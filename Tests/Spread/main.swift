import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
var tests = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    tests += 1
    precondition(value(), message)
    print("PASS: \(message)")
}
let width = 320, height = 240
func book(seam: Double = 0.5, slope: Double = 0, gutter: Bool = true, single: Bool = false) -> [UInt8] {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        var value: UInt8 = 55
        if y >= 20 && y < 220 && x >= 24 && x < (single ? 160 : 296) {
            value = 235
            if gutter && abs(Double(x) - (seam * Double(width) + slope * Double(y - 120))) < 3 { value = 65 }
            else if y % 17 < 2 && x % 60 > 8 { value = 80 }
        }
        for c in 0..<3 { bytes[(y * width + x) * 4 + c] = value }
    }}
    return bytes
}
func detect(_ input: [UInt8]) -> ScanSpreadGeometry.Spread? {
    ScanSpreadGeometry.detect(rgba: input, width: width, height: height)
}
let centered = detect(book())
check(centered != nil, "Centered spread detected")
check(abs(centered!.seam[0].x - 0.5) < 0.02, "Centered gutter estimated from pixels")
let offset = detect(book(seam: 0.42))
check(offset != nil, "Off-center spread detected")
check(abs(offset!.seam[0].x - 0.42) < 0.02, "Off-center seam is not forced to 50 percent")
check(offset!.left.bounds.width < offset!.right.bounds.width, "Unequal page widths retained")
let tilted = detect(book(seam: 0.46, slope: 0.08))
check(tilted != nil, "Tilted gutter detected")
check(tilted!.seam[1].x > tilted!.seam[0].x + 0.03, "Tilted seam direction preserved")
check(detect(book(gutter: false)) == nil, "No confident gutter means no fabricated second page")
check(detect(book(single: true)) == nil, "Single visible page rejected as spread")
check(detect([UInt8](repeating: 235, count: width * height * 4)) == nil, "Uniform surface rejected")
check(detect([]) == nil, "Malformed raster rejected")
let fallback = ScanSpreadGeometry.manual(bounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), seamTop: 0.4, seamBottom: 0.47)!
check(fallback.needsReview, "Manual split is marked for review")
check(fallback.left.bounds.maxX >= 0.47 && fallback.right.bounds.minX <= 0.4, "Slanted inner edges preserved by conservative overlap")
check(ScanSpreadGeometry.manual(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), seamTop: 0.01, seamBottom: 0.5) == nil, "Invalid manual divider rejected")
for size in [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000)] {
    let a = ScanSpreadGeometry.cropBounds(region: fallback.left, margin: 0.05, imageSize: size)
    let b = ScanSpreadGeometry.cropBounds(region: fallback.right, margin: 0.05, imageSize: size)
    check(a.maxX <= ceil(fallback.left.bounds.maxX * size.width), "Margin does not grow into opposite page")
    check(b.minX >= floor(fallback.right.bounds.minX * size.width), "Right gutter does not grow into opposite page")
    check(a.minX < fallback.left.bounds.minX * size.width && b.maxX > fallback.right.bounds.maxX * size.width, "Margins expand outer page edges")
    check(a.minY == floor(0.06 * size.height), "Normalized crop maps to actual photograph dimensions")
}
// A short bowed outer edge must remain in the saved crop, even when it occupies
// less than 10 percent of the rows (the previous percentile bounds lost it).
var bowed = book()
for y in 40..<48 {
    for x in 8..<24 {
        for c in 0..<3 { bowed[(y * width + x) * 4 + c] = 235 }
    }
}
let bowedSpread = detect(bowed)
check(bowedSpread != nil, "Short bowed outer edge keeps spread detectable")
if let spread = bowedSpread {
    check(spread.left.bounds.minX < 15.0 / Double(width), "Crop retains rare outer extent rather than percentile")
    for region in [spread.left, spread.right] {
        let inclusive = region.bounds.insetBy(dx: -0.000001, dy: -0.000001)
        check(region.contour.allSatisfy { inclusive.contains($0) }, "Saved bounds enclose every displayed contour point")
    }
}
print("\(tests) spread checks passed; synthetic fixtures only.")
