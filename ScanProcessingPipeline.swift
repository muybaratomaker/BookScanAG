import UIKit
import ImageIO

struct ScanProcessingOptions {
    var automatic = true
    var dewarp = false
    var zone = CGRect(x: 0.075, y: 0.10, width: 0.85, height: 0.80)
    var margin = 0.07
}

struct ProcessedScan {
    let cropped: Data
    let corrected: Data?
    let selectedVariant: ScanVariant
    let status: ScanPageStatus
    let message: String
    let cropRect: CGRect
    let contour: [CGPoint]
}

/// One serial work queue bounds memory to a single page. Originals remain byte-for-byte on disk.
final class ScanProcessingPipeline {
    private let queue = DispatchQueue(label: "bookscan.processing", qos: .userInitiated)
    private let segmentation = PageSegmentationService()
    private let dewarper = PageDewarpService()

    func process(originalURL: URL, options: ScanProcessingOptions) async throws -> ProcessedScan {
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

    private func processSynchronously(originalURL: URL, options: ScanProcessingOptions) throws -> ProcessedScan {
        guard let image = ScanImageIO.load(originalURL, maxPixelSize: 2600), let cg = image.cgImage else {
            throw ScanProcessingError.unreadable
        }
        let detection = options.automatic ? segmentation.detect(image: image) : nil
        let trusted = detection.map { !$0.needsReview } ?? false
        // Uncertain automatic detection proposes a crop but exports the full photograph until reviewed.
        let zone = options.automatic ? (detection?.bounds ?? options.zone) : options.zone
        let safe = FixedCrop.expanded(zone, margin: options.margin)
        guard !safe.isNull, safe.width > 0.01, safe.height > 0.01 else { throw ScanProcessingError.invalidCrop }
        let pixels = CGRect(x: safe.minX * CGFloat(cg.width), y: safe.minY * CGFloat(cg.height),
                            width: safe.width * CGFloat(cg.width), height: safe.height * CGFloat(cg.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let croppedCG = cg.cropping(to: pixels) else { throw ScanProcessingError.invalidCrop }
        let cropped = UIImage(cgImage: croppedCG)
        guard let data = cropped.pngData() else { throw ScanProcessingError.encoding }
        var correction: Data?
        var message = options.automatic ? (trusted ? "Superficie individuata. Verifica i margini." : "Contorno incerto: conservata la fotografia intera. Controlla il ritaglio.") : "Ritaglio manuale applicato."
        if options.dewarp && (!options.automatic || trusted) {
            let result = dewarper.correct(cropped)
            if result.applied { correction = result.image?.pngData() }
            message += " " + result.message
        }
        let needsReview = options.automatic && !trusted
        return ProcessedScan(cropped: data, corrected: correction,
                             selectedVariant: needsReview ? .original : (correction == nil ? .cropped : .corrected),
                             status: needsReview ? .review : .ready, message: message,
                             cropRect: safe, contour: detection?.contour ?? [])
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
        rect.insetBy(dx: -rect.width * margin, dy: -rect.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
