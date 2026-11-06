import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared conservative acceptance rules. An uncertain proposal is displayed for review,
/// never silently promoted to the crop just because a contour exists.
enum ScanQualityEvaluator {
    static func canAutomaticallyCrop(_ result: PageSegmentationResult) -> Bool {
        !result.needsReview && result.confidence >= 0.80 && result.clippedEdges.isEmpty
            && result.bounds.width >= 0.25 && result.bounds.height >= 0.25
            && result.bounds.width * result.bounds.height < 0.90
    }

    static func message(for result: PageSegmentationResult?) -> String {
        guard let result else { return "Pagina non riconosciuta · usa il riquadro manuale" }
        if !result.clippedEdges.isEmpty { return "Bordi fuori inquadratura · da controllare" }
        return canAutomaticallyCrop(result) ? "Superficie individuata" : "Contorno incerto · da controllare"
    }
}
