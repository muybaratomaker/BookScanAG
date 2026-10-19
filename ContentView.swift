import SwiftUI
import UIKit
import Vision
import CoreImage

// BookScan AG 0.4 — sostituisce ContentView.swift. CameraView.swift resta invariato.
private struct PageCorners {
    // Coordinate normalizzate, origine in alto a sinistra.
    var points: [CGPoint]
    static let fallback = PageCorners(points: [
        CGPoint(x: 0.06, y: 0.06), CGPoint(x: 0.94, y: 0.06),
        CGPoint(x: 0.94, y: 0.94), CGPoint(x: 0.06, y: 0.94)
    ])
}

private struct PageDraft: Identifiable {
    let id = UUID()
    let image: UIImage
    var corners: PageCorners
    let detected: Bool
    let reliable: Bool
}

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var pages: [Data] = []
    @State private var splitRatio = 0.5
    @State private var pending: [PageDraft] = []
    @State private var reviewing = false
    @State private var busy = false
    @State private var showShare = false
    @State private var exportedURL: URL?
    @State private var pdfSize: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    CameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    GeometryReader { geo in
                        Rectangle().fill(.yellow.opacity(0.9)).frame(width: 2)
                            .position(x: geo.size.width * splitRatio, y: geo.size.height / 2)
                    }.allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Text("Inquadra due pagine dall'alto")
                        .font(.caption).padding(8)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(12)
                }

                VStack(spacing: 3) {
                    Text("Rilegatura: \(Int(splitRatio * 100))%").font(.caption)
                    Slider(value: $splitRatio, in: 0.30...0.70)
                }.padding(.horizontal)

                HStack {
                    Button {
                        camera.capture()
                    } label: {
                        Label("Scatta 2 pagine", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || reviewing || camera.permissionDenied)

                    Button(busy ? "Attendi…" : "Esporta PDF") { exportPDF() }
                        .buttonStyle(.bordered)
                        .disabled(busy || pages.isEmpty)
                }

                Text("Pagine: \(pages.count) · correzione prospettica · JPEG")
                    .font(.caption)
                if let pdfSize {
                    Text("Ultimo PDF: \(pdfSize)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !pages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(pages.indices, id: \.self) { index in
                                if let image = UIImage(data: pages[index]) {
                                    Image(uiImage: image)
                                        .resizable().scaledToFit().frame(height: 95)
                                }
                            }
                        }
                    }.frame(height: 105)
                    Button("Elimina ultima coppia", role: .destructive) {
                        if pages.count >= 2 { pages.removeLast(2) }
                    }.font(.caption)
                }
            }
            .padding()
            .navigationTitle("BookScan AG 0.4")
            .onAppear {
                camera.onPhoto = { photo in
                    guard !busy, !reviewing else { return }
                    busy = true
                    let ratio = splitRatio
                    DispatchQueue.global(qos: .userInitiated).async {
                        let drafts = ScanProcessor.prepare(photo, ratio: ratio)
                        DispatchQueue.main.async {
                            busy = false
                            if drafts.count == 2 {
                                if drafts.allSatisfy({ $0.reliable }) {
                                    // Auto-save only when BOTH page contours pass checks.
                                    busy = true
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        let output = drafts.compactMap {
                                            ScanProcessor.correctAndCompress($0.image, corners: $0.corners)
                                        }
                                        DispatchQueue.main.async {
                                            busy = false
                                            if output.count == 2 {
                                                pages.append(contentsOf: output)
                                            } else {
                                                pending = drafts
                                                reviewing = true
                                                camera.stop()
                                            }
                                        }
                                    }
                                } else {
                                    pending = drafts
                                    reviewing = true
                                    camera.stop()
                                }
                            } else {
                                errorMessage = "Non riesco a elaborare questa fotografia."
                            }
                        }
                    }
                }
                camera.start()
            }
            .onDisappear { camera.stop() }
            .sheet(isPresented: $reviewing, onDismiss: { camera.start() }) {
                ReviewPagesView(drafts: $pending) { drafts in
                    reviewing = false
                    busy = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = drafts.compactMap {
                            ScanProcessor.correctAndCompress($0.image, corners: $0.corners)
                        }
                        DispatchQueue.main.async {
                            busy = false
                            if output.count == 2 {
                                pages.append(contentsOf: output)
                            } else {
                                errorMessage = "Impossibile salvare entrambe le pagine."
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportedURL { BookScanShareSheet(items: [exportedURL]) }
            }
            .alert("Attenzione", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .overlay {
                if camera.permissionDenied {
                    ContentUnavailableView("Fotocamera non autorizzata",
                        systemImage: "camera.fill",
                        description: Text("Abilita la fotocamera nelle Impostazioni."))
                }
            }
        }
    }

    private func exportPDF() {
        busy = true
        let snapshot = pages
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookScan-\(UUID().uuidString).pdf")
            let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
            let renderer = UIGraphicsPDFRenderer(bounds: bounds)
            do {
                try renderer.writePDF(to: url) { context in
                    for data in snapshot {
                        guard let image = UIImage(data: data) else { continue }
                        context.beginPage()
                        let area = bounds.insetBy(dx: 15, dy: 15)
                        let factor = min(area.width / image.size.width,
                                         area.height / image.size.height)
                        let size = CGSize(width: image.size.width * factor,
                                          height: image.size.height * factor)
                        image.draw(in: CGRect(
                            x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height))
                    }
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                DispatchQueue.main.async {
                    busy = false
                    exportedURL = url
                    pdfSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    showShare = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    errorMessage = "Errore PDF: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct ReviewPagesView: View {
    @Binding var drafts: [PageDraft]
    let onConfirm: ([PageDraft]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Pagina", selection: $selected) {
                    Text("Sinistra").tag(0)
                    Text("Destra").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal)

                if drafts.indices.contains(selected) {
                    CornerEditor(image: drafts[selected].image,
                                 corners: $drafts[selected].corners)
                        .padding(.horizontal, 12)
                    Text(drafts[selected].detected
                         ? "Bordi proposti automaticamente: trascina gli angoli per correggerli."
                         : "Bordi non rilevati: posiziona manualmente i quattro angoli.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Text("Controlla entrambe le pagine prima di salvare.")
                    .font(.caption)
                HStack {
                    Button("Annulla") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Ripristina angoli") {
                        if drafts.indices.contains(selected) {
                            drafts[selected].corners = .fallback
                        }
                    }.font(.caption)
                    Spacer()
                    Button("Salva 2 pagine") { onConfirm(drafts) }
                        .buttonStyle(.borderedProminent)
                }.padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Controlla il ritaglio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct CornerEditor: View {
    let image: UIImage
    @Binding var corners: PageCorners

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedRect(image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable().interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                Path { path in
                    guard corners.points.count == 4 else { return }
                    let pts = corners.points.map {
                        CGPoint(x: frame.minX + $0.x * frame.width,
                                y: frame.minY + $0.y * frame.height)
                    }
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    path.closeSubpath()
                }
                .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))

                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(.yellow)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                        .position(
                            x: frame.minX + corners.points[index].x * frame.width,
                            y: frame.minY + corners.points[index].y * frame.height
                        )
                        .modifier(CornerDragModifier(index: index, frame: frame, corners: $corners))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxHeight: .infinity)
    }

    private func fittedRect(_ image: CGSize, in space: CGSize) -> CGRect {
        let scale = min(space.width / max(image.width, 1),
                        space.height / max(image.height, 1))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (space.width-size.width)/2,
                      y: (space.height-size.height)/2,
                      width: size.width, height: size.height)
    }
}

private struct CornerDragModifier: ViewModifier {
    let index: Int
    let frame: CGRect
    @Binding var corners: PageCorners
    @State private var start: CGPoint?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if start == nil { start = corners.points[index] }
                    guard let origin = start else { return }
                    corners.points[index] = CGPoint(
                        x: min(1, max(0, origin.x + value.translation.width / max(1, frame.width))),
                        y: min(1, max(0, origin.y + value.translation.height / max(1, frame.height)))
                    )
                }
                .onEnded { _ in start = nil }
        )
    }
}

private enum ScanProcessor {
    static func prepare(_ photo: UIImage, ratio: Double) -> [PageDraft] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: photo.size, format: format)
            .image { _ in photo.draw(in: CGRect(origin: .zero, size: photo.size)) }
        guard let cg = normalized.cgImage, cg.width > 4 else { return [] }
        let split = max(1, min(cg.width-1, Int(CGFloat(cg.width)*CGFloat(ratio))))
        let halves = [
            CGRect(x: 0, y: 0, width: split, height: cg.height),
            CGRect(x: split, y: 0, width: cg.width-split, height: cg.height)
        ]
        return halves.compactMap { rect in
            guard let half = cg.cropping(to: rect) else { return nil }
            let detection = detect(half)
            return PageDraft(image: UIImage(cgImage: half),
                             corners: detection?.0 ?? .fallback,
                             detected: detection != nil,
                             reliable: detection?.1 ?? false)
        }
    }

    // Conservative page detector: Vision rectangle geometry + text evidence.
    // Never silently substitute the whole photograph when a contour is uncertain.
    private static func detect(_ image: CGImage) -> (PageCorners, Bool)? {
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 16
        rectangleRequest.minimumConfidence = 0.35
        rectangleRequest.minimumSize = 0.12
        rectangleRequest.minimumAspectRatio = 0.15
        rectangleRequest.maximumAspectRatio = 1.0
        rectangleRequest.quadratureTolerance = 40

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false

        do {
            try VNImageRequestHandler(cgImage: image, options: [:])
                .perform([rectangleRequest, textRequest])
        } catch { return nil }

        let texts = textRequest.results ?? []
        let candidates = (rectangleRequest.results ?? []).compactMap { rectangle
            -> (VNRectangleObservation, Double, Bool)? in
            let box = rectangle.boundingBox
            let area = Double(box.width * box.height)
            // A book page should fill a substantial part of its half-frame.
            guard area >= 0.28, box.width >= 0.48, box.height >= 0.46 else {
                return nil
            }
            // Reject short, wide regions likely to be keyboards or desks.
            let ratio = box.height / max(box.width, 0.001)
            guard ratio > 0.65 else { return nil }

            let matchingText = texts.filter { text in
                let center = CGPoint(x: text.boundingBox.midX, y: text.boundingBox.midY)
                return box.contains(center)
            }
            // Text must be spread across the page, not clustered on a keyboard.
            let verticalSpread: CGFloat = {
                guard let minY = matchingText.map({ $0.boundingBox.midY }).min(),
                      let maxY = matchingText.map({ $0.boundingBox.midY }).max()
                else { return 0 }
                return (maxY - minY) / max(box.height, 0.001)
            }()
            let hasPageText = matchingText.count >= 5 && verticalSpread >= 0.18
            let centrality = max(0, 1 - abs(Double(box.midX) - 0.5) * 2)
            let score = area * 2.0 + Double(rectangle.confidence) * 0.5
                        + (hasPageText ? 0.5 : 0)
                        + centrality * 0.15
            let reliable = area >= 0.42 &&
                           rectangle.confidence >= 0.65 &&
                           hasPageText && centrality >= 0.45
            return (rectangle, score, reliable)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }) else {
            return nil
        }

        func flip(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: 1-p.y)
        }
        let r = best.0
        return (PageCorners(points: [
            flip(r.topLeft), flip(r.topRight),
            flip(r.bottomRight), flip(r.bottomLeft)
        ]), best.2)
    }

    static func correctAndCompress(_ image: UIImage, corners: PageCorners) -> Data? {
        guard let cg = image.cgImage, corners.points.count == 4 else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let p = corners.points.map { CGPoint(x: $0.x*w, y: (1-$0.y)*h) }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgPoint: p[0]), forKey: "inputTopLeft")
        filter?.setValue(CIVector(cgPoint: p[1]), forKey: "inputTopRight")
        filter?.setValue(CIVector(cgPoint: p[2]), forKey: "inputBottomRight")
        filter?.setValue(CIVector(cgPoint: p[3]), forKey: "inputBottomLeft")
        guard let corrected = filter?.outputImage, !corrected.extent.isEmpty else { return nil }
        let gray = corrected.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.14,
            kCIInputBrightnessKey: 0.02
        ])
        let context = CIContext()
        guard let output = context.createCGImage(gray, from: gray.extent) else { return nil }
        let source = UIImage(cgImage: output)
        let scale = min(1, 2000 / max(source.size.width, source.size.height))
        let size = CGSize(width: max(1, (source.size.width*scale).rounded()),
                          height: max(1, (source.size.height*scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.76)
    }
}

private struct BookScanShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
