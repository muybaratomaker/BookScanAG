import SwiftUI
import UIKit
import CoreImage
import AudioToolbox

// BookScan AG 1.2.1: corrected Scanner filter preserving text contrast, single-page scan, reusable crop and document looks.
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
    @State private var scanStyle: ScanStyle = .scanner

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

    // MARK: - BookScan AG 1.1: softer home, edge-to-edge scanner, floating controls.
    private var homeScreen: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("BOOKSCAN", systemImage: "book.pages")
                            .font(.caption.weight(.bold)).tracking(2.1)
                            .foregroundStyle(Color(red: 0.28, green: 0.34, blue: 0.46))
                        Spacer()
                        Button { showControls = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 50, height: 50)
                                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        }
                        .accessibilityLabel("Impostazioni scansione")
                    }
                    .padding(.top, 18)

                    Text("Il tuo libro,\nuna pagina alla volta.")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 40)
                    Text("Scatta, ritaglia ed esporta un PDF leggero.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)

                    // Decorative illustration, no fake documents or additional actions.
                    ZStack {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.90, green: 0.94, blue: 1.0),
                                                          Color(red: 0.96, green: 0.97, blue: 0.99)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Circle().fill(.white.opacity(0.60)).frame(width: 215, height: 215)
                            .blur(radius: 20).offset(x: 75, y: -60)
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 100, weight: .ultraLight))
                            .foregroundStyle(Color(red: 0.27, green: 0.42, blue: 0.76))
                            .rotationEffect(.degrees(-12))
                            .shadow(color: .blue.opacity(0.13), radius: 20, y: 12)
                        Image(systemName: "viewfinder")
                            .font(.system(size: 142, weight: .ultraLight))
                            .foregroundStyle(.blue.opacity(0.42))
                    }
                    .frame(height: 222)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .padding(.top, 32)

                    Button {
                        scanning = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 21, weight: .semibold))
                            Text(originals.isEmpty ? "Inizia scansione" : "Continua scansione")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.headline)
                        }
                        .padding(.horizontal, 23)
                        .frame(height: 66)
                        .foregroundStyle(.white)
                        .background(Color(red: 0.12, green: 0.35, blue: 0.91),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)

                    HStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.blue)
                            .frame(width: 50, height: 50)
                            .background(Color.blue.opacity(0.07), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sessione corrente").font(.headline)
                            Text("\(originals.count) pagine" + (pdfSize.map { " · Ultimo PDF: \($0)" } ?? ""))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Button { showPages = true } label: {
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .disabled(originals.isEmpty)
                        .accessibilityLabel("Apri pagine acquisite")
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 4)
                    .padding(.top, 15)
                    Divider().opacity(0.45)
                    Button { showControls = true } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("\(scanStyle.title) · \(documentProfile.title)")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                    }
                    if !originals.isEmpty {
                        Button { exportPDF() } label: {
                            Label("Esporta PDF", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity).frame(height: 52)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                        .disabled(processing)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.bottom, 45)
            }
        }
    }

    private var scannerScreen: some View {
        GeometryReader { outer in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { scanning = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.13), in: Circle())
                    }.accessibilityLabel("Torna alla home")
                    Spacer()
                    VStack(spacing: 2) {
                        Text("BookScan").font(.headline.weight(.semibold))
                        Text("\(originals.count) pagine acquisite")
                            .font(.caption).foregroundStyle(.white.opacity(0.64))
                    }
                    Spacer()
                    Button { exportPDF() } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.13), in: Circle())
                    }
                    .disabled(processing || originals.isEmpty)
                    .accessibilityLabel("Esporta PDF")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)

                GeometryReader { available in
                    let displayWidth = min(available.size.width - 16, available.size.height * 0.75)
                    let displayHeight = displayWidth * 4 / 3
                    ZStack(alignment: .bottom) {
                        ZStack {
                            CameraPreview(session: camera.session)
                            CalibrationOverlay(zone: $pageZone, safety: safetyMargin, locked: locked)
                            if camera.permissionDenied {
                                Color.black.opacity(0.85)
                                Text("Abilita la fotocamera nelle Impostazioni")
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            }
                        }
                        .frame(width: displayWidth, height: displayHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                        Button { locked.toggle() } label: {
                            Label(locked ? "Ricalibra" : "Blocca ritaglio",
                                  systemImage: locked ? "lock.fill" : "hand.draw")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .background(.black.opacity(0.67), in: Capsule())
                        }
                        .padding(.bottom, 14)
                        .accessibilityLabel(locked ? "Sblocca il ritaglio" : "Blocca il ritaglio")
                    }
                    .frame(width: available.size.width, height: available.size.height)
                }
                .frame(maxHeight: .infinity)

                HStack {
                    Text(scanStyle.title)
                    Circle().frame(width: 3, height: 3)
                    Text("Margine \(Int(safetyMargin * 100))%")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.70))
                .padding(.vertical, 10)

                HStack(alignment: .center, spacing: 10) {
                    Button { showControls = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 22))
                            .frame(width: 58, height: 58)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Controlli scansione")
                    Spacer(minLength: 0)
                    Button(action: takePhoto) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.94), lineWidth: 5)
                                .frame(width: 101, height: 101)
                            Circle().fill(processing ? Color.gray : Color.white)
                                .frame(width: 82, height: 82)
                            if processing { ProgressView().tint(.black) }
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
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.12))
                                .frame(width: 58, height: 58)
                            if let last = originals.last, let image = UIImage(data: last) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 58, height: 58).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else {
                                Image(systemName: "square.stack")
                                    .font(.title3).frame(width: 58, height: 58)
                            }
                            Text("\(originals.count)")
                                .font(.caption2.bold()).foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.white, in: Capsule())
                                .offset(x: 6, y: 5)
                        }
                    }
                    .accessibilityLabel("Pagine acquisite")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .frame(width: outer.size.width, height: outer.size.height)
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
                    }.pickerStyle(.menu)
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
    case natural, optimized, scanner, blackWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "Naturale"
        case .optimized: return "Ottimizzato"
        case .scanner: return "Scanner"
        case .blackWhite: return "Bianco e nero"
        }
    }
    var description: String {
        switch self {
        case .natural: return "Grigi naturali, contrasto delicato."
        case .optimized: return "Sfondo più chiaro e testo ben contrastato."
        case .scanner: return "Bianco uniforme e ombre attenuate: ideale per pagine di libri."
        case .blackWhite: return "Contrasto forte; verifica i caratteri sottili prima di esportare."
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
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(color.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .frame(width: safe.width * size.width, height: safe.height * size.height)
            .position(x: safe.midX * size.width, y: safe.midY * size.height)
            .allowsHitTesting(false)
        RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                .frame(width: 27, height: 27)
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
    // The image is processed ONLY at PDF export. Original cropped JPEGs are kept
    // untouched so users can re-export using a different look.
    static func render(_ jpeg: Data, profile: DocumentProfile, style: ScanStyle) -> Data? {
        guard let image = UIImage(data: jpeg), let cg = image.cgImage else { return nil }
        var ci = CIImage(cgImage: cg)
        ci = ci.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0
        ])

        switch style {
        case .natural:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.06,
                kCIInputBrightnessKey: 0.008
            ])
        case .optimized:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.16,
                kCIInputBrightnessKey: 0.035
            ])
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.25
            ])
        case .scanner:
            // Safe scan look: retain dark letter strokes while lifting light paper.
            // IMPORTANT: Do not divide the photo by a blurred background here:
            // that previously normalized dark strokes almost to white.
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.30,
                kCIInputBrightnessKey: 0.025
            ])
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.22
            ])
        case .blackWhite:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.65,
                kCIInputBrightnessKey: 0.06
            ])
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.35
            ])
        }

        let context = CIContext()
        guard let output = context.createCGImage(ci, from: ci.extent) else { return nil }
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
