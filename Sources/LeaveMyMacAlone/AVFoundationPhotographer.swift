import AVFoundation
import Foundation

/// Single-shot front-camera photographer. Each call spins up its own capture
/// session, lets exposure settle, grabs one JPEG, then tears the session down —
/// so the camera LED only lights for the ~1 s of an actual capture, never the
/// whole lock. Returns nil on any failure (denied, no camera, lid closed).
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

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        session.startRunning()
        guard session.isRunning else { return nil }
        defer { session.stopRunning() }

        // Let auto-exposure / white-balance settle so the frame isn't black.
        try? await Task.sleep(for: .milliseconds(600))

        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // AVCapturePhotoOutput retains the delegate until the capture
            // completes, so a local instance is enough.
            let delegate = PhotoCaptureDelegate { data in cont.resume(returning: data) }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    private static func frontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front)
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

/// Bridges the one-shot delegate callback to a continuation.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: @Sendable (Data?) -> Void
    init(completion: @escaping @Sendable (Data?) -> Void) {
        self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        completion(photo.fileDataRepresentation())
    }
}
