import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ScanStyle: String, CaseIterable, Identifiable {
    case natural, optimized, scanner, blackWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "Naturale"
        case .optimized: return "Ottimizzato"
        case .scanner: return "Scanner"
        case .blackWhite: return "Bianco e nero"
        }
    }
    var description: String {
        switch self {
        case .natural: return "Grigi naturali, contrasto delicato."
        case .optimized: return "Sfondo più chiaro e testo ben contrastato."
        case .scanner: return "Bianco uniforme e ombre attenuate: ideale per pagine di libri."
        case .blackWhite: return "Contrasto forte; verifica i caratteri sottili prima di esportare."
        }
    }
}

enum DocumentProfile: String, CaseIterable, Identifiable {
    case compact
    case readable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: return "Documento leggero"
        case .readable: return "Testo piccolo"
        }
    }
    var longEdge: Int { self == .compact ? 1500 : 1700 }
    var jpegQuality: CGFloat { self == .compact ? 0.54 : 0.68 }
    var contrast: CGFloat { self == .compact ? 1.14 : 1.09 }
    var brightness: CGFloat { self == .compact ? 0.025 : 0.01 }
}


enum DocumentRendering {
    // Decode only the target resolution, preserving EXIF orientation. Each export
    // starts from a lossless working variant (or the unchanged camera original).
    private static let context = CIContext()

    static func render(_ sourceData: Data, profile: DocumentProfile, style: ScanStyle) -> Data? {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: profile.longEdge,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        var ci = CIImage(cgImage: cg)
        // Preserve the established four document looks; no division by a blurred
        // background, which previously erased thin letter strokes.
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        switch style {
        case .natural:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.06, kCIInputBrightnessKey: 0.008])
        case .optimized:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.16, kCIInputBrightnessKey: 0.035])
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.25])
        case .scanner:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.30, kCIInputBrightnessKey: 0.025])
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.22])
        case .blackWhite:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.65, kCIInputBrightnessKey: 0.06])
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
        }
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: ci.extent)
        ci = ci.composited(over: background)
        guard let result = context.createCGImage(ci, from: ci.extent,
                                                format: .RGBA8,
                                                colorSpace: CGColorSpaceCreateDeviceRGB()) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, result, [
            kCGImageDestinationLossyCompressionQuality: profile.jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
