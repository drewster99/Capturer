import AVFoundation
import XCTest

@testable import Capturer

/// `-[AVCaptureSession addOutput:]` raises an Objective-C exception, which Swift cannot catch, when
/// the session refuses an output. Attaching the same output twice is the easiest way to get there,
/// and it used to crash the app; these pin that a refusal is reported as an error instead.
final class SessionAttachmentTests: XCTestCase {

  func testAttachingAPhotoOutputTwiceThrowsInsteadOfRaising() throws {
    let session = AVCaptureSession()
    let photoOutput = PhotoOutput()
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    try photoOutput.setUp(sessionInConfiguring: session)

    XCTAssertThrowsError(try photoOutput.setUp(sessionInConfiguring: session)) { error in
      XCTAssertEqual(
        error as? SessionAttachmentError,
        .sessionRefusedOutput(outputType: String(describing: AVCapturePhotoOutput.self))
      )
    }
    XCTAssertEqual(session.outputs.count, 1)
  }

  func testAttachingAVideoDataOutputTwiceThrowsInsteadOfRaising() throws {
    let session = AVCaptureSession()
    let videoDataOutput = VideoDataOutput()
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    try videoDataOutput.setUp(sessionInConfiguring: session)

    XCTAssertThrowsError(try videoDataOutput.setUp(sessionInConfiguring: session)) { error in
      XCTAssertEqual(
        error as? SessionAttachmentError,
        .sessionRefusedOutput(outputType: String(describing: AVCaptureVideoDataOutput.self))
      )
    }
    XCTAssertEqual(session.outputs.count, 1)
  }

  /// A wrapper must pass its upstream's refusal on, not swallow it.
  func testAWrappingOutputPassesTheRefusalOn() throws {
    let session = AVCaptureSession()
    let upstream = VideoDataOutput()
    let wrapper = AnyCMSampleBufferOutput(upstream)
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    try upstream.setUp(sessionInConfiguring: session)

    XCTAssertThrowsError(try wrapper.setUp(sessionInConfiguring: session)) { error in
      XCTAssertTrue(error is SessionAttachmentError)
    }
  }
}
