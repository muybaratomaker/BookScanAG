import UIKit
import ImageIO

enum ScanMode: String, CaseIterable, Identifiable {
    case single, book
    var id: String { rawValue }
    var title: String { self == .single ? "Pagina singola" : "Libro aperto (2 pagine)" }
}

struct ScanProcessingOptions {
    var automatic = true
    var dewarp = false
    var zone = CGRect(x: 0.075, y: 0.10, width: 0.85, height: 0.80)
    var margin = 0.03
    var mode: ScanMode = .single
    /// Explicit user placement, never a fabricated detection.
    var seamTop: Double?
    var seamBottom: Double?
}

struct ProcessedCapture {
    let pages: [ProcessedScan] // Always left then right, independent of later file writes.
    let seam: [CGPoint]
    let bounds: CGRect
}

/// Work is serialized and originals remain immutable. Coordinates are top-left,
/// relative to the EXIF-normalized full photograph, never the preview layer.
final class ScanProcessingPipeline {
    private let queue = DispatchQueue(label: "bookscan.processing", qos: .userInitiated)
    private let segmentation = PageSegmentationService()
    private let dewarper = PageDewarpService()

    func process(originalURL: URL, options: ScanProcessingOptions) async throws -> ProcessedScan {
        let result = try await processCapture(originalURL: originalURL, options: options)
        guard let page = result.pages.first else { throw ScanProcessingError.invalidCrop }
        return page
    }

    func processCapture(originalURL: URL, options: ScanProcessingOptions) async throws -> ProcessedCapture {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try autoreleasepool {
                        try self.processSynchronously(originalURL: originalURL, options: options)
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func processSynchronously(originalURL: URL, options: ScanProcessingOptions) throws -> ProcessedCapture {
        guard let image = ScanImageIO.load(originalURL, maxPixelSize: options.mode == .book ? 4200 : 2600),
              let cg = image.cgImage else { throw ScanProcessingError.unreadable }
        let detection = options.automatic ? segmentation.detect(image: image) : nil
        if options.mode == .book {
            let spread: ScanSpreadGeometry.Spread?
            if let top = options.seamTop, let bottom = options.seamBottom {
                spread = ScanSpreadGeometry.manual(bounds: options.zone, seamTop: top, seamBottom: bottom)
            } else {
                spread = options.automatic ? segmentation.detectSpread(image: image) : nil
            }
            if let spread {
                let manual = options.seamTop != nil
                let review = !manual && spread.needsReview
                let message = review ? "Due pagine proposte: controlla rilegatura e margini prima del PDF." : "Libro separato: sinistra, poi destra."
                let pages = try [spread.left, spread.right].map { region -> ProcessedScan in
                    let pixels = ScanSpreadGeometry.cropBounds(region: region, margin: options.margin,
                        imageSize: CGSize(width: cg.width, height: cg.height))
                    let safe = CGRect(x: pixels.minX / CGFloat(cg.width), y: pixels.minY / CGFloat(cg.height),
                                      width: pixels.width / CGFloat(cg.width), height: pixels.height / CGFloat(cg.height))
                    return try render(image: image, safe: safe, review: review, useOriginal: false,
                                      dewarp: options.dewarp && !review, message: message)
                }
                return ProcessedCapture(pages: pages, seam: spread.seam,
                                        bounds: spread.left.bounds.union(spread.right.bounds))
            }
            // No evidence for two pages: keep ONE photograph. Splitting is an explicit review action.
            let full = CGRect(x: 0, y: 0, width: 1, height: 1)
            let page = try render(image: image, safe: full, review: true, useOriginal: true, dewarp: false,
                message: "Non distinguo due pagine. Foto intera conservata: regola la rilegatura in Controlla pagina, oppure conferma una sola pagina.")
            return ProcessedCapture(pages: [page], seam: [], bounds: detection?.bounds ?? options.zone)
        }
        let trusted = detection.map { ScanQualityEvaluator.canAutomaticallyCrop($0) } ?? false
        let hasProposal = detection != nil
        let zone = options.automatic ? (detection?.bounds ?? options.zone) : options.zone
        let safe = FixedCrop.expanded(zone, margin: options.margin)
        let review = options.automatic && !trusted
        // A detected crop is now the visible candidate, not silently replaced by the original.
        // Uncertain candidates cannot export without explicit review in the UI.
        let message = options.automatic
            ? (trusted ? "Ritaglio rilevato applicato." : (hasProposal ? "Ritaglio proposto da controllare prima del PDF." : "Pagina non riconosciuta: regola il ritaglio o conferma l'originale."))
            : "Ritaglio manuale applicato."
        let page = try render(image: image, safe: safe, review: review,
                              useOriginal: options.automatic && !hasProposal,
                              dewarp: options.dewarp && !review, message: message)
        return ProcessedCapture(pages: [page], seam: [], bounds: safe)
    }

    private func render(image: UIImage, safe: CGRect, review: Bool, useOriginal: Bool,
                        dewarp: Bool, message: String) throws -> ProcessedScan {
        guard let cg = image.cgImage, !safe.isNull, safe.width > 0.01, safe.height > 0.01 else {
            throw ScanProcessingError.invalidCrop
        }
        let pixels = CropCoordinates.pixels(for: safe, imageSize: CGSize(width: cg.width, height: cg.height))
        guard let croppedCG = cg.cropping(to: pixels) else { throw ScanProcessingError.invalidCrop }
        let cropped = UIImage(cgImage: croppedCG)
        guard let data = cropped.pngData() else { throw ScanProcessingError.encoding }
        var correction: Data?
        var text = message
        if dewarp {
            let result = dewarper.correct(cropped)
            if result.applied { correction = result.image?.pngData() }
            text += " " + result.message
        }
        let actual = CGRect(x: pixels.minX / CGFloat(cg.width), y: pixels.minY / CGFloat(cg.height),
                            width: pixels.width / CGFloat(cg.width), height: pixels.height / CGFloat(cg.height))
        return ProcessedScan(cropped: data, corrected: correction,
            selectedVariant: useOriginal ? .original : (correction == nil ? .cropped : .corrected),
            status: review ? .review : .ready, message: text, cropRect: actual,
            contour: CropCoordinates.corners(actual))
    }
}

enum ScanProcessingError: LocalizedError {
    case unreadable, invalidCrop, encoding
    var errorDescription: String? {
        switch self {
        case .unreadable: return "Impossibile leggere la foto; l'originale resta nella sessione."
        case .invalidCrop: return "Ritaglio non valido; l'originale resta nella sessione."
        case .encoding: return "Impossibile salvare la pagina elaborata; l'originale resta nella sessione."
        }
    }
}

enum ScanImageIO {
    static func load(_ url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

enum FixedCrop {
    static func expanded(_ rect: CGRect, margin: Double) -> CGRect {
        CropCoordinates.expanded(rect, margin: margin)
    }
}
