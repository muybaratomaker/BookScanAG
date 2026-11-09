import Foundation

struct PDFRaster {
    let jpeg: Data
    let width: Int
    let height: Int
}

enum ScanPDFError: LocalizedError {
    case noPages, unreadablePage(Int), invalidRaster, fileCreation
    var errorDescription: String? {
        switch self {
        case .noPages: return "Nessuna pagina da esportare."
        case .unreadablePage(let number): return "Pagina \(number) non leggibile. PDF non esportato; nessuna pagina è stata saltata."
        case .invalidRaster: return "Immagine PDF non valida."
        case .fileCreation: return "Impossibile creare il PDF."
        }
    }
}

/// A small streaming PDF writer for opaque RGB JPEG pages. It embeds the exact
/// encoded bytes with DCTDecode, so the PDF renderer cannot recompress text.
/// Foundation-only: its page structure and payload identity can be tested on Linux.
enum ScanPDFWriter {
    static func write(pageCount: Int, to url: URL,
                      pageAt: (Int) throws -> PDFRaster) throws {
        guard pageCount > 0 else { throw ScanPDFError.noPages }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ScanPDFError.fileCreation }
        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        var offset: UInt64 = 0
        var offsets = [UInt64](repeating: 0, count: 3 + 3 * pageCount)
        func bytes(_ data: Data) throws {
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
        func text(_ string: String) throws { try bytes(Data(string.utf8)) }
        func object(_ id: Int, _ body: String) throws {
            offsets[id] = offset
            try text("\(id) 0 obj\n\(body)\nendobj\n")
        }
        func decimal(_ value: Double) -> String {
            String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        try text("%PDF-1.4\n%BookScanAG\n")
        try object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        let kids = (0..<pageCount).map { "\(3 + 3 * $0) 0 R" }.joined(separator: " ")
        try object(2, "<< /Type /Pages /Count \(pageCount) /Kids [\(kids)] >>")
        for index in 0..<pageCount {
            // The caller uses autoreleasepool around raster construction; only
            // this page's final JPEG is retained during its streaming write.
            let raster = try pageAt(index)
            guard raster.width > 0, raster.height > 0,
                  raster.jpeg.count > 4,
                  raster.jpeg.prefix(2) == Data([0xFF, 0xD8]),
                  raster.jpeg.suffix(2) == Data([0xFF, 0xD9]) else { throw ScanPDFError.invalidRaster }
            let pageID = 3 + 3 * index, imageID = pageID + 1, contentID = pageID + 2
            try object(pageID, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /XObject << /Im0 \(imageID) 0 R >> >> /Contents \(contentID) 0 R >>")
            offsets[imageID] = offset
            try text("\(imageID) 0 obj\n<< /Type /XObject /Subtype /Image /Width \(raster.width) /Height \(raster.height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(raster.jpeg.count) >>\nstream\n")
            try bytes(raster.jpeg)
            try text("\nendstream\nendobj\n")
            let scale = min(563 / Double(raster.width), 810 / Double(raster.height))
            let width = Double(raster.width) * scale, height = Double(raster.height) * scale
            let command = "q\n\(decimal(width)) 0 0 \(decimal(height)) \(decimal((595 - width) / 2)) \(decimal((842 - height) / 2)) cm\n/Im0 Do\nQ\n"
            try object(contentID, "<< /Length \(command.utf8.count) >>\nstream\n\(command)endstream")
        }
        let xrefOffset = offset
        try text("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for item in offsets.dropFirst() {
            guard item < 10_000_000_000 else { throw ScanPDFError.fileCreation }
            try text(String(format: "%010llu 00000 n \n", item))
        }
        try text("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n")
        try handle.synchronize()
        succeeded = true
    }
}

#if canImport(UIKit)
import UIKit
import ImageIO

enum ScanPDFExporter {
    static func export(pages: [URL], profile: DocumentProfile, style: ScanStyle) throws -> URL {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookScan-\(UUID().uuidString).pdf")
        try ScanPDFWriter.write(pageCount: pages.count, to: target) { index in
            try autoreleasepool {
                guard let sourceData = try? Data(contentsOf: pages[index], options: .mappedIfSafe),
                      let jpeg = DocumentRendering.render(sourceData, profile: profile, style: style),
                      let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    throw ScanPDFError.unreadablePage(index + 1)
                }
                return PDFRaster(jpeg: jpeg, width: width, height: height)
            }
        }
        return target
    }
}
#endif
