import Foundation

/// Why a node could not be attached to an `AVCaptureSession`.
///
/// `-[AVCaptureSession addInput:]` and `-addOutput:` raise an Objective-C exception, which Swift
/// cannot catch, when the session refuses the node — for instance when the same output is attached
/// twice, or the session cannot take another input. Nodes ask `canAddInput` / `canAddOutput` first
/// and throw this instead, so the caller can report the failure rather than crash.
public enum SessionAttachmentError: Error, Equatable, Sendable {
  /// The session refused an input. The payload names the input's type, for diagnostics.
  case sessionRefusedInput(inputType: String)
  /// The session refused an output. The payload names the output's type, for diagnostics.
  case sessionRefusedOutput(outputType: String)
}
