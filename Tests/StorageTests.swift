import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// macOS command-line tests of the actual disk store (no replacement implementation).
/// swiftc ScanProcessingTypes.swift ScanSessionStore.swift Tests/StorageTests.swift -o /tmp/bookscan-storage
@main
struct StorageTests {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("bookscan-storage-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let context = CGContext(data: nil, width: 24, height: 32, bitsPerComponent: 8,
            bytesPerRow: 24 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let image = png as Data
        let store = ScanSessionStore(directory: root)
        precondition(store.errorMessage == nil, store.errorMessage ?? "")
        let first = try await store.addOriginal(image)
        let secondCapture = try await store.addOriginal(image)
        // A later capture already exists when the first pair finishes processing.
        let right = try await store.addSibling(of: first)
        precondition(store.pages.map(\.id) == [first.id, right.id, secondCapture.id])
        let duplicateRequest = try await store.addSibling(of: first)
        precondition(duplicateRequest.id == right.id && store.pages.count == 3)
        let original = store.url(for: first, variant: .original)!
        let linked = store.url(for: right, variant: .original)!
        let firstInode = try files.attributesOfItem(atPath: original.path)[.systemFileNumber] as! NSNumber
        let secondInode = try files.attributesOfItem(atPath: linked.path)[.systemFileNumber] as! NSNumber
        precondition(firstInode == secondInode, "Original was copied instead of linked")
        let linkedBytes = try Data(contentsOf: linked)
        precondition(linkedBytes == image)
        let restored = ScanSessionStore(directory: root)
        precondition(restored.pages.map(\.id) == store.pages.map(\.id), "Restore reordered the pair")
        try restored.remove(pageID: first.id)
        let survivingBytes = try Data(contentsOf: linked)
        precondition(survivingBytes == image, "Deleting left lost shared original")
        precondition(restored.pages.map(\.id) == [right.id, secondCapture.id])
        try await restored.saveVariant(image, for: right.id, variant: .cropped)
        try await restored.saveVariant(image, for: right.id, variant: .corrected)
        try restored.select(.corrected, for: right.id)
        let revision = restored.pages[0].revision
        try await restored.saveVariant(image, for: right.id, variant: .cropped)
        precondition(!restored.pages[0].hasCorrected && restored.pages[0].selectedVariant == .cropped)
        precondition(restored.pages[0].revision != revision)
        // Simulate a stale corrected file left by an interrupted cleanup.
        try image.write(to: linked.deletingLastPathComponent().appendingPathComponent("corrected.png"))
        let reopened = ScanSessionStore(directory: root)
        precondition(!reopened.pages[0].hasCorrected, "A stale correction was resurrected")
        precondition(reopened.pages[0].selectedVariant == .cropped)
        // An interrupted sibling insertion must not be recovered as a duplicate.
        let pending = root.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: pending, withIntermediateDirectories: true)
        try files.linkItem(at: linked, to: pending.appendingPathComponent("original.source"))
        try Data().write(to: pending.appendingPathComponent(".pending-sibling"))
        precondition(ScanSessionStore(directory: root).pages.count == 2)
        // Existing manifests without new optional spread fields remain readable.
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy.filter {
            !["captureID", "spreadSide", "spreadSeam", "spreadBounds", "revision"].contains($0.key)
        })
        let legacyPage = try JSONDecoder().decode(ScanPage.self, from: legacyData)
        precondition(legacyPage.id == first.id)
        try reopened.clear()
        precondition(reopened.pages.isEmpty)
        print("PASS: pair order, idempotent sibling creation, shared original inode, deletion recovery, stale correction invalidation, revisions, pending sibling recovery and legacy decoding")
    }
}
