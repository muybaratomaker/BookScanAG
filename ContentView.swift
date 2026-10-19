import SwiftUI
import UIKit
import CoreImage
import Vision

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var pages: [Data] = [] // JPEG ottimizzati, non fotografie originali
    @State private var splitRatio = 0.5
    @State private var autoCrop = true
    @State private var showShare = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var exporting = false
    @State private var pdfSize: String?

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
                    Text("Inquadra entrambe le pagine dall'alto")
                        .font(.caption).padding(8)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white).padding(12)
                }
                VStack(spacing: 4) {
                    Text("Rilegatura: \(Int(splitRatio * 100))%")
                        .font(.caption)
                    Slider(value: $splitRatio, in: 0.30...0.70)
                }.padding(.horizontal)
                Toggle("Ritaglio automatico dei margini", isOn: $autoCrop)
                    .font(.subheadline)
                    .padding(.horizontal)
                HStack(spacing: 16) {
                    Button { camera.capture() } label: {
                        Label("Scatta 2 pagine", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(camera.permissionDenied || exporting)
                    Button(exporting ? "Esportazione…" : "Esporta PDF") { exportPDF() }
                        .buttonStyle(.bordered)
                        .disabled(pages.isEmpty || exporting)
                }
                Text("Pagine: \(pages.count) · JPEG bilanciato · scala di grigi")
                    .font(.caption)
                if let pdfSize {
                    Text("Ultimo PDF: \(pdfSize)").font(.caption).foregroundStyle(.secondary)
                }
                if !pages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(pages.indices, id: \.self) { index in
                                if let image = UIImage(data: pages[index]) {
                                    Image(uiImage: image)
                                        .resizable().scaledToFit().frame(height: 100)
                                }
                            }
                        }
                    }.frame(height: 108)
                    Button("Elimina ultima coppia") {
                        if pages.count >= 2 { pages.removeLast(2) }
                    }.font(.caption)
                }
            }
            .padding()
            .navigationTitle("BookScan AG")
            .onAppear {
                camera.onPhoto = { photo in
                    let ratio = splitRatio
                    let cropEnabled = autoCrop
                    DispatchQueue.global(qos: .userInitiated).async {
                        let pair = ImageProcessing.splitAndCompress(photo, ratio: ratio, autoCrop: cropEnabled)
                        DispatchQueue.main.async {
                            if let pair { pages.append(contentsOf: pair) }
                            else { errorMessage = "Impossibile elaborare la fotografia." }
                        }
                    }
                }
                camera.start()
            }
            .onDisappear { camera.stop() }
            .sheet(isPresented: $showShare) {
                if let exportedURL { ShareSheet(items: [exportedURL]) }
            }
            .alert("Attenzione", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .overlay {
                if camera.permissionDenied {
                    ContentUnavailableView("Fotocamera non autorizzata", systemImage: "camera.fill", description: Text("Abilita la fotocamera nelle Impostazioni di iOS."))
                }
            }
        }
    }

    private func exportPDF() {
        exporting = true
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
                        let area = bounds.insetBy(dx: 18, dy: 18)
                        let scale = min(area.width / image.size.width, area.height / image.size.height)
                        let width = image.size.width * scale
                        let height = image.size.height * scale
                        image.draw(in: CGRect(x: (bounds.width-width)/2,
                                            y: (bounds.height-height)/2,
                                            width: width, height: height))
                    }
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                DispatchQueue.main.async {
                    exportedURL = url
                    pdfSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    exporting = false
                    showShare = true
                }
            } catch {
                DispatchQueue.main.async {
                    exporting = false
                    errorMessage = "Errore PDF: \(error.localizedDescription)"
                }
            }
        }
    }
}

private enum ImageProcessing {
    // Obiettivo: immagini leggibili per OCR senza conservare JPEG originali.
    // 1800 px sul lato lungo per singola pagina, JPEG 0.80, scala di grigi.
    static func splitAndCompress(_ image: UIImage, ratio: Double, autoCrop: Bool) -> [Data]? {
        let normalizedFormat = UIGraphicsImageRendererFormat()
        normalizedFormat.scale = 1
        let normalized = UIGraphicsImageRenderer(size: image.size, format: normalizedFormat)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        guard let cg = normalized.cgImage, cg.width > 2, cg.height > 2 else { return nil }
        let cut = max(1, min(cg.width - 1, Int(Double(cg.width) * ratio)))
        let rects = [CGRect(x: 0, y: 0, width: cut, height: cg.height),
                     CGRect(x: cut, y: 0, width: cg.width-cut, height: cg.height)]
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var result: [Data] = []
        for rect in rects {
            guard let cropped = cg.cropping(to: rect) else { return nil }
            let detected = autoCrop ? detectPage(in: cropped) : nil
            let source = CIImage(cgImage: detected ?? cropped)
            let gray = source.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.12
            ])
            guard let grayCG = ciContext.createCGImage(gray, from: gray.extent) else { return nil }
            let page = UIImage(cgImage: grayCG)
            let factor = min(1.0, 1800.0 / max(page.size.width, page.size.height))
            let size = CGSize(width: max(1, (page.size.width * factor).rounded()),
                              height: max(1, (page.size.height * factor).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format)
                .image { _ in page.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = scaled.jpegData(compressionQuality: 0.80) else { return nil }
            result.append(jpeg)
        }
        return result
    }

    // Rileva un rettangolo con Vision. Se la confidenza geometrica è bassa,
    // conserva l'immagine originale per non perdere righe di testo.
    private static func detectPage(in image: CGImage) -> CGImage? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumConfidence = 0.65
        request.minimumSize = 0.25
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let rectangles = request.results, !rectangles.isEmpty else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let candidates = rectangles.compactMap { observation -> CGRect? in
            let box = observation.boundingBox
            // VN usa coordinate normalizzate con origine in basso a sinistra.
            let raw = CGRect(x: box.minX * width,
                             y: (1 - box.maxY) * height,
                             width: box.width * width,
                             height: box.height * height)
            let fraction = (raw.width * raw.height) / (width * height)
            guard fraction >= 0.48, fraction <= 0.99,
                  raw.width > width * 0.55,
                  raw.height > height * 0.55 else { return nil }
            return raw
        }
        guard let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }
        // Margine di sicurezza: 2% per non tagliare numeri e intestazioni.
        let paddingX = width * 0.02
        let paddingY = height * 0.02
        let safe = largest.insetBy(dx: -paddingX, dy: -paddingY)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !safe.isEmpty else { return nil }
        return image.cropping(to: safe)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
