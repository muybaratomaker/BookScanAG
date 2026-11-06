import Foundation
import Combine
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum ScanVariant: String, Codable, CaseIterable, Identifiable {
    case original, cropped, corrected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Originale"
        case .cropped: return "Ritagliata"
        case .corrected: return "Corretta"
        }
    }
}

enum ScanPageStatus: String, Codable {
    case acquired, processing, ready, review, failed
    var title: String {
        switch self {
        case .acquired: return "Acquisita"
        case .processing: return "In elaborazione"
        case .ready: return "Pronta"
        case .review: return "Da controllare"
        case .failed: return "Non elaborabile"
        }
    }
}

struct ScanPage: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    var selectedVariant: ScanVariant = .original
    var status: ScanPageStatus = .acquired
    var message = ""
    var hasCropped = false
    var hasCorrected = false
    var cropRect: CGRect?
    var proposedContour: [CGPoint] = []

    var variants: [ScanVariant] {
        [.original] + (hasCropped ? [.cropped] : []) + (hasCorrected ? [.corrected] : [])
    }
}

enum ScanStorageError: LocalizedError {
    case missingPage, invalidVariant, invalidImage
    var errorDescription: String? {
        switch self {
        case .missingPage: return "Pagina non disponibile nella sessione."
        case .invalidVariant: return "Questa versione della pagina non è disponibile."
        case .invalidImage: return "Il file fotografico non è leggibile."
        }
    }
}

/// Only small metadata is resident in memory. The camera bytes are never
/// overwritten by crop/dewarp operations. One directory belongs to each page.
@MainActor
final class ScanSessionStore: ObservableObject {
    @Published private(set) var pages: [ScanPage] = []
    @Published var errorMessage: String?
    private let root: URL
    private var writable = false
    private var manifestURL: URL { root.appendingPathComponent("session.json") }

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask)[0]
            .appendingPathComponent("BookScanAG/Session", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excludedRoot = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedRoot.setResourceValues(values)
            try restore()
            writable = true
        } catch {
            // In particular, never overwrite an unreadable existing manifest.
            errorMessage = "Sessione: \(error.localizedDescription)"
        }
    }

    func url(for page: ScanPage, variant: ScanVariant) -> URL? {
        guard page.variants.contains(variant) else { return nil }
        return pageDirectory(page.id).appendingPathComponent(filename(variant))
    }

    func thumbnailURL(for page: ScanPage) -> URL {
        pageDirectory(page.id).appendingPathComponent("thumb-\(page.selectedVariant.rawValue).jpg")
    }

    func addOriginal(_ data: Data) async throws -> ScanPage {
        guard writable else { throw ScanStorageError.missingPage }
        let page = ScanPage()
        let directory = pageDirectory(page.id)
        let original = directory.appendingPathComponent(filename(.original))
        let thumbnail = directory.appendingPathComponent("thumb-original.jpg")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Save before decoding: even an unusual/corrupt photo remains recoverable.
            try data.write(to: original, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? Self.writeThumbnail(data, to: thumbnail)
        }.value
        let updated = pages + [page]
        try persist(updated)
        pages = updated
        return page
    }

    func saveVariant(_ data: Data, for pageID: UUID, variant: ScanVariant) async throws {
        guard writable else { throw ScanStorageError.missingPage }
        guard variant != .original else { throw ScanStorageError.invalidVariant }
        guard pages.contains(where: { $0.id == pageID }) else { throw ScanStorageError.missingPage }
        let target = pageDirectory(pageID).appendingPathComponent(filename(variant))
        let thumbnail = pageDirectory(pageID).appendingPathComponent("thumb-\(variant.rawValue).jpg")
        try await Task.detached(priority: .userInitiated) {
            guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw ScanStorageError.invalidImage }
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? Self.writeThumbnail(data, to: thumbnail)
        }.value
        guard var page = pages.first(where: { $0.id == pageID }) else { throw ScanStorageError.missingPage }
        if variant == .cropped { page.hasCropped = true }
        if variant == .corrected { page.hasCorrected = true }
        try update(page)
    }

    func update(_ page: ScanPage) throws {
        guard writable else { throw ScanStorageError.missingPage }
        guard let index = pages.firstIndex(where: { $0.id == page.id }) else { throw ScanStorageError.missingPage }
        guard page.variants.contains(page.selectedVariant) else { throw ScanStorageError.invalidVariant }
        var updated = pages
        updated[index] = page
        try persist(updated)
        pages = updated
    }

    func select(_ variant: ScanVariant, for pageID: UUID) throws {
        guard var page = pages.first(where: { $0.id == pageID }) else { throw ScanStorageError.missingPage }
        guard page.variants.contains(variant) else { throw ScanStorageError.invalidVariant }
        page.selectedVariant = variant
        try update(page)
    }

    func removeLast() throws {
        guard writable else { throw ScanStorageError.missingPage }
        guard let last = pages.last else { return }
        let directory = pageDirectory(last.id)
        let trash = root.appendingPathComponent(".trash-\(last.id.uuidString)")
        let exists = FileManager.default.fileExists(atPath: directory.path)
        if exists { try FileManager.default.moveItem(at: directory, to: trash) }
        do {
            let updated = Array(pages.dropLast())
            try persist(updated)
            pages = updated
        } catch {
            if exists { try? FileManager.default.moveItem(at: trash, to: directory) }
            throw error
        }
        if exists { try FileManager.default.removeItem(at: trash) }
    }

    func clear() throws {
        while !pages.isEmpty { try removeLast() }
    }

    private func filename(_ variant: ScanVariant) -> String {
        variant == .original ? "original.source" : "\(variant.rawValue).png"
    }

    private func pageDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func persist(_ updated: [ScanPage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(to: manifestURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func restore() throws {
        var restored: [ScanPage] = []
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            do { restored = try JSONDecoder().decode([ScanPage].self, from: data) }
            catch {
                let backup = root.appendingPathComponent("session-corrupt-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: manifestURL, to: backup)
                errorMessage = "Indice non leggibile: originali recuperati. L'indice precedente è conservato."
            }
        }
        // A crash between moving a deleted page aside and committing the index
        // must not strand an original still referenced by the old index.
        for page in restored {
            let directory = pageDirectory(page.id)
            let trash = root.appendingPathComponent(".trash-\(page.id.uuidString)")
            if !FileManager.default.fileExists(atPath: directory.path),
               FileManager.default.fileExists(atPath: trash.path) {
                try FileManager.default.moveItem(at: trash, to: directory)
            }
        }
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  !restored.contains(where: { $0.id == id }),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("original.source").path) else { continue }
            var page = ScanPage()
            page.id = id
            page.createdAt = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            page.status = .review
            page.message = "Originale recuperato dopo un'interruzione."
            restored.append(page)
        }
        restored.sort { $0.createdAt < $1.createdAt }
        for index in restored.indices {
            let directory = pageDirectory(restored[index].id)
            restored[index].hasCropped = FileManager.default.fileExists(atPath: directory.appendingPathComponent("cropped.png").path)
            restored[index].hasCorrected = FileManager.default.fileExists(atPath: directory.appendingPathComponent("corrected.png").path)
            if !restored[index].variants.contains(restored[index].selectedVariant) {
                restored[index].selectedVariant = .original
            }
            if restored[index].status == .processing || restored[index].status == .acquired {
                restored[index].status = .review
                restored[index].message = "Elaborazione interrotta: originale conservato."
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("original.source").path) {
                restored[index].status = .failed
                restored[index].message = "File originale assente: verifica le copie disponibili."
            }
        }
        try persist(restored)
        pages = restored
    }

    nonisolated private static func writeThumbnail(_ data: Data, to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ScanStorageError.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScanStorageError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanStorageError.invalidImage }
        try (encoded as Data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
