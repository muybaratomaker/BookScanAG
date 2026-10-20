import SwiftUI
import UIKit
import CoreImage

// BookScan AG 0.9 - pagina singola, profili Documento e Alta leggibilita.
// Funziona con CameraController e CameraPreview già presenti in CameraView.swift.
struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var pages: [Data] = []
    @State private var pageZone = CGRect(x: 0.075, y: 0.10, width: 0.85, height: 0.80)
    @State private var safetyMargin = 0.07
    @State private var documentProfile: DocumentProfile = .compact
    @State private var locked = false
    @State private var processing = false
    @State private var showShare = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var pdfSize: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 9) {
                // Proporzione 3:4: evita che il ritaglio usi coordinate diverse
                // dall'anteprima. La fotocamera è usata in verticale.
                GeometryReader { available in
                    let displayWidth = min(available.size.width, available.size.height * 3 / 4)
                    let displayHeight = displayWidth * 4 / 3
                    ZStack {
                        CameraPreview(session: camera.session)
                        CalibrationOverlay(zone: $pageZone,
                                           safety: safetyMargin, locked: locked)
                    }
                    .frame(width: displayWidth, height: displayHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(width: available.size.width, height: available.size.height)
                }
                .frame(maxHeight: .infinity)

                HStack {
                    Label(locked ? "Calibrazione bloccata" : "Trascina bordi e angoli", systemImage: locked ? "lock.fill" : "hand.draw")
                        .font(.caption)
                    Spacer()
                    Button(locked ? "Ricalibra" : "Blocca") { locked.toggle() }
                        .buttonStyle(.bordered)
                }
                HStack {
                    Text("Margine di sicurezza: \(Int(safetyMargin * 100))%")
                        .font(.caption)
                    Slider(value: $safetyMargin, in: 0.03...0.12, step: 0.01)
                        .disabled(locked)
                }
                HStack(spacing: 10) {
                    Button {
                        guard !processing else { return }
                        processing = true
                        camera.capture()
                    } label: {
                        Label("Scatta pagina", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(processing || camera.permissionDenied)

                    Button(processing ? "Attendi…" : "Esporta PDF") { exportPDF() }
                        .buttonStyle(.bordered)
                        .disabled(processing || pages.isEmpty)
                }
                Picker("Qualità", selection: $documentProfile) {
                    ForEach(DocumentProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!pages.isEmpty || processing)
                Text("\(pages.count) pagine · \(documentProfile.longEdge) px / JPEG \(Int(documentProfile.jpegQuality * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pages.isEmpty ? "Scegli un profilo prima di iniziare." : "Per cambiare profilo, esporta e inizia una nuova scansione.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let pdfSize { Text("Ultimo PDF: \(pdfSize)").font(.caption) }
                if !pages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(pages.indices, id: \.self) { i in
                                if let img = UIImage(data: pages[i]) {
                                    Image(uiImage: img).resizable().scaledToFit().frame(height: 68)
                                }
                            }
                        }
                    }.frame(height: 70)
                    Button("Elimina ultima pagina", role: .destructive) {
                        if !pages.isEmpty { pages.removeLast() }
                    }.font(.caption)
                }
            }
            .padding(10)
            .navigationTitle("BookScan AG 0.9")
            .onAppear {
                camera.onPhoto = { image in
                    let zone = pageZone
                    let padding = safetyMargin
                    let profile = documentProfile
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = FixedCrop.process(image, zone: zone, margin: padding, profile: profile)
                        DispatchQueue.main.async {
                            processing = false
                            if let result { pages.append(result) }
                            else { errorMessage = "Ritaglio non riuscito. Riprova lo scatto." }
                        }
                    }
                }
                camera.start()
            }
            .onDisappear { camera.stop() }
            .sheet(isPresented: $showShare) {
                if let exportedURL { BookShareSheet(items: [exportedURL]) }
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
        guard !processing else { return }
        processing = true
        let data = pages
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookScan-\(UUID().uuidString).pdf")
            let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
            do {
                try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { renderer in
                    for pageData in data {
                        guard let img = UIImage(data: pageData) else { continue }
                        renderer.beginPage()
                        let available = bounds.insetBy(dx: 16, dy: 16)
                        let scale = min(available.width / img.size.width,
                                        available.height / img.size.height)
                        let size = CGSize(width: img.size.width * scale,
                                          height: img.size.height * scale)
                        img.draw(in: CGRect(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2,
                                            width: size.width, height: size.height))
                    }
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                DispatchQueue.main.async {
                    processing = false
                    exportedURL = url
                    pdfSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    showShare = true
                }
            } catch {
                DispatchQueue.main.async {
                    processing = false
                    errorMessage = "Errore PDF: \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct CalibrationOverlay: View {
    @Binding var zone: CGRect
    let safety: Double
    let locked: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                outline(zone, size: geo.size, color: .green)
                if !locked {
                    editor(rect: $zone, size: geo.size, color: .green)
                }
            }
        }
    }

    @ViewBuilder
    private func outline(_ rect: CGRect, size: CGSize, color: Color) -> some View {
        let safe = FixedCrop.expanded(rect, margin: safety)
        Rectangle()
            .stroke(color.opacity(0.65), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .frame(width: safe.width * size.width, height: safe.height * size.height)
            .position(x: safe.midX * size.width, y: safe.midY * size.height)
            .allowsHitTesting(false)
        Rectangle()
            .stroke(color, lineWidth: 2)
            .frame(width: rect.width * size.width, height: rect.height * size.height)
            .position(x: rect.midX * size.width, y: rect.midY * size.height)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func editor(rect: Binding<CGRect>, size: CGSize, color: Color) -> some View {
        // Trascina l'interno per spostare il riquadro.
        Rectangle()
            .fill(color.opacity(0.08))
            .frame(width: rect.wrappedValue.width * size.width,
                   height: rect.wrappedValue.height * size.height)
            .position(x: rect.wrappedValue.midX * size.width,
                      y: rect.wrappedValue.midY * size.height)
            .modifier(ZoneDrag(rect: rect, size: size, corner: nil))
        // Trascina gli angoli per allargare o restringere.
        ForEach(0..<4, id: \.self) { corner in
            let zone = rect.wrappedValue
            let x = (corner == 0 || corner == 3) ? zone.minX : zone.maxX
            let y = (corner == 0 || corner == 1) ? zone.minY : zone.maxY
            Circle()
                .fill(color)
                .frame(width: 25, height: 25)
                .overlay(Circle().stroke(.black, lineWidth: 1.5))
                .position(x: x * size.width, y: y * size.height)
                .modifier(ZoneDrag(rect: rect, size: size, corner: corner))
        }
    }
}

private struct ZoneDrag: ViewModifier {
    @Binding var rect: CGRect
    let size: CGSize
    let corner: Int?
    @State private var origin: CGRect?

    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if origin == nil { origin = rect }
                guard let start = origin else { return }
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                if let corner {
                    var x1 = start.minX, x2 = start.maxX
                    var y1 = start.minY, y2 = start.maxY
                    if corner == 0 || corner == 3 { x1 = min(max(0, x1 + dx), x2 - 0.14) }
                    else { x2 = max(min(1, x2 + dx), x1 + 0.14) }
                    if corner == 0 || corner == 1 { y1 = min(max(0, y1 + dy), y2 - 0.15) }
                    else { y2 = max(min(1, y2 + dy), y1 + 0.15) }
                    rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
                } else {
                    rect = CGRect(x: min(max(0, start.minX + dx), 1 - start.width),
                                  y: min(max(0, start.minY + dy), 1 - start.height),
                                  width: start.width, height: start.height)
                }
            }
            .onEnded { _ in origin = nil })
    }
}

// Choose a profile before taking the first picture.
// Values are starting points, not guaranteed target PDF sizes.
private enum DocumentProfile: String, CaseIterable, Identifiable {
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

private enum FixedCrop {
    static func expanded(_ rect: CGRect, margin: Double) -> CGRect {
        // Il margine è una percentuale della dimensione della singola zona.
        let padX = rect.width * margin
        let padY = rect.height * margin
        return rect.insetBy(dx: -padX, dy: -padY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func process(_ image: UIImage, zone: CGRect, margin: Double, profile: DocumentProfile) -> Data? {
        // Normalize UIImage orientation (portrait EXIF) before cropping.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: image.size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let cg = upright.cgImage else { return nil }

        let safe = expanded(zone, margin: margin)
        let bounds = CGRect(x: safe.minX * CGFloat(cg.width),
                            y: safe.minY * CGFloat(cg.height),
                            width: safe.width * CGFloat(cg.width),
                            height: safe.height * CGFloat(cg.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard !bounds.isEmpty, let cropped = cg.cropping(to: bounds) else { return nil }

        // Grayscale, gentle document enhancement. No binary threshold:
        // faint letters and text near the book gutter must remain visible.
        let input = CIImage(cgImage: cropped)
        let adjusted = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: profile.contrast,
            kCIInputBrightnessKey: profile.brightness
        ])
        let context = CIContext()
        guard let output = context.createCGImage(adjusted, from: adjusted.extent) else { return nil }
        let page = UIImage(cgImage: output)
        let scale = min(1, CGFloat(profile.longEdge) / max(page.size.width, page.size.height))
        let target = CGSize(width: max(1, (page.size.width * scale).rounded()),
                            height: max(1, (page.size.height * scale).rounded()))
        let smallFormat = UIGraphicsImageRendererFormat()
        smallFormat.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: smallFormat).image { _ in
            page.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: profile.jpegQuality)
    }

}

private struct BookShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
