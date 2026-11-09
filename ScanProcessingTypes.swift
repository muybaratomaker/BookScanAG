import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct ProcessedScan {
    let cropped: Data
    let corrected: Data?
    let selectedVariant: ScanVariant
    let status: ScanPageStatus
    let message: String
    let cropRect: CGRect
    let contour: [CGPoint]
}
