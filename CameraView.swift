import SwiftUI
import AVFoundation
import UIKit

struct LivePage: Equatable {
    let points: [CGPoint] // Normalized top-left coordinates, after portrait rotation.
}

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "bookscan.camera.session")
    private let visionQueue = DispatchQueue(label: "bookscan.camera.vision")
    private let detector = PageSegmentationService()
    @Published var permissionDenied = false
    @Published var ready = false
    @Published var livePages: [LivePage] = []
    @Published var liveUncertain = true
    @Published var scanStatus = "Inquadra una pagina"
    var onPhoto: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    private var configured = false
    private var captureInFlight = false
    // All tracking state is owned exclusively by visionQueue.
    private var detectionEnabled = true
    private var previousContour: [CGPoint] = []
    private var lastDetection: CFTimeInterval = 0
    private var lastVisionTime: CFTimeInterval = 0

    func setRecognitionEnabled(_ enabled: Bool) {
        visionQueue.async {
            self.detectionEnabled = enabled
            self.previousContour = []
            self.lastDetection = 0
            DispatchQueue.main.async {
                self.livePages = []
                self.liveUncertain = true
                self.scanStatus = enabled ? "Cerco la superficie della pagina…" : "Ritaglio manuale"
            }
        }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true; self.ready = false }
                return
            }
            self.sessionQueue.async {
                if !self.configured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                          let input = try? AVCaptureDeviceInput(device: device),
                          self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput),
                          self.session.canAddOutput(self.videoOutput) else {
                        self.session.commitConfiguration()
                        self.fail("Fotocamera non disponibile")
                        return
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
                    self.session.addOutput(self.videoOutput)
                    for output in [self.photoOutput as AVCaptureOutput, self.videoOutput as AVCaptureOutput] {
                        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }
                    do {
                        try device.lockForConfiguration()
                        device.videoZoomFactor = 1
                        device.unlockForConfiguration()
                    } catch { /* Device default is still the physical main camera. */ }
                    self.session.commitConfiguration()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async { self.permissionDenied = false; self.ready = running }
                if !running { self.fail("Impossibile avviare la fotocamera") }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false }
        }
    }

    func capture() {
        sessionQueue.async {
            guard self.session.isRunning, !self.captureInFlight else {
                self.fail("Fotocamera occupata o interrotta: riprova")
                return
            }
            self.captureInFlight = true
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            fail("Scatto non riuscito: riprova")
            return
        }
        DispatchQueue.main.async { self.onPhoto?(data) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { self.captureInFlight = false }
        if let error { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.scanStatus = message; self.onError?(message) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard detectionEnabled, now - lastVisionTime >= 0.35,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVisionTime = now
        let result = detector.detect(pixelBuffer: pixel)
        var points = result?.contour ?? []
        var uncertain = result?.needsReview ?? true
        if !points.isEmpty {
            // Smooth only compatible, small movements. Larger movements must track immediately.
            if points.count == previousContour.count {
                let drift = zip(points, previousContour).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
                if drift < 0.06 {
                    points = zip(points, previousContour).map { CGPoint(x: 0.65 * $0.x + 0.35 * $1.x,
                                                                        y: 0.65 * $0.y + 0.35 * $1.y) }
                }
            }
            previousContour = points
            lastDetection = now
        } else if now - lastDetection < 0.9 {
            points = previousContour
            uncertain = true // Stale evidence is never green.
        } else { previousContour = [] }
        let pages = points.isEmpty ? [] : [LivePage(points: points)]
        let status = points.isEmpty ? "Cerco la superficie della pagina…" : (uncertain ? "Contorno da controllare" : "Pagina individuata")
        DispatchQueue.main.async {
            self.livePages = pages
            self.liveUncertain = uncertain
            self.scanStatus = status
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        if let connection = view.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
