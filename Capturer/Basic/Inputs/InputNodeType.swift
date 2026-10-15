
import Foundation
import AVFoundation

public protocol InputNodeType: Sendable {
  /// Adds this node to a session that is between `beginConfiguration()` and
  /// `commitConfiguration()`. Throws `SessionAttachmentError` when the session refuses it.
  func setUp(sessionInConfiguring: AVCaptureSession) throws
  func tearDown(sessionInConfiguring: AVCaptureSession)
}

public protocol DeviceInputNodeType: InputNodeType {
  var device: AVCaptureDevice { get }
}
