import AVFoundation
import CoreImage
import CoreMedia
import XCTest

@testable import Capturer

/// Proves `DemoVideoSource.rotated(_:by:to:)` turns a frame upright for **every** orientation and
/// mirroring a recording can stamp on its track, not only the one portrait clip the demo camera
/// happens to bundle.
///
/// The bug this guards against is silent and orientation-specific: a rotation that is right for a
/// quarter turn can be a half turn off, or mirror-flipped, for another orientation, and nothing in
/// the pipeline would notice — the frame simply renders sideways. A dimensions-only check would
/// pass a 180° error, so this samples actual corner pixels.
///
/// ## Method
///
/// The input frame is divided into four solid-colour quadrants — red top-left, green top-right,
/// blue bottom-left, white bottom-right — so "upright" is a checkable claim about where each colour
/// ends up. `preferredTransform` is authored in the video's top-left, y-down space, and a correct
/// rotation reproduces what `AVPlayerItem.videoComposition` would have done: map every point by the
/// transform and normalise the result to the origin. This test computes that mapping independently
/// (the *oracle*) and compares it to what `rotated(_:by:to:)` actually produced. Both agree only if
/// the code is correct; where they disagree, the failing corner names the error.
///
/// The eight transforms are the full dihedral group `D4` — the four rotations and their four
/// mirrors — each built the way AVFoundation builds a real `preferredTransform`: a rotation/
/// reflection about the origin, then a translation that slides the transformed rect back into the
/// positive quadrant. They are derived, not invented; `testTransformsMatchAVFoundationConvention`
/// pins the 90° case to the matrix a real recording carries.
final class DemoVideoOrientationTests: XCTestCase {

  // The natural (pre-rotation) frame size. Non-square so a width/height swap is detectable, and
  // divisible by four so each quadrant centroid lands on a clean pixel.
  private let naturalSize = CGSize(width: 64, height: 48)

  private struct RGBColor: Equatable {
    let r, g, b: UInt8
    static let red = RGBColor(r: 255, g: 0, b: 0)
    static let green = RGBColor(r: 0, g: 255, b: 0)
    static let blue = RGBColor(r: 0, g: 0, b: 255)
    static let white = RGBColor(r: 255, g: 255, b: 255)
  }

  /// One named quadrant of the source frame: the colour it is painted, and the centroid of that
  /// quadrant in the source's top-left-origin, y-down coordinate space.
  private struct Quadrant {
    let name: String
    let color: RGBColor
    let sourceCentroid: CGPoint
  }

  private func quadrants(for size: CGSize) -> [Quadrant] {
    let w = size.width, h = size.height
    return [
      Quadrant(name: "top-left", color: .red, sourceCentroid: CGPoint(x: w * 0.25, y: h * 0.25)),
      Quadrant(name: "top-right", color: .green, sourceCentroid: CGPoint(x: w * 0.75, y: h * 0.25)),
      Quadrant(name: "bottom-left", color: .blue, sourceCentroid: CGPoint(x: w * 0.25, y: h * 0.75)),
      Quadrant(name: "bottom-right", color: .white, sourceCentroid: CGPoint(x: w * 0.75, y: h * 0.75)),
    ]
  }

  // MARK: - The eight orientations

  private struct Orientation {
    let name: String
    // The 2x2 linear part in AVFoundation's y-down, top-left space: (x, y) -> (a*x + c*y, b*x + d*y).
    let a, b, c, d: CGFloat
  }

  /// The full dihedral group `D4`: four rotations (det +1) and four mirrors (det -1). Every
  /// `preferredTransform` a recording can carry is one of these eight linear parts plus a
  /// translation, which `transform(_:for:)` supplies.
  private let orientations: [Orientation] = [
    Orientation(name: "0° (identity)", a: 1, b: 0, c: 0, d: 1),
    Orientation(name: "90° CW", a: 0, b: 1, c: -1, d: 0),
    Orientation(name: "180°", a: -1, b: 0, c: 0, d: -1),
    Orientation(name: "270° CW (90° CCW)", a: 0, b: -1, c: 1, d: 0),
    Orientation(name: "mirrored horizontally", a: -1, b: 0, c: 0, d: 1),
    Orientation(name: "mirrored + 90° CW", a: 0, b: 1, c: 1, d: 0),
    Orientation(name: "mirrored vertically (180° mirror)", a: 1, b: 0, c: 0, d: -1),
    Orientation(name: "mirrored + 270° CW", a: 0, b: -1, c: -1, d: 0),
  ]

  /// Builds the genuine `preferredTransform` for an orientation exactly as AVFoundation does:
  /// the linear part about the origin, then a translation chosen so the transformed natural rect
  /// sits in the positive quadrant with its corner at the origin.
  private func transform(_ orientation: Orientation, for size: CGSize) -> CGAffineTransform {
    let linear = CGAffineTransform(a: orientation.a, b: orientation.b, c: orientation.c, d: orientation.d, tx: 0, ty: 0)
    let mappedBounds = CGRect(origin: .zero, size: size).applying(linear)
    return linear.concatenating(CGAffineTransform(translationX: -mappedBounds.minX, y: -mappedBounds.minY))
  }

  // MARK: - The proof

  func testEveryOrientationRendersUpright() throws {
    let source = DemoVideoSource.forRotationTesting()
    let sourceBuffer = try makeQuadrantBuffer(size: naturalSize)

    var failures: [String] = []

    for orientation in orientations {
      let transform = self.transform(orientation, for: naturalSize)
      let renderSize = DemoVideoSource.renderSize(naturalSize: naturalSize, transform: transform)

      guard let output = source.rotated(sourceBuffer, by: transform, to: renderSize) else {
        failures.append("\(orientation.name): rotated(...) returned nil")
        continue
      }

      // (a) dimensions — a quarter turn swaps them.
      let outW = CVPixelBufferGetWidth(output), outH = CVPixelBufferGetHeight(output)
      let expectedW = Int(renderSize.width.rounded()), expectedH = Int(renderSize.height.rounded())
      if outW != expectedW || outH != expectedH {
        failures.append("\(orientation.name): output \(outW)x\(outH), expected \(expectedW)x\(expectedH)")
      }

      // (b) corner pixels — the oracle says where each source quadrant's colour must land.
      var evidence: [String] = []
      var ok = true
      for quadrant in quadrants(for: naturalSize) {
        let expectedPoint = quadrant.sourceCentroid.applying(transform)
        let actual = try readPixel(in: output, atUpright: expectedPoint)
        let matched = actual == quadrant.color
        evidence.append("\(quadrant.name) \(quadrant.color)→(\(Int(expectedPoint.x)),\(Int(expectedPoint.y)))=\(actual) \(matched ? "ok" : "WRONG")")
        if !matched { ok = false }
      }
      if !ok {
        failures.append("\(orientation.name): \(evidence.joined(separator: " | "))")
      } else {
        print("[orientation] \(orientation.name): upright — \(evidence.joined(separator: " | "))")
      }
    }

    XCTAssertTrue(failures.isEmpty, "Orientation rotation failures:\n" + failures.joined(separator: "\n"))
  }

  /// The identity case must come back upright and unchanged.
  func testIdentityIsUnchanged() throws {
    let source = DemoVideoSource.forRotationTesting()
    let sourceBuffer = try makeQuadrantBuffer(size: naturalSize)
    let renderSize = DemoVideoSource.renderSize(naturalSize: naturalSize, transform: .identity)
    let output = try XCTUnwrap(source.rotated(sourceBuffer, by: .identity, to: renderSize))

    XCTAssertEqual(CVPixelBufferGetWidth(output), Int(naturalSize.width))
    XCTAssertEqual(CVPixelBufferGetHeight(output), Int(naturalSize.height))
    for quadrant in quadrants(for: naturalSize) {
      let actual = try readPixel(in: output, atUpright: quadrant.sourceCentroid)
      XCTAssertEqual(actual, quadrant.color, "identity moved \(quadrant.name)")
    }
  }

  /// Pins one derived transform to the matrix a real 90° recording carries, so the oracle cannot
  /// silently drift onto an invented convention.
  func testTransformsMatchAVFoundationConvention() {
    let ninety = transform(orientations[1], for: naturalSize) // 90° CW
    XCTAssertEqual(ninety.a, 0)
    XCTAssertEqual(ninety.b, 1)
    XCTAssertEqual(ninety.c, -1)
    XCTAssertEqual(ninety.d, 0)
    XCTAssertEqual(ninety.tx, naturalSize.height) // tx = height for a 90° video
    XCTAssertEqual(ninety.ty, 0)
  }

  // MARK: - Real capture: a landscape clip through the whole player path

  /// The isolated `rotated(...)` proof above covers the maths. This drives the **whole** path a
  /// real capture takes — encode to a file, read the track's `preferredTransform` back, play it
  /// through `AVQueuePlayer` + the display link, and pull the very buffer the shutter returns —
  /// with a genuinely landscape-transformed clip (portrait content stamped with a 90° turn, whose
  /// render size is wider than it is tall). The existing round-trip test checks only that the
  /// dimensions swap, which a 180° error would pass; this samples the corner colours.
  func testLandscapeFootagePlaysBackUprightThroughTheWholePlayerPath() async throws {
    // Portrait natural size + a quarter turn = a landscape render, exercising the rotation.
    let naturalSize = CGSize(width: 240, height: 320)
    let url = temporaryURL("landscape-demo.mov")
    defer { try? FileManager.default.removeItem(at: url) }

    let recorder = DemoVideoRecorder()
    try recorder.start(to: url, size: naturalSize, rotationDegrees: 90, frameRate: 30)
    let content = try makeQuadrantBuffer(size: naturalSize)
    for index in 0..<12 {
      recorder.append(content, at: CMTime(value: CMTimeValue(index), timescale: 30))
    }
    _ = try await recorder.finish()

    // The transform the file actually carries — read back, not assumed — is the oracle's input.
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let (trackNaturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
    XCTAssertFalse(preferredTransform.isIdentity, "a 90° recording must carry a transform")
    let renderSize = DemoVideoSource.renderSize(naturalSize: trackNaturalSize, transform: preferredTransform)
    XCTAssertGreaterThan(renderSize.width, renderSize.height, "a portrait clip turned 90° renders landscape")

    let source = try await DemoVideoSource.prepare(videoURLs: [url])
    source.start(feeding: VideoDataOutput())
    defer { source.stop() }
    try await waitUntil("a frame is published") { source.latestPixelBuffer != nil }
    let frame = try XCTUnwrap(source.latestPixelBuffer)

    XCTAssertEqual(CVPixelBufferGetWidth(frame), Int(renderSize.width.rounded()))
    XCTAssertEqual(CVPixelBufferGetHeight(frame), Int(renderSize.height.rounded()))

    // rotated(...) normalises the transformed extent to the origin; the oracle must too.
    let mappedBounds = CGRect(origin: .zero, size: trackNaturalSize).applying(preferredTransform)
    var evidence: [String] = []
    for quadrant in quadrants(for: trackNaturalSize) {
      let mapped = quadrant.sourceCentroid.applying(preferredTransform)
      let upright = CGPoint(x: mapped.x - mappedBounds.minX, y: mapped.y - mappedBounds.minY)
      let actual = try readPixel(in: frame, atUpright: upright)
      evidence.append("\(quadrant.name) \(quadrant.color)→(\(Int(upright.x)),\(Int(upright.y)))=\(actual)")
      XCTAssertEqual(actual, quadrant.color, "landscape playback put \(quadrant.name) in the wrong place")
    }
    print("[landscape round-trip] \(evidence.joined(separator: " | "))")
  }

  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("OrientationTests-\(UUID().uuidString)-\(name)")
  }

  private func waitUntil(_ description: String, timeout: TimeInterval = 15, _ condition: @escaping () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("timed out waiting for: \(description)")
  }

  // MARK: - Pixel helpers (BGRA, top-left origin)

  /// A `naturalSize` BGRA buffer painted in four solid quadrants.
  private func makeQuadrantBuffer(size: CGSize) throws -> CVPixelBuffer {
    let width = Int(size.width), height = Int(size.height)
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    let pb = try XCTUnwrap(buffer, "CVPixelBufferCreate failed: \(status)")

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pb)

    for row in 0..<height {
      for col in 0..<width {
        let color: RGBColor
        let left = col < width / 2, top = row < height / 2
        switch (top, left) {
        case (true, true): color = .red
        case (true, false): color = .green
        case (false, true): color = .blue
        case (false, false): color = .white
        }
        let p = base + row * rowBytes + col * 4
        p[0] = color.b; p[1] = color.g; p[2] = color.r; p[3] = 255
      }
    }
    return pb
  }

  /// Reads the pixel at an upright, top-left-origin point in a BGRA buffer, clamped into range.
  private func readPixel(in buffer: CVPixelBuffer, atUpright point: CGPoint) throws -> RGBColor {
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let col = min(max(Int(point.x.rounded(.down)), 0), width - 1)
    let row = min(max(Int(point.y.rounded(.down)), 0), height - 1)

    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let p = base + row * rowBytes + col * 4
    return classify(b: p[0], g: p[1], r: p[2])
  }

  /// Snaps a sampled pixel to the nearest of the four quadrant colours, absorbing any edge
  /// interpolation from the render.
  private func classify(b: UInt8, g: UInt8, r: UInt8) -> RGBColor {
    let candidates: [RGBColor] = [.red, .green, .blue, .white]
    func distance(_ c: RGBColor) -> Int {
      let dr = Int(c.r) - Int(r), dg = Int(c.g) - Int(g), db = Int(c.b) - Int(b)
      return dr * dr + dg * dg + db * db
    }
    return candidates.min(by: { distance($0) < distance($1) }) ?? .red
  }
}
