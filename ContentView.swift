import SwiftUI
import UIKit
import CoreImage
import AudioToolbox

// BookScan AG 1.0: home Apple Minimal, single-page scan, reusable crop and document looks.
// Compatible with existing CameraView.swift (CameraController / CameraPreview).
struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var scanning = false
    @State private var showControls = false
    @State private var showPages = false
    @State private var showShare = false
    @State private var showClearConfirmation = false
    @State private var processing = false
    @State private var errorMessage: String?
    @State private var exportedURL: URL?
    @State private var pdfSize: String?

    // Store JPEGs of the cropped, unfiltered pages, so export styles remain reversible.
    @State private var originals: [Data] = []
    @State private var pageZone = CGRect(x: 0.075, y: 0.10, width: 0.85, height: 0.80)
    @State private var safetyMargin = 0.07
    @State private var locked = false
    @State private var documentProfile: DocumentProfile = .compact
    @State private var scanStyle: ScanStyle = .optimized

    var body: some View {
        NavigationStack {
            Group {
                if scanning { scannerScreen }
                else { homeScreen }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(scanning ? Color.black : Color(uiColor: .systemGroupedBackground))
            .onAppear { configureCamera() }
            .onChange(of: scanning) { enabled in
                if enabled { camera.start() } else { camera.stop() }
            }
            .sheet(isPresented: $showControls) { controlsSheet }
            .sheet(isPresented: $showPages) { pagesSheet }
            .sheet(isPresented: $showShare) {
                if let exportedURL { BookShareSheet(items: [exportedURL]) }
            }
            .confirmationDialog("Eliminare tutte le pagine?", isPresented: $showClearConfirmation) {
                Button("Elimina tutte", role: .destructive) {
                    originals.removeAll()
                    pdfSize = nil
                }
            } message: { Text("Questa operazione non si può annullare.") }
            .alert("Attenzione", isPresented: Binding(get: { errorMessage != nil },
                                                      set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .tint(.blue)
    }

    private var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("IL TUO SCANNER").font(.caption.weight(.semibold))
                            .tracking(1.5).foregroundStyle(.secondary)
                        Text("BookScan AG").font(.largeTitle.bold())
                        Text("Libri in PDF, senza complicazioni")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showControls = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3).frame(width: 44, height: 44)
                            .background(.white, in: Circle())
                    }.accessibilityLabel("Impostazioni scansione")
                }
                VStack(alignment: .leading, spacing: 18) {
                    Label("Nuova scansione", systemImage: "doc.viewfinder")
                        .font(.title2.bold())
                    Text("Una pagina alla volta. Calibra il riquadro e continua a scattare.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: "doc.text.image").foregroundStyle(.blue)
                        Text(documentProfile.title)
                        Spacer()
                        Text(scanStyle.title).foregroundStyle(.secondary)
                    }.font(.subheadline)
                        .padding(13)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    Button { scanning = true } label: {
                        Label(originals.isEmpty ? "Inizia scansione" : "Continua scansione", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Sessione corrente").font(.title3.bold())
                    HStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.title2).foregroundStyle(.blue)
                            .frame(width: 52, height: 52)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading) {
                            Text("\(originals.count) pagine acquisite").font(.headline)
                            Text(pdfSize.map { "Ultimo PDF: \($0)" } ?? "Pronte per l'esportazione")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { showPages = true } label: { Image(systemName: "chevron.right") }
                            .disabled(originals.isEmpty)
                    }
                    if !originals.isEmpty {
                        Button { exportPDF() } label: {
                            Label("Esporta PDF", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(processing)
                    }
                }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 22))
                Text("Qualità e stile si possono cambiare anche dopo lo scatto, prima di esportare.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var scannerScreen: some View {
        GeometryReader { outer in
            VStack(spacing: 10) {
                HStack {
                    Button { scanning = false } label: {
                        Image(systemName: "xmark").font(.headline)
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.13), in: Circle())
                    }.accessibilityLabel("Torna alla home")
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Scansione pagina").font(.headline)
                        Text("\(originals.count) pagine acquisite")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Button("Esporta") { exportPDF() }
                        .font(.subheadline.weight(.semibold))
                        .disabled(originals.isEmpty || processing)
                        .frame(minWidth: 65, minHeight: 44)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)

                GeometryReader { available in
                    let displayWidth = min(available.size.width, available.size.height * 3 / 4)
                    let displayHeight = displayWidth * 4 / 3
                    ZStack {
                        CameraPreview(session: camera.session)
                        CalibrationOverlay(zone: $pageZone, safety: safetyMargin, locked: locked)
                        if camera.permissionDenied {
                            Color.black.opacity(0.85)
                            Text("Abilita la fotocamera nelle Impostazioni")
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: displayWidth, height: displayHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(width: available.size.width, height: available.size.height)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 8) {
                    Image(systemName: locked ? "lock.fill" : "hand.draw")
                    Text(locked ? "Calibrazione bloccata" : "Sposta i bordi verdi")
                    Spacer()
                    Button(locked ? "Ricalibra" : "Blocca") { locked.toggle() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.mint)
                        .frame(minHeight: 44)
                }.font(.footnote).foregroundStyle(.white)
                    .padding(.horizontal, 18)

                HStack(alignment: .center, spacing: 14) {
                    Button { showControls = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .frame(width: 58, height: 58)
                            .background(.white.opacity(0.13), in: Circle())
                    }.accessibilityLabel("Controlli")
                    Spacer(minLength: 0)
                    Button(action: takePhoto) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.92), lineWidth: 5)
                                .frame(width: 100, height: 100)
                            Circle().fill(processing ? Color.gray : .white)
                                .frame(width: 82, height: 82)
                            if processing {
                                ProgressView().tint(.black)
                            }
                        }
                        .frame(width: 108, height: 108)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(processing || camera.permissionDenied)
                    .accessibilityLabel("Scatta pagina")
                    .accessibilityHint("Aggiunge una pagina alla sessione")
                    Spacer(minLength: 0)
                    Button { showPages = true } label: {
                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.15))
                                .frame(width: 58, height: 58)
                            if let last = originals.last, let image = UIImage(data: last) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 58, height: 58).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            } else {
                                Image(systemName: "square.stack")
                                    .frame(width: 58, height: 58)
                            }
                            Text("\(originals.count)")
                                .font(.caption2.bold()).foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.white, in: Capsule())
                                .offset(x: 6, y: 6)
                        }
                    }.accessibilityLabel("Vedi pagine acquisite")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                Text("\(scanStyle.title) · Margine \(Int(safetyMargin * 100))%")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                    .padding(.bottom, 4)
            }
        }
    }

    private var controlsSheet: some View {
        NavigationStack {
            Form {
                Section("Qualità PDF") {
                    Picker("Qualità", selection: $documentProfile) {
                        ForEach(DocumentProfile.allCases) { p in Text(p.title).tag(p) }
                    }.pickerStyle(.segmented)
                    Text("Documento leggero: 1500 px / JPEG 54%. Testo piccolo: 1700 px / JPEG 68%.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Aspetto scansione") {
                    Picker("Stile", selection: $scanStyle) {
                        ForEach(ScanStyle.allCases) { style in Text(style.title).tag(style) }
                    }.pickerStyle(.segmented)
                    Text(scanStyle.description).font(.caption).foregroundStyle(.secondary)
                }
                Section("Ritaglio") {
                    HStack {
                        Text("Margine di sicurezza")
                        Spacer()
                        Text("\(Int(safetyMargin * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $safetyMargin, in: 0.03...0.12, step: 0.01)
                        .disabled(locked)
                    Button(locked ? "Sblocca calibrazione" : "Blocca calibrazione") {
                        locked.toggle()
                    }
                    Button("Reimposta riquadro") {
                        pageZone = CGRect(x: 0.075, y: 0.10, width: 0.85, height: 0.80)
                        locked = false
                    }
                }
                Section("Pagine") {
                    Button("Visualizza \(originals.count) pagine") { showControls = false; showPages = true }
                        .disabled(originals.isEmpty)
                    Button("Elimina ultima pagina", role: .destructive) {
                        if !originals.isEmpty { originals.removeLast() }
                    }.disabled(originals.isEmpty)
                    Button("Cancella sessione", role: .destructive) {
                        showControls = false
                        showClearConfirmation = true
                    }.disabled(originals.isEmpty)
                }
            }
            .navigationTitle("Controlli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Fine") { showControls = false }
            }}
        }
        .presentationDetents([.medium, .large])
    }

    private var pagesSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(originals.indices, id: \.self) { i in
                        VStack(spacing: 6) {
                            if let image = UIImage(data: originals[i]) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(maxWidth: .infinity).frame(height: 200)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text("Pagina \(i+1)").font(.caption.weight(.medium))
                        }
                    }
                }.padding()
            }
            .navigationTitle("Pagine acquisite")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chiudi") { showPages = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Esporta") { showPages = false; exportPDF() }
                        .disabled(originals.isEmpty || processing)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Elimina ultima", role: .destructive) {
                        if !originals.isEmpty { originals.removeLast() }
                    }.disabled(originals.isEmpty)
                }
            }
        }
    }

    private func configureCamera() {
        camera.onPhoto = { image in
            let zone = pageZone
            let margin = safetyMargin
            DispatchQueue.global(qos: .userInitiated).async {
                let result = FixedCrop.cropOriginal(image, zone: zone, margin: margin)
                DispatchQueue.main.async {
                    processing = false
                    if let result {
                        originals.append(result)
                        AudioServicesPlaySystemSound(1104)
                    } else {
                        errorMessage = "Ritaglio non riuscito. Riprova lo scatto."
                    }
                }
            }
        }
        if scanning { camera.start() }
    }

    private func takePhoto() {
        guard !processing, !camera.permissionDenied else { return }
        processing = true
        camera.capture()
        // Photo callback is responsible for resetting the processing state.
    }

    private func exportPDF() {
        guard !processing, !originals.isEmpty else { return }
        processing = true
        let inputPages = originals
        let profile = documentProfile
        let style = scanStyle
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookScan-\(UUID().uuidString).pdf")
            let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
            do {
                try UIGraphicsPDFRenderer(bounds: pageBounds).writePDF(to: url) { pdf in
                    for data in inputPages {
                        guard let converted = DocumentRendering.render(data, profile: profile, style: style),
                              let image = UIImage(data: converted) else { continue }
                        pdf.beginPage()
                        let area = pageBounds.insetBy(dx: 16, dy: 16)
                        let factor = min(area.width / image.size.width,
                                         area.height / image.size.height)
                        let size = CGSize(width: image.size.width * factor,
                                          height: image.size.height * factor)
                        let frame = CGRect(x: (pageBounds.width - size.width) / 2,
                                           y: (pageBounds.height - size.height) / 2,
                                           width: size.width, height: size.height)
                        image.draw(in: frame)
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

private enum ScanStyle: String, CaseIterable, Identifiable {
    case natural, optimized, blackWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "Naturale"
        case .optimized: return "Ottimizzato"
        case .blackWhite: return "Bianco e nero"
        }
    }
    var description: String {
        switch self {
        case .natural: return "Grigi naturali, contrasto delicato."
        case .optimized: return "Sfondo più chiaro e testo ben contrastato, senza soglie aggressive."
        case .blackWhite: return "Bianco e nero con contrasto elevato: controlla i caratteri sottili."
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
        let padX = rect.width * margin
        let padY = rect.height * margin
        return rect.insetBy(dx: -padX, dy: -padY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func cropOriginal(_ image: UIImage, zone: CGRect, margin: Double) -> Data? {
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
        // Working copy: retain details for all filter choices without full-resolution memory cost.
        let page = UIImage(cgImage: cropped)
        let factor = min(1, 2000 / max(page.size.width, page.size.height))
        let target = CGSize(width: max(1, (page.size.width * factor).rounded()),
                            height: max(1, (page.size.height * factor).rounded()))
        let scaled = UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in page.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: 0.86)
    }
}

private enum DocumentRendering {
    static func render(_ jpeg: Data, profile: DocumentProfile, style: ScanStyle) -> Data? {
        guard let image = UIImage(data: jpeg), let cg = image.cgImage else { return nil }
        var ci = CIImage(cgImage: cg)
        let contrast: CGFloat
        let brightness: CGFloat
        switch style {
        case .natural: contrast = 1.06; brightness = 0.008
        case .optimized: contrast = 1.16; brightness = 0.035
        case .blackWhite: contrast = 1.65; brightness = 0.06
        }
        ci = ci.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: contrast,
            kCIInputBrightnessKey: brightness
        ])
        // Mild sharpening of fine strokes; no hard threshold in any of the presets.
        if style == .optimized || style == .blackWhite {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: style == .optimized ? 0.25 : 0.35
            ])
        }
        guard let output = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        let page = UIImage(cgImage: output)
        let factor = min(1, CGFloat(profile.longEdge) / max(page.size.width, page.size.height))
        let target = CGSize(width: max(1, (page.size.width * factor).rounded()),
                            height: max(1, (page.size.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in page.draw(in: CGRect(origin: .zero, size: target)) }
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
