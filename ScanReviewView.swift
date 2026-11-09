import SwiftUI

/// Bounded display decode. Callers key by the persisted revision when files change.
struct ScanFileImage: View {
    let url: URL
    var maxPixelSize = 1300
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: url) {
            let input = url, limit = maxPixelSize
            let loaded = await Task.detached(priority: .utility) { ScanImageIO.load(input, maxPixelSize: limit) }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}

@MainActor
struct ScanReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ScanSessionStore
    let pageID: UUID
    let pipeline: ScanProcessingPipeline
    @Binding var processing: Bool
    @State private var editing = false
    @State private var splitting = false
    @State private var zone = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var bookZone = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var seamTop = 0.5
    @State private var seamBottom = 0.5
    @State private var dewarpPair = false
    @State private var previousZone: CGRect?
    @State private var originalPreview: UIImage?
    @State private var message: String?
    @State private var confirmDeletion = false

    private var page: ScanPage? { store.pages.first { $0.id == pageID } }
    private var proposedSpread: ScanSpreadGeometry.Spread? {
        ScanSpreadGeometry.manual(bounds: bookZone, seamTop: seamTop, seamBottom: seamBottom)
    }

    var body: some View {
        ScrollView {
            if let page {
                VStack(spacing: 16) {
                    Text(page.status.title).font(.headline)
                    if splitting, let originalPreview {
                        Image(uiImage: originalPreview).resizable().scaledToFit()
                            .overlay {
                                CalibrationOverlay(zone: $bookZone, safety: 0, locked: processing)
                                ScanSeamOverlay(points: proposedSpread?.seam ?? [])
                            }
                        Text("Regola il riquadro sul libro intero e la rilegatura. La posizione iniziale non è un riconoscimento confermato.")
                            .font(.caption).foregroundStyle(.secondary)
                        VStack {
                            Text("Rilegatura: estremità superiore")
                            Slider(value: $seamTop, in: 0.1...0.9)
                            Text("Rilegatura: estremità inferiore")
                            Slider(value: $seamBottom, in: 0.1...0.9)
                            Toggle("Correggi curvatura separatamente", isOn: $dewarpPair)
                        }.disabled(processing)
                        Button("Applica alle due pagine") { processPair() }
                            .buttonStyle(.borderedProminent).disabled(processing || proposedSpread == nil)
                        Button("Annulla") { splitting = false }.disabled(processing)
                    } else if editing, let originalPreview {
                        Image(uiImage: originalPreview).resizable().scaledToFit()
                            .overlay { CalibrationOverlay(zone: $zone, safety: 0, locked: processing) }
                    } else if let url = store.url(for: page, variant: page.selectedVariant) {
                        ScanFileImage(url: url).id(page.revision)
                            .overlay {
                                if page.selectedVariant == .original, let crop = page.cropRect {
                                    ScanOverlayView(contour: CropCoordinates.corners(crop), uncertain: page.status != .ready)
                                }
                            }
                    }
                    Text(page.message).font(.caption).foregroundStyle(.secondary)
                    Picker("Versione da esportare", selection: Binding(get: { page.selectedVariant }, set: { variant in
                        do { try store.select(variant, for: pageID) } catch { message = error.localizedDescription }
                    })) {
                        Text("Originale").tag(ScanVariant.original)
                        if page.hasCropped { Text("Ritagliata").tag(ScanVariant.cropped) }
                        if page.hasCorrected { Text("Corretta").tag(ScanVariant.corrected) }
                    }.pickerStyle(.segmented).disabled(processing || editing || splitting)
                    Text("Il PDF userà la versione selezionata. Originale mostra la foto completa; Ritagliata disattiva UVDoc su questa pagina.")
                        .font(.caption).foregroundStyle(.secondary)
                    if processing { ProgressView("Elaborazione…") }
                    if page.status != .ready && !editing && !splitting {
                        Button("Conferma questa versione per il PDF") {
                            var confirmed = page
                            confirmed.status = .ready
                            confirmed.message = "Versione controllata e confermata."
                            do { try store.update(confirmed) } catch { message = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).disabled(processing)
                    }
                    if editing {
                        Button("Applica ritaglio manuale") {
                            previousZone = page.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                            process(zone: zone, dewarp: false)
                        }.buttonStyle(.borderedProminent).disabled(processing)
                        Button("Annulla") { editing = false }.disabled(processing)
                    } else if !splitting {
                        Button("Correggi ritaglio di questa pagina") {
                            zone = page.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                            editing = true
                        }.buttonStyle(.bordered).disabled(processing || originalPreview == nil)
                        Button("Prova correzione curvatura") {
                            process(zone: page.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1), dewarp: true)
                        }.disabled(processing || page.spreadSide == "pending")
                        Button(page.spreadSide == nil || page.spreadSide == "pending" ? "Dividi in due pagine…" : "Regola rilegatura della coppia…") {
                            bookZone = page.spreadBounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                            seamTop = Double(page.spreadSeam?.first?.x ?? bookZone.midX)
                            seamBottom = Double(page.spreadSeam?.last?.x ?? bookZone.midX)
                            splitting = true
                        }.disabled(processing || originalPreview == nil)
                        if let previousZone {
                            Button("Ripristina ritaglio precedente") {
                                process(zone: previousZone, dewarp: false)
                                self.previousZone = nil
                            }.disabled(processing)
                        }
                        Button("Elimina questa pagina", role: .destructive) { confirmDeletion = true }
                            .disabled(processing)
                    }
                    Text("Controlla soprattutto parole, punteggiatura e margine della rilegatura. Puoi sempre tornare all'originale.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .navigationTitle("Controlla pagina")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(processing)
        .task {
            guard let page, let url = store.url(for: page, variant: .original) else { return }
            originalPreview = await Task.detached(priority: .utility) { ScanImageIO.load(url, maxPixelSize: 1300) }.value
        }
        .confirmationDialog("Eliminare questa pagina? L'altra pagina della coppia sarà conservata.", isPresented: $confirmDeletion) {
            Button("Elimina", role: .destructive) {
                do { try store.remove(pageID: pageID); dismiss() } catch { message = error.localizedDescription }
            }
        }
        .alert("Attenzione", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func process(zone: CGRect, dewarp: Bool) {
        guard !processing, let page, let url = store.url(for: page, variant: .original) else { return }
        processing = true
        Task { @MainActor in
            defer { processing = false }
            do {
                let result = try await pipeline.process(originalURL: url,
                    options: ScanProcessingOptions(automatic: false, dewarp: dewarp, zone: zone, margin: 0))
                _ = try await store.applyProcessed(result, to: page)
                editing = false
            } catch { message = error.localizedDescription }
        }
    }

    private func processPair() {
        guard !processing, let page else { return }
        let captureID = page.captureID ?? page.id
        let base = store.pages.first { $0.captureID == captureID && $0.spreadSide == "left" } ?? page
        guard let url = store.url(for: base, variant: .original) else { return }
        let options = ScanProcessingOptions(automatic: false, dewarp: dewarpPair, zone: bookZone,
                                            margin: 0.01, mode: .book, seamTop: seamTop, seamBottom: seamBottom)
        processing = true
        Task { @MainActor in
            defer { processing = false }
            do {
                let result = try await pipeline.processCapture(originalURL: url, options: options)
                guard result.pages.count == 2 else { throw ScanProcessingError.invalidCrop }
                let right = try await store.addSibling(of: base)
                let left = store.pages.first(where: { $0.id == base.id }) ?? base
                for (index, target) in [left, right].enumerated() {
                    var metadata = target
                    metadata.captureID = captureID
                    metadata.spreadSide = index == 0 ? "left" : "right"
                    metadata.spreadSeam = result.seam
                    metadata.spreadBounds = result.bounds
                    metadata.status = .processing
                    try store.update(metadata)
                    _ = try await store.applyProcessed(result.pages[index], to: metadata)
                }
                splitting = false
            } catch {
                message = error.localizedDescription
                for var pending in store.pages where pending.captureID == captureID {
                    pending.status = .review
                    pending.message = "Rielaborazione interrotta: controlla questa pagina. Originale conservato."
                    try? store.update(pending)
                }
            }
        }
    }
}
