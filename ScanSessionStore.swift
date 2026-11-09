import Foundation
import CoreGraphics
import Combine
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
    // Optional fields preserve decoding of pre-spread session manifests.
    var captureID: UUID?
    var spreadSide: String?
    var spreadSeam: [CGPoint]?
    var spreadBounds: CGRect?
    var revision: UUID?

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
    private var siblingOperations = Set<UUID>()
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
            try data.write(to: original, options: Self.protectedWriteOptions)
            try? Self.writeThumbnail(data, to: thumbnail)
        }.value
        let updated = pages + [page]
        try persist(updated)
        pages = updated
        return page
    }

    /// Both entries own a hard link to the same immutable camera file. Removing
    /// either page cannot remove the other's original or duplicate the photo bytes.
    func addSibling(of page: ScanPage) async throws -> ScanPage {
        guard writable, let source = pages.first(where: { $0.id == page.id }) else {
            throw ScanStorageError.missingPage
        }
        let capture = source.captureID ?? source.id
        if let existing = pages.first(where: { $0.captureID == capture && $0.id != source.id }) {
            return existing
        }
        guard !siblingOperations.contains(capture) else { throw ScanStorageError.missingPage }
        siblingOperations.insert(capture)
        defer { siblingOperations.remove(capture) }
        var sibling = ScanPage()
        sibling.captureID = capture
        sibling.spreadSide = "right"
        sibling.spreadSeam = source.spreadSeam
        sibling.spreadBounds = source.spreadBounds
        let directory = pageDirectory(sibling.id)
        let staging = root.appendingPathComponent(".pending-\(sibling.id.uuidString)")
        let sourceDirectory = pageDirectory(source.id)
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                try files.linkItem(at: sourceDirectory.appendingPathComponent("original.source"),
                                   to: staging.appendingPathComponent("original.source"))
                let thumbnail = sourceDirectory.appendingPathComponent("thumb-original.jpg")
                if files.fileExists(atPath: thumbnail.path) {
                    try files.linkItem(at: thumbnail, to: staging.appendingPathComponent("thumb-original.jpg"))
                }
                // If interrupted before the manifest commit, recovery must not
                // expose this uncommitted hard link as a duplicate full photo.
                try Data().write(to: staging.appendingPathComponent(".pending-sibling"))
                try files.moveItem(at: staging, to: directory)
            } catch {
                try? files.removeItem(at: staging)
                throw error
            }
        }.value
        // A deletion can happen while file work is suspended. Never append an
        // orphan sibling to a session whose source page has been removed.
        guard let index = pages.firstIndex(where: { $0.id == source.id }) else {
            try? FileManager.default.removeItem(at: directory)
            throw ScanStorageError.missingPage
        }
        var updated = pages
        updated[index].captureID = capture
        updated[index].spreadSide = "left"
        updated.insert(sibling, at: index + 1)
        do {
            try persist(updated)
            pages = updated
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".pending-sibling"))
        } catch {
            // The source's hard link still owns the original, so this uncommitted
            // sibling can be removed safely rather than recovered as a duplicate.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return sibling
    }

    @discardableResult
    func applyProcessed(_ result: ProcessedScan, to page: ScanPage) async throws -> ScanPage {
        try await saveVariant(result.cropped, for: page.id, variant: .cropped)
        if let corrected = result.corrected {
            try await saveVariant(corrected, for: page.id, variant: .corrected)
        }
        guard var current = pages.first(where: { $0.id == page.id }) else { throw ScanStorageError.missingPage }
        current.hasCropped = true
        current.hasCorrected = result.corrected != nil
        current.selectedVariant = result.selectedVariant
        current.status = result.status
        current.message = result.message
        current.cropRect = result.cropRect
        current.proposedContour = result.contour
        try update(current)
        return pages.first(where: { $0.id == page.id }) ?? current
    }

    /// Commit invalidation first. A leftover file after interruption must never
    /// become a selectable correction of a newer, different crop on restore.
    func discardCorrected(for pageID: UUID) throws {
        guard var page = pages.first(where: { $0.id == pageID }) else { throw ScanStorageError.missingPage }
        page.hasCorrected = false
        if page.selectedVariant == .corrected { page.selectedVariant = page.hasCropped ? .cropped : .original }
        try update(page)
        for name in ["corrected.png", "thumb-corrected.jpg"] {
            let file = pageDirectory(pageID).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    func saveVariant(_ data: Data, for pageID: UUID, variant: ScanVariant) async throws {
        guard writable else { throw ScanStorageError.missingPage }
        guard variant != .original else { throw ScanStorageError.invalidVariant }
        guard pages.contains(where: { $0.id == pageID }) else { throw ScanStorageError.missingPage }
        if variant == .cropped { try discardCorrected(for: pageID) }
        let target = pageDirectory(pageID).appendingPathComponent(filename(variant))
        let thumbnail = pageDirectory(pageID).appendingPathComponent("thumb-\(variant.rawValue).jpg")
        try await Task.detached(priority: .userInitiated) {
            guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw ScanStorageError.invalidImage }
            try data.write(to: target, options: Self.protectedWriteOptions)
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
        updated[index].revision = UUID()
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
        guard let last = pages.last else { return }
        try remove(pageID: last.id)
    }

    func remove(pageID: UUID) throws {
        guard writable, pages.contains(where: { $0.id == pageID }) else { throw ScanStorageError.missingPage }
        let directory = pageDirectory(pageID)
        let trash = root.appendingPathComponent(".trash-\(pageID.uuidString)")
        let exists = FileManager.default.fileExists(atPath: directory.path)
        if exists { try FileManager.default.moveItem(at: directory, to: trash) }
        do {
            let updated = pages.filter { $0.id != pageID }
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
            options: Self.protectedWriteOptions)
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
        var recovered: [ScanPage] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  !restored.contains(where: { $0.id == id }),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".pending-sibling").path),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("original.source").path) else { continue }
            var page = ScanPage()
            page.id = id
            page.createdAt = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            page.status = .review
            page.message = "Originale recuperato dopo un'interruzione."
            recovered.append(page)
        }
        // Keep the committed order (including pairs and future user reordering).
        // Only files absent from the manifest are ordered by acquisition date.
        restored += recovered.sorted { $0.createdAt < $1.createdAt }
        for index in restored.indices {
            let directory = pageDirectory(restored[index].id)
            restored[index].hasCropped = restored[index].hasCropped && FileManager.default.fileExists(atPath: directory.appendingPathComponent("cropped.png").path)
            restored[index].hasCorrected = restored[index].hasCorrected && FileManager.default.fileExists(atPath: directory.appendingPathComponent("corrected.png").path)
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

    nonisolated private static var protectedWriteOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        // macOS command-line fixtures use the same store with ordinary atomic files.
        return [.atomic]
        #endif
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
        try (encoded as Data).write(to: url, options: Self.protectedWriteOptions)
    }
}
