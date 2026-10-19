import SwiftUI
import AVFoundation
import UIKit
import CoreImage

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
    @Published var autoEnabled = false
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
        // Segment bright paper regions instead of searching for rectangles.
        let result = BookPageDetector.detect(pixelBuffer: pixel)
        let selected = result?.pages ?? []
        let boxes = selected.map { page -> CGRect in
            let xs = page.points.map(\.x), ys = page.points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        let stable = boxes.count == 2 && previousBoxes.count == 2 &&
            zip(boxes, previousBoxes).allSatisf {
                abs($0.0.midX - $0.1.midX) < 0.016 &&
                abs($0.0.midY - $0.1.midY) < 0.016 &&
                abs($0.0.width - $0.1.width) < 0.020 &&
                abs($0.0.height - $0.1.height) < 0.020
            }
        stableFrames = stable ? stableFrames + 1 : 0
        previousBoxes = boxes
        if boxes.count < 2 { absentFrames += 1 } else { absentFrames = 0 }
        if waitingForTurn && absentFrames >= 5 {
            waitingForTurn = false
            stableFrames = 0
        }
        // Intentionally conservative: automatic capture can be enabled by the user.
        let shouldCapture = stableFrames >= 7 && !waitingForTurn &&
                            selected.count == 2 && autoEnabled
        if shouldCapture { waitingForTurn = true; stableFrames = 0 }
        DispatchQueue.main.async {
            self.livePages = selected
            self.scanStatus = selected.count == 2
                ? (stable ? "Libro individuato · tieni fermo" : "Contorni in verifica…")
                : "Cerco le superfici delle pagine…"
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
