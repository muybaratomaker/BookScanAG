import SwiftUI
import UIKit
import Vision
import CoreImage

// BookScan AG 0.6 — sostituisce ContentView.swift. CameraView.swift resta invariato.
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
                        // Preview uses resizeAspect: match the portrait video image's fitted bounds.
                        let videoRatio: CGFloat = 9.0 / 16.0
                        let previewWidth = min(geo.size.width, geo.size.height * videoRatio)
                        let previewHeight = previewWidth / videoRatio
                        let originX = (geo.size.width - previewWidth) / 2
                        let originY = (geo.size.height - previewHeight) / 2
                        Path { path in
                            for page in camera.livePages where page.points.count == 4 {
                                let points = page.points.map {
                                    CGPoint(x: originX + $0.x * previewWidth,
                                            y: originY + $0.y * previewHeight)
                                }
                                path.move(to: points[0])
                                for point in points.dropFirst() { path.addLine(to: point) }
                                path.closeSubpath()
                            }
                        }
                        .stroke(camera.livePages.count == 2 ? .green : .yellow, lineWidth: 3)
                        Rectangle().fill(.yellow.opacity(0.55)).frame(width: 1)
                            .position(x: originX + previewWidth * splitRatio,
                                      y: geo.size.height / 2)
                    }.allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Text(camera.scanStatus)
                        .font(.caption).padding(8)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(12)
                }

                VStack(spacing: 3) {
                    Text("Rilegatura: \(Int(splitRatio * 100))%").font(.caption)
                    Slider(value: $splitRatio, in: 0.30...0.70)
                }.padding(.horizontal)

                Toggle("Scatto automatico (sperimentale)", isOn: $camera.autoEnabled)
                    .onChange(of: camera.autoEnabled) { _ in camera.resetAutoCapture() }
                    .padding(.horizontal)

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

                Text("Pagine: \(pages.count) · ritaglio sperimentale · JPEG")
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
            .navigationTitle("BookScan AG 0.6")
            .onAppear {
                camera.onAutoCapture = {
                    guard !busy, !reviewing else { return }
                    camera.capture()
                }
                camera.onPhoto = { photo in
                    guard !busy, !reviewing else { return }
                    busy = true
                    let ratio = splitRatio
                    DispatchQueue.global(qos: .userInitiated).async {
                        let drafts = ScanProcessor.prepare(photo, ratio: ratio)
                        DispatchQueue.main.async {
                            busy = false
                            if drafts.count == 2 {
                                if drafts.allSatisfy({ $0.reliable }) && camera.autoEnabled {
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
        guard let cg = normalized.cgImage, cg.width > 4, cg.height > 4 else { return [] }
        // Analyze the FULL photograph, then crop each page. Never use a
        // generic rectangle detector or silently include the whole table.
        guard let detected = BookPageDetector.detect(image: normalized),
              detected.pages.count == 2 else { return [] }
        return detected.pages.compactMap { page in
            let xs = page.points.map(\.x), ys = page.points.map(\.y)
            guard let l = xs.min(), let r = xs.max(),
                  let t = ys.min(), let b = ys.max() else { return nil }
            let rect = CGRect(x: max(0, floor(l * CGFloat(cg.width))),
                              y: max(0, floor(t * CGFloat(cg.height))),
                              width: ceil((r-l) * CGFloat(cg.width)),
                              height: ceil((b-t) * CGFloat(cg.height)))
                .intersection(CGRect(x:0,y:0,width:cg.width,height:cg.height))
            guard rect.width > 10, rect.height > 10,
                  let cropped = cg.cropping(to: rect) else { return nil }
            return PageDraft(image: UIImage(cgImage: cropped),
                             corners: PageCorners(points: [CGPoint(x:0,y:0), CGPoint(x:1,y:0), CGPoint(x:1,y:1), CGPoint(x:0,y:1)]),
                             detected: true,
                             reliable: true)
        }
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
