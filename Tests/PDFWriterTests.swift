import Foundation

// Run: swiftc ScanPDFExporter.swift Tests/PDFWriterTests.swift -o /tmp/bookscan-pdf-tests
@main
struct PDFWriterTests {
    enum ExpectedFailure: Error { case interrupted }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bookscan-pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAQAAwDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==")!
        let output = directory.appendingPathComponent("session.pdf")
        var called: [Int] = []
        try ScanPDFWriter.write(pageCount: 150, to: output) { index in
            called.append(index)
            return PDFRaster(jpeg: jpeg, width: 12, height: 16)
        }
        precondition(called == Array(0..<150), "Page order changed or page skipped")
        let data = try Data(contentsOf: output)
        let text = String(decoding: data, as: UTF8.self)
        precondition(text.contains("/Count 150 /Kids"))
        precondition(text.hasSuffix("%%EOF\n"))
        var search = data.startIndex..<data.endIndex
        var copies = 0
        while let range = data.range(of: jpeg, in: search) {
            copies += 1
            search = range.upperBound..<data.endIndex
        }
        precondition(copies == 150, "JPEG bytes were changed or lost")
        // Resolve every xref offset against actual binary byte positions.
        let marker = Data("xref\n0 453\n".utf8)
        let markerRange = data.range(of: marker)!
        let xrefTail = String(decoding: data[markerRange.upperBound...], as: UTF8.self)
        let entries = xrefTail.split(separator: "\n")
        precondition(entries[0] == "0000000000 65535 f ")
        for id in 1...452 {
            let offset = Int(entries[id].prefix(10))!
            let expected = Data("\(id) 0 obj\n".utf8)
            precondition(data[offset..<(offset + expected.count)] == expected, "Broken xref for object \(id)")
        }
        precondition(text.contains("startxref\n\(markerRange.lowerBound)\n"))
        let empty = directory.appendingPathComponent("empty.pdf")
        do {
            try ScanPDFWriter.write(pageCount: 0, to: empty) { _ in fatalError("Unexpected page request") }
            fatalError("Accepted empty export")
        } catch ScanPDFError.noPages {}
        precondition(!FileManager.default.fileExists(atPath: empty.path))
        let invalid = directory.appendingPathComponent("invalid.pdf")
        do {
            try ScanPDFWriter.write(pageCount: 1, to: invalid) { _ in PDFRaster(jpeg: Data(), width: 12, height: 16) }
            fatalError("Accepted invalid JPEG")
        } catch ScanPDFError.invalidRaster {}
        precondition(!FileManager.default.fileExists(atPath: invalid.path))
        let partial = directory.appendingPathComponent("partial.pdf")
        do {
            try ScanPDFWriter.write(pageCount: 3, to: partial) { index in
                if index == 1 { throw ExpectedFailure.interrupted }
                return PDFRaster(jpeg: jpeg, width: 12, height: 16)
            }
            fatalError("Skipped a broken page")
        } catch ExpectedFailure.interrupted {}
        precondition(!FileManager.default.fileExists(atPath: partial.path))
        for captures in [1, 20] {
            let count = captures * 2
            let pairs = directory.appendingPathComponent("pairs-\(captures).pdf")
            var order: [String] = []
            try ScanPDFWriter.write(pageCount: count, to: pairs) { index in
                order.append("\(index / 2)-\(index % 2 == 0 ? "left" : "right")")
                return PDFRaster(jpeg: jpeg, width: 12, height: 16)
            }
            let expected = (0..<captures).flatMap { ["\($0)-left", "\($0)-right"] }
            precondition(order == expected)
            let contents = try Data(contentsOf: pairs)
            precondition(String(decoding: contents, as: UTF8.self).contains("/Count \(count) /Kids"))
            print("PASS: \(captures) spread(s), \(count) PDF pages in left/right order")
        }
        // Optional destination for independent PDF readers (pdfinfo/pdftoppm).
        if CommandLine.arguments.count > 1 {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        print("PASS: 150-page order; byte-identical JPEGs; all xref offsets; empty export rejection; invalid JPEG cleanup; interrupted export cleanup")
    }
}
