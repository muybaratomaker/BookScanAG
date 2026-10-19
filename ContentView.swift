import SwiftUI
import UIKit
import CoreImage

// BookScan AG 0.7 - due aree calibrabili, taglio fisso con margine di sicurezza.
// Funziona con CameraController e CameraPreview già presenti in CameraView.swift.
struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var pages: [Data] = []
    @State private var left = CGRect(x: 0.045, y: 0.14, width: 0.445, height: 0.70)
    @State private var right = CGRect(x: 0.51, y: 0.14, width: 0.445, height: 0.70)
    @State private var safetyMargin = 0.07
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
                        CalibrationOverlay(left: $left, right: $right,
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
                    Button { camera.capture() } label: {
                        Label("Scatta 2 pagine", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(processing || camera.permissionDenied)

                    Button(processing ? "Attendi…" : "Esporta PDF") { exportPDF() }
                        .buttonStyle(.bordered)
                        .disabled(processing || pages.isEmpty)
                }
                Text("\(pages.count) pagine salvate · ritaglio fisso · scala di grigi")
                    .font(.caption)
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
                    Button("Elimina ultima coppia", role: .destructive) {
                        if pages.count >= 2 { pages.removeLast(2) }
                    }.font(.caption)
                }
            }
            .padding(10)
            .navigationTitle("BookScan AG 0.7")
            .onAppear {
                camera.onPhoto = { image in
                    guard !processing else { return }
                    processing = true
                    let zones = [left, right]
                    let padding = safetyMargin
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = FixedCrop.process(image, zones: zones, margin: padding)
                        DispatchQueue.main.async {
                            processing = false
                            if let result { pages.append(contentsOf: result) }
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
    @Binding var left: CGRect
    @Binding var right: CGRect
    let safety: Double
    let locked: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                outline(left, size: geo.size, color: .green)
                outline(right, size: geo.size, color: .cyan)
                if !locked {
                    editor(rect: $left, size: geo.size, color: .green)
                    editor(rect: $right, size: geo.size, color: .cyan)
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

private enum FixedCrop {
    static func expanded(_ rect: CGRect, margin: Double) -> CGRect {
        // Il margine è una percentuale della dimensione della singola zona.
        let padX = rect.width * margin
        let padY = rect.height * margin
        return rect.insetBy(dx: -padX, dy: -padY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func process(_ image: UIImage, zones: [CGRect], margin: Double) -> [Data]? {
        // Normalizzazione dell'orientamento exif prima del ritaglio.
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        let upright = UIGraphicsImageRenderer(size: image.size, format: rendererFormat)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let cg = upright.cgImage else { return nil }
        let context = CIContext()
        var result: [Data] = []
        for zone in zones {
            let safe = expanded(zone, margin: margin)
            let box = CGRect(x: safe.minX * CGFloat(cg.width),
                             y: safe.minY * CGFloat(cg.height),
                             width: safe.width * CGFloat(cg.width),
                             height: safe.height * CGFloat(cg.height)).integral
            guard let crop = cg.cropping(to: box) else { return nil }
            let original = CIImage(cgImage: crop)
            let adjusted = original.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.12
            ])
            guard let gray = context.createCGImage(adjusted, from: adjusted.extent) else { return nil }
            let page = UIImage(cgImage: gray)
            let factor = min(1.0, 2000.0 / max(page.size.width, page.size.height))
            let outputSize = CGSize(width: max(1, (page.size.width * factor).rounded()),
                                    height: max(1, (page.size.height * factor).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: outputSize, format: format)
                .image { _ in page.draw(in: CGRect(origin: .zero, size: outputSize)) }
            guard let data = resized.jpegData(compressionQuality: 0.79) else { return nil }
            result.append(data)
        }
        return result.count == 2 ? result : nil
    }
}

private struct BookShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
