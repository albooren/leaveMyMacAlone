import Foundation

/// Hardware boundary for grabbing a single still photo. Returns JPEG-encoded
/// bytes, or nil when capture is impossible (no camera, lid closed, permission
/// denied, or any failure). Behind a protocol so the coordinator is testable
/// with a fake.
protocol IntruderPhotographer: Sendable {
    func capture() async -> Data?
}
