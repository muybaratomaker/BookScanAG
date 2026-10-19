import SwiftUI
import AVFoundation
import UIKit
import Vision

struct LivePage: Equatable {
    // Points are normalized in top-left image coordinates, clockwise.
    let points: [CGPoint]
}

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "bookscan.camera.session")
    private let visionQueue = DispatchQueue(label: "bookscan.camera.vision")
    @Published var permissionDenied = false
    @Published var livePages: [LivePage] = []
    @Published var scanStatus = "Inquadra il libro aperto"
    @Published var autoEnabled = true
    var onPhoto: ((UIImage) -> Void)?
    var onAutoCapture: (() -> Void)?

    private var configured = false
    private var processingFrame = false
    private var previousBoxes: [CGRect] = []
    private var stableFrames = 0
    private var lastVisionTime: CFTimeInterval = 0
    private var waitingForTurn = false
    private var absentFrames = 0
    private var captureInFlight = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                if !self.configured {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                          let input = try? AVCaptureDeviceInput(device: device),
                          self.session.canAddInput(input),
                          self.session.canAddOutput(self.photoOutput),
                          self.session.canAddOutput(self.videoOutput) else {
                        self.session.commitConfiguration()
                        return
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.visionQueue)
                    self.session.addOutput(self.videoOutput)
                    if let connection = self.videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    self.session.commitConfiguration()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture() {
        sessionQueue.async {
            guard self.session.isRunning, !self.captureInFlight else { return }
            self.captureInFlight = true
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        sessionQueue.async { self.captureInFlight = false }
        guard error == nil, let image else {
            DispatchQueue.main.async { self.scanStatus = "Scatto non riuscito: riprova" }
            return
        }
        DispatchQueue.main.async { self.onPhoto?(image) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastVisionTime >= 0.30, !processingFrame,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVisionTime = now
        processingFrame = true
        defer { processingFrame = false }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 14
        request.minimumConfidence = 0.50
        request.minimumSize = 0.13
        request.minimumAspectRatio = 0.15
        request.quadratureTolerance = 35
        do {
            // Video buffers are portrait because the video connection is portrait.
            try VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up, options: [:]).perform([request])
        } catch { return }
        let observations = (request.results ?? []).filter {
            let b = $0.boundingBox
            return b.width > 0.20 && b.height > 0.25 && b.width * b.height > 0.095
        }
        // Split the live frame around the book's central binding.
        let left = observations.filter { $0.boundingBox.midX < 0.5 }
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        let right = observations.filter { $0.boundingBox.midX >= 0.5 }
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        let selected = [left, right].compactMap { $0 }
        let boxes = selected.map(\.boundingBox)
        let stable = selected.count == 2 && previousBoxes.count == 2 && zip(boxes, previousBoxes).allSatisfy {
            let a = $0.0, b = $0.1
            return abs(a.midX-b.midX) < 0.022 && abs(a.midY-b.midY) < 0.022 &&
                   abs(a.width-b.width) < 0.025 && abs(a.height-b.height) < 0.025
        }
        stableFrames = stable ? stableFrames + 1 : 0
        previousBoxes = boxes
        if selected.count < 2 {
            absentFrames += 1
        } else { absentFrames = 0 }
        // Require the book to disappear/change clearly before the next automatic capture.
        if waitingForTurn && absentFrames >= 3 { waitingForTurn = false; stableFrames = 0 }
        let contours = selected.map { observation -> LivePage in
            func convert(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
            return LivePage(points: [convert(observation.topLeft), convert(observation.topRight),
                                     convert(observation.bottomRight), convert(observation.bottomLeft)])
        }
        let shouldCapture = stableFrames >= 5 && !waitingForTurn && selected.count == 2 && autoEnabled
        if shouldCapture { waitingForTurn = true; stableFrames = 0 }
        DispatchQueue.main.async {
            self.livePages = contours
            self.scanStatus = self.waitingForTurn && !shouldCapture ? "Gira pagina per continuare" :
                selected.count == 2 ? (stable ? "Tieni fermo…" : "Allinea le pagine") : "Cerco due pagine…"
            if shouldCapture && self.autoEnabled { self.onAutoCapture?() }
        }
    }

    func resetAutoCapture() {
        visionQueue.async {
            self.waitingForTurn = false
            self.stableFrames = 0
            self.previousBoxes = []
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
