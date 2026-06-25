import AVFoundation
import AppKit
import CoreImage
import Foundation

/// Single-shot front-camera photographer. Each call spins up its own capture
/// session, skips a few warm-up frames so exposure settles, grabs one JPEG frame
/// from the video stream, then tears the session down — so the camera LED only
/// lights for the brief moment of a capture, never the whole lock. Returns nil on
/// any failure (denied, no camera, lid closed, timeout).
///
/// Uses `AVCaptureVideoDataOutput` (a sample-buffer delegate on a dispatch
/// queue), NOT `AVCapturePhotoOutput`: the latter sets up KVO that fails to link
/// in this SwiftPM executable (`NSKVONotifying_AVCapturePhotoOutput not linked`),
/// so its delegate never fires and the capture leaks its continuation forever.
final class AVFoundationPhotographer: NSObject, IntruderPhotographer, @unchecked Sendable {

    func capture() async -> Data? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return nil
        }
        guard let device = Self.frontCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return nil
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        let collector = FrameCollector(warmupFrames: 8)
        let queue = DispatchQueue(label: "com.alperenkisi.leavemymacalone.camera")
        output.setSampleBufferDelegate(collector, queue: queue)

        session.startRunning()
        guard session.isRunning else { return nil }
        defer { session.stopRunning() }

        return await collector.firstFrame(timeout: .seconds(3))
    }

    private static func frontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front)
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

/// Grabs the first settled frame from an `AVCaptureVideoDataOutput` and encodes
/// it as JPEG, resolving the awaiting caller exactly once (or with nil on
/// timeout). The delegate callback runs on the capture queue; an `NSLock` guards
/// the single-resolution invariant, including the race where the first frame
/// arrives before `firstFrame()` has registered its continuation.
private final class FrameCollector: NSObject,
                                    AVCaptureVideoDataOutputSampleBufferDelegate,
                                    @unchecked Sendable {
    private let warmupFrames: Int
    private let lock = NSLock()
    private var seen = 0
    private var finished = false
    private var capturedData: Data?
    private var continuation: CheckedContinuation<Data?, Never>?

    init(warmupFrames: Int) {
        self.warmupFrames = warmupFrames
    }

    /// Suspend until the first settled frame (or `timeout`). Resolves once.
    func firstFrame(timeout: Duration) async -> Data? {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(nil)
        }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            lock.lock()
            if finished {
                let data = capturedData
                lock.unlock()
                cont.resume(returning: data)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
        timeoutTask.cancel()
        return result
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        seen += 1
        let take = !finished && seen > warmupFrames
        lock.unlock()
        guard take else { return }
        finish(Self.jpeg(from: sampleBuffer))
    }

    /// Resolve exactly once; stores the data so a frame arriving before
    /// `firstFrame()` registers is not lost.
    private func finish(_ data: Data?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        capturedData = data
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: data)
    }

    private static func jpeg(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
