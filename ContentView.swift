import SwiftUI
import UIKit
import CoreImage
import AudioToolbox

@MainActor
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

    @StateObject private var store = ScanSessionStore()
    @State private var pipeline = ScanProcessingPipeline()
    @State private var automaticRecognition = true
    @State private var correctCurvature = false
    @State private var scanMode: ScanMode = .single
    @State private var pendingOptions: ScanProcessingOptions?
    @State private var pageZone = CGRect(x: 0.075, y: 0.10, width: 0.85, height: 0.80)
    @State private var safetyMargin = 0.03
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
            .onChange(of: scanMode) { mode in camera.setMode(mode, margin: safetyMargin) }
            .onChange(of: safetyMargin) { margin in camera.setMode(scanMode, margin: margin) }
            .onChange(of: automaticRecognition) { enabled in camera.setRecognitionEnabled(enabled) }
            .onChange(of: store.errorMessage) { message in if let message { errorMessage = message } }
            .onDisappear { camera.stop() }
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
                    performStoreChange { try store.clear() }
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
                            Text(store.pages.isEmpty ? "Inizia scansione" : "Continua scansione")
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
                            Text("\(store.pages.count) pagine" + (pdfSize.map { " · Ultimo PDF: \($0)" } ?? ""))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Button { showPages = true } label: {
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .disabled(store.pages.isEmpty || processing)
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
                    if !store.pages.isEmpty {
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
                        Text("\(store.pages.count) pagine acquisite")
                            .font(.caption).foregroundStyle(.white.opacity(0.64))
                    }
                    Spacer()
                    Button { exportPDF() } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.13), in: Circle())
                    }
                    .disabled(processing || store.pages.isEmpty)
                    .accessibilityLabel("Esporta PDF")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Picker("Modalità scansione", selection: $scanMode) {
                    ForEach(ScanMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).padding(.horizontal).disabled(processing)

                GeometryReader { available in
                    let aspect = max(0.1, camera.frameAspect)
                    let displayWidth = min(available.size.width - 16, available.size.height * aspect)
                    let displayHeight = displayWidth / aspect
                    ZStack(alignment: .bottom) {
                        ZStack {
                            CameraPreview(session: camera.session)
                            if automaticRecognition {
                                ForEach(Array(camera.livePages.enumerated()), id: \.offset) { _, page in
                                    ScanOverlayView(contour: page.points, uncertain: camera.liveUncertain)
                                }
                                ScanSeamOverlay(points: camera.liveSeam)
                            } else {
                                CalibrationOverlay(zone: $pageZone, safety: safetyMargin, locked: locked)
                            }
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

                        Button { if automaticRecognition { automaticRecognition = false }; locked.toggle() } label: {
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
                    Text(processing ? "In elaborazione…" : camera.scanStatus)
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
                    .disabled(processing || camera.permissionDenied || !camera.ready)
                    .accessibilityLabel("Scatta pagina")
                    .accessibilityHint(scanMode == .book ? "Acquisisce due pagine, sinistra poi destra" : "Aggiunge una pagina alla sessione")
                    Spacer(minLength: 0)
                    Button { showPages = true } label: {
                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.12))
                                .frame(width: 58, height: 58)
                            if let last = store.pages.last {
                                ScanFileImage(url: store.thumbnailURL(for: last), maxPixelSize: 240).id(last.revision)
                                    .frame(width: 58, height: 58).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else {
                                Image(systemName: "square.stack")
                                    .font(.title3).frame(width: 58, height: 58)
                            }
                            Text("\(store.pages.count)")
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
                Section("Correzione intelligente") {
                    Picker("Riconoscimento pagina", selection: $automaticRecognition) {
                        Text("Automatico").tag(true)
                        Text("Manuale").tag(false)
                    }.pickerStyle(.segmented)
                    Toggle("Correzione curvatura", isOn: $correctCurvature)
                    Text("Gli originali sono conservati. Controlla i risultati in Pagine prima di esportare; puoi scegliere foto, ritaglio o correzione.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    Slider(value: $safetyMargin, in: 0.01...0.08, step: 0.01)
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
                    Button("Visualizza \(store.pages.count) pagine") { showControls = false; showPages = true }
                        .disabled(store.pages.isEmpty || processing)
                    Button("Elimina ultima pagina", role: .destructive) {
                        performStoreChange { try store.removeLast() }
                    }.disabled(store.pages.isEmpty || processing)
                    Button("Cancella sessione", role: .destructive) {
                        showControls = false
                        showClearConfirmation = true
                    }.disabled(store.pages.isEmpty || processing)
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
                    ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                        NavigationLink {
                            ScanReviewView(store: store, pageID: page.id, pipeline: pipeline, processing: $processing)
                        } label: {
                            VStack(spacing: 6) {
                                ScanFileImage(url: store.thumbnailURL(for: page), maxPixelSize: 240).id(page.revision)
                                    .frame(maxWidth: .infinity).frame(height: 200)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text("Pagina \(index + 1)").font(.caption.weight(.medium))
                                Text(page.status.title).font(.caption2)
                                    .foregroundStyle(page.status == .review || page.status == .failed ? Color.orange : Color.secondary)
                            }
                        }.disabled(processing)
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
                        .disabled(store.pages.isEmpty || processing)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Elimina ultima", role: .destructive) {
                        performStoreChange { try store.removeLast() }
                    }.disabled(store.pages.isEmpty || processing)
                }
            }
        }
    }

    private func configureCamera() {
        camera.setRecognitionEnabled(automaticRecognition)
        camera.setMode(scanMode, margin: safetyMargin)
        camera.onError = { message in processing = false; pendingOptions = nil; errorMessage = message }
        camera.onPhoto = { data in
            let options = pendingOptions ?? ScanProcessingOptions(automatic: automaticRecognition, dewarp: correctCurvature, zone: pageZone, margin: safetyMargin, mode: scanMode)
            pendingOptions = nil
            Task { @MainActor in
                var acquired: ScanPage?
                defer { processing = false }
                do {
                    var page = try await store.addOriginal(data)
                    acquired = page
                    page.status = .processing
                    try store.update(page)
                    guard let url = store.url(for: page, variant: .original) else { throw ScanProcessingError.unreadable }
                    let capture = try await pipeline.processCapture(originalURL: url, options: options)
                    var targets = [page]
                    if capture.pages.count == 2 {
                        let right = try await store.addSibling(of: page)
                        targets = [store.pages.first(where: { $0.id == page.id }) ?? page, right]
                    }
                    for (index, result) in capture.pages.enumerated() {
                        var target = targets[index]
                        if options.mode == .book {
                            target.captureID = page.id
                            target.spreadSide = capture.pages.count == 2 ? (index == 0 ? "left" : "right") : "pending"
                            target.spreadSeam = capture.seam
                            target.spreadBounds = capture.bounds
                        }
                        try store.update(target)
                        _ = try await store.applyProcessed(result, to: target)
                    }
                    pdfSize = nil
                    AudioServicesPlaySystemSound(1104)
                } catch {
                    if let acquired {
                        for var failed in store.pages where (failed.id == acquired.id || failed.captureID == acquired.id)
                            && (failed.status == .processing || failed.status == .acquired) {
                            failed.status = .failed
                            failed.message = error.localizedDescription
                            failed.selectedVariant = .original
                            do { try store.update(failed) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
        if let message = store.errorMessage { errorMessage = message }
        if scanning { camera.start() }
    }

    private func takePhoto() {
        guard !processing, camera.ready, !camera.permissionDenied else { return }
        processing = true
        pendingOptions = ScanProcessingOptions(automatic: automaticRecognition, dewarp: correctCurvature,
                                               zone: pageZone, margin: safetyMargin, mode: scanMode)
        camera.capture()
    }

    private func performStoreChange(_ operation: () throws -> Void) {
        do { try operation(); pdfSize = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func exportPDF() {
        guard !processing, !store.pages.isEmpty else { return }
        guard store.pages.allSatisfy({ $0.status == .ready }) else {
            errorMessage = "Controlla e conferma le pagine segnalate prima di esportare: nessun originale verrà inserito al posto del ritaglio senza la tua scelta."
            showPages = true
            return
        }
        let urls = store.pages.compactMap { store.url(for: $0, variant: $0.selectedVariant) }
        guard urls.count == store.pages.count else { errorMessage = "Una pagina manca su disco: controlla la sessione."; return }
        processing = true
        let profile = documentProfile, style = scanStyle
        Task { @MainActor in
            defer { processing = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ScanPDFExporter.export(pages: urls, profile: profile, style: style)
                }.value
                let bytes = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                exportedURL = url
                pdfSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                showShare = true
            } catch { errorMessage = "Errore PDF: \(error.localizedDescription)" }
        }
    }
}

struct CalibrationOverlay: View {
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

private struct BookShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
