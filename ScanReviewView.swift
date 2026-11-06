import SwiftUI

/// Loads only a bounded display image; the grid never decodes full original photographs.
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
    @ObservedObject var store: ScanSessionStore
    let pageID: UUID
    let pipeline: ScanProcessingPipeline
    @Binding var processing: Bool
    @State private var editing = false
    @State private var zone = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var previousZone: CGRect?
    @State private var originalPreview: UIImage?
    @State private var message: String?
    @State private var revision = 0

    private var page: ScanPage? { store.pages.first { $0.id == pageID } }
    var body: some View {
        ScrollView {
            if let page {
                VStack(spacing: 16) {
                    Text(page.status.title).font(.headline)
                    if editing, let originalPreview {
                        Image(uiImage: originalPreview).resizable().scaledToFit()
                            .overlay { CalibrationOverlay(zone: $zone, safety: 0, locked: processing) }
                    } else if let url = store.url(for: page, variant: page.selectedVariant) {
                        ScanFileImage(url: url).id("\(revision)-\(page.selectedVariant.rawValue)")
                            .overlay {
                                if page.selectedVariant == .original && !page.proposedContour.isEmpty {
                                    ScanOverlayView(contour: page.proposedContour, uncertain: page.status != .ready)
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
                    }.pickerStyle(.segmented).disabled(processing || editing)
                    Text("Il PDF userà la versione selezionata, con il filtro e il profilo scelti nei Controlli.")
                        .font(.caption).foregroundStyle(.secondary)
                    if processing { ProgressView("Elaborazione…") }
                    if editing {
                        Button("Applica ritaglio manuale") {
                            previousZone = page.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                            process(zone: zone, dewarp: false)
                        }.buttonStyle(.borderedProminent).disabled(processing)
                        Button("Annulla") { editing = false }.disabled(processing)
                    } else {
                        Button("Correggi ritaglio") {
                            zone = page.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                            editing = true
                        }.buttonStyle(.bordered).disabled(processing || originalPreview == nil)
                        Button("Prova correzione curvatura") {
                            process(zone: page.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1), dewarp: true)
                        }.disabled(processing)
                        if let previousZone {
                            Button("Ripristina ritaglio precedente") {
                                process(zone: previousZone, dewarp: false)
                                self.previousZone = nil
                            }.disabled(processing)
                        }
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
        .alert("Attenzione", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func process(zone: CGRect, dewarp: Bool) {
        guard !processing, var page, let url = store.url(for: page, variant: .original) else { return }
        processing = true
        Task { @MainActor in
            defer { processing = false }
            do {
                let result = try await pipeline.process(originalURL: url,
                    options: ScanProcessingOptions(automatic: false, dewarp: dewarp, zone: zone, margin: 0))
                try await store.saveVariant(result.cropped, for: page.id, variant: .cropped)
                if let corrected = result.corrected {
                    try await store.saveVariant(corrected, for: page.id, variant: .corrected)
                }
                page.hasCropped = true
                page.hasCorrected = result.corrected != nil
                page.selectedVariant = result.selectedVariant
                page.cropRect = result.cropRect
                page.status = result.status
                page.message = result.message
                try store.update(page)
                revision += 1
                editing = false
            } catch { message = error.localizedDescription }
        }
    }
}
