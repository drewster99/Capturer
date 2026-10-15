import AVFoundation
import Foundation


// to be replaced by the wrapped CaptureBody once ios 18.4 availability allow us to use isolated deinit.
public typealias CaptureBody = CaptureBodyWrapper

public final class CaptureBodyWrapper: @unchecked Sendable {
  public typealias Configuration = CaptureBody.Configuration

  public actor CaptureBody {

    public struct Configuration: Sendable {

      public var sessionPreset: AVCaptureSession.Preset = .photo

      public var enableMultitaskingCameraAccessIfSupported: Bool = false
        
      public init() {

      }

      public init(
        modify: (inout Self) -> Void
      ) {
        var instance = Self()
        modify(&instance)
        self = instance
      }
    }

    public struct State: Equatable {

    }

    public struct Handlers {

      public var didChangeState: (State) -> Void = { _ in }

      public init() {}
    }

    public private(set) var state: State = .init() {
      didSet {
        if oldValue != state {
          handlers.didChangeState(state)
        }
      }
    }

    public var handlers: Handlers = .init()

    /// The serial queue this actor runs on, and so the one queue every use of `session` happens on.
    ///
    /// `startRunning()`, `stopRunning()` and `commitConfiguration()` block until the camera has
    /// done what was asked, which can take hundreds of milliseconds. On the default actor executor
    /// that wait would park a Swift-concurrency cooperative thread, and the pool has only one per
    /// core, so every task queued behind it would stall. Apple's guidance is to drive a session from
    /// a dedicated serial queue; making that queue this actor's executor keeps every configuration,
    /// start and stop on it, in the order they were requested, while callers only suspend.
    private let sessionQueue = DispatchSerialQueue(label: "Capturer.CaptureBody.session")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
      sessionQueue.asUnownedSerialExecutor()
    }

    /// The underlying `AVCaptureSession`.
    ///
    /// Exposed so SwiftUI preview views (e.g. `CapturePreviewView`) can attach an
    /// `AVCaptureVideoPreviewLayer` and callers can observe its state. Mutate it only through this
    /// actor, which confines changes to `sessionQueue`. Reading its state can wait on the
    /// session's internal lock, so do that off the main thread and off the cooperative pool.
    public nonisolated(unsafe) let session: AVCaptureSession = .init()
    private var inputNode: InputNodeType?
    private var outputNodes: [OutputNodeType] = []

    public init(
      configuration: Configuration
    ) {
      guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }

      assert(Utils.checkIfCanUseCameraAccordingToPrivacySensitiveData() == true)

      // Enqueued rather than run here so that even the first configuration happens on
      // `sessionQueue`, not on whatever thread creates this. The queue is serial and this is
      // enqueued before the actor can receive any call, so it runs before every later use.
      let boxedSession = UncheckedSendable(session)
      sessionQueue.async {
        boxedSession.wrapped.performConfiguration {
          $0.sessionPreset = configuration.sessionPreset
          $0.automaticallyConfiguresCaptureDeviceForWideColor = true
          if configuration.enableMultitaskingCameraAccessIfSupported,
             $0.isMultitaskingCameraAccessSupported {
            $0.isMultitaskingCameraAccessEnabled = true
          }
        }
      }
    }

    /// Starts the session, returning once `startRunning()` has.
    ///
    /// Runs on `sessionQueue`; see it for why. The session may still not be running afterwards
    /// (an interruption, a runtime error), so read `session.isRunning` rather than assume.
    public func start() {
      Log.debug(.capture, "Session starting")
      session.startRunning()
    }

    /// Stops the session, returning once `stopRunning()` has. Runs on `sessionQueue`.
    public func stop() {
      Log.debug(.capture, "Session stopping")
      session.stopRunning()
    }

    /**
     Replaces the current input and adds the outputs, in one configuration.

     Throws `SessionAttachmentError` at the first node the session refuses. The nodes attached
     before it stay attached and are tracked, so they are torn down with the rest; the refused
     node and the ones after it are not attached. The previous input is removed either way.
     */
    public func batchAttaching(
      input newInputNode: InputNodeType,
      outputs newOutputNodes: [OutputNodeType]
    ) throws {
      try session.performConfiguration { session in
        try replaceInput(with: newInputNode, sessionInConfiguring: session)
        for output in newOutputNodes {
          try output.setUp(sessionInConfiguring: session)
          outputNodes.append(output)
        }
      }
    }

    /**
     Attaches an input with replacing current input.

     Throws `SessionAttachmentError` when the session refuses it; the previous input has been
     removed by then, so the session is left with no input rather than an untracked one.
     */
    public func attach(input newInputNode: some DeviceInputNodeType) throws {

      Log.debug(.capture, "Attach input \(newInputNode)")

      try session.performConfiguration { session in
        try replaceInput(with: newInputNode, sessionInConfiguring: session)
      }
    }

    /// Adds an output. Throws `SessionAttachmentError` when the session refuses it — as it does
    /// an output that is already attached — and then does not track it.
    public func attach(output component: some OutputNodeType) throws {

      Log.debug(.capture, "Attach output \(component)")

      try session.performConfiguration { session in
        try component.setUp(sessionInConfiguring: session)
      }
      outputNodes.append(component)
    }

    public func removeCurrentInput() {

      guard let currentInput = inputNode else {
        return
      }

      inputNode = nil

      self.session.performConfiguration {
        currentInput.tearDown(sessionInConfiguring: $0)
      }
    }

    /// Tracks the new input only once the session has accepted it, so a refused input is never
    /// torn down later as if it had been added.
    private func replaceInput(
      with newInputNode: InputNodeType,
      sessionInConfiguring session: AVCaptureSession
    ) throws {
      if let currentInputNode = inputNode {
        currentInputNode.tearDown(sessionInConfiguring: session)
        inputNode = nil
      }
      try newInputNode.setUp(sessionInConfiguring: session)
      inputNode = newInputNode
    }

    // upon migrating to ios 18.4, we can place this in the isolated deinit and remove the wrapper calling it
    fileprivate func isolatedDeinitAction() {
      session.performConfiguration { [inputNode] in
        inputNode?.tearDown(sessionInConfiguring: $0)
      }

      session.performConfiguration { [outputNodes] session in
        outputNodes.forEach { output in
          output.tearDown(sessionInConfiguring: session)
        }
      }
    }

    deinit {

      Log.debug(.capture, "\(self) deinitializes")

    }

  }

  /// The underlying `AVCaptureSession`. See `CaptureBody.session`.
  public var session: AVCaptureSession {
    wrappedCaptureBody.session
  }

  // Boilerplate wrapping:
  public init(
    configuration: Configuration
  ) {
    self.wrappedCaptureBody = .init(configuration: configuration)
  }

  public func start() async {
    await wrappedCaptureBody.start()
  }

  public func stop() async {
    await wrappedCaptureBody.stop()
  }

  public func batchAttaching(
    input newInputNode: InputNodeType,
    outputs newOutputNodes: [OutputNodeType]
  ) async throws {
    try await wrappedCaptureBody.batchAttaching(input: newInputNode, outputs: newOutputNodes)
  }

  public func removeCurrentInput() async {
    await wrappedCaptureBody.removeCurrentInput()
  }

  public func attach(output component: some OutputNodeType) async throws {
    try await wrappedCaptureBody.attach(output: component)
  }

  public func attach(input newInputNode: some DeviceInputNodeType) async throws {
    try await wrappedCaptureBody.attach(input: newInputNode)
  }

  private let wrappedCaptureBody: CaptureBody

  deinit {
    Task { [wrappedCaptureBody] in
      await wrappedCaptureBody.isolatedDeinitAction()
    }
  }
}

extension AVCaptureSession {

  @inline(__always)
  func performConfiguration(_ perform: (AVCaptureSession) throws -> Void) rethrows {
    beginConfiguration()
    defer {
      commitConfiguration()
    }
    try perform(self)
  }

}
