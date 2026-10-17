@testable import SwiftVLC
import CoreGraphics
import Foundation
import Testing

/// The displayed shape of a video track: stored size, pixel aspect ratio and
/// orientation. The derivation is pure, so it is covered without a decoder.
struct VideoPresentationTests {
  private func presentation(
    _ width: CGFloat, _ height: CGFloat,
    sar: (UInt32, UInt32)? = nil,
    _ orientation: VideoPresentation.Orientation = .topLeft
  ) -> VideoPresentation {
    VideoPresentation(
      size: CGSize(width: width, height: height),
      sampleAspectRatio: sar.map { .init(numerator: $0.0, denominator: $0.1) },
      orientation: orientation
    )
  }

  @Test
  func `square pixels display at the stored shape`() throws {
    let aspect = try #require(presentation(1920, 1080, sar: (1, 1)).displayAspectRatio)
    #expect(abs(aspect - 16.0 / 9.0) < 1e-9)
  }

  @Test
  func `a pixel aspect ratio above one widens the display`() throws {
    // 720 x 480 with 32:27 pixels is anamorphic 16:9.
    let aspect = try #require(presentation(720, 480, sar: (32, 27)).displayAspectRatio)
    #expect(abs(aspect - 16.0 / 9.0) < 1e-9)
  }

  @Test
  func `a pixel aspect ratio below one narrows the display`() throws {
    // 720 x 480 with 8:9 pixels is shown at 4:3, not at the stored 3:2.
    let aspect = try #require(presentation(720, 480, sar: (8, 9)).displayAspectRatio)
    #expect(abs(aspect - 4.0 / 3.0) < 1e-9)
  }

  @Test
  func `an unspecified pixel aspect ratio is treated as square`() throws {
    for sar: (UInt32, UInt32)? in [nil, (0, 1), (1, 0), (0, 0)] {
      let aspect = try #require(presentation(720, 480, sar: sar).displayAspectRatio)
      #expect(abs(aspect - 3.0 / 2.0) < 1e-9, "\(String(describing: sar))")
    }
  }

  @Test(arguments: [
    VideoPresentation.Orientation.leftTop, .leftBottom, .rightTop, .rightBottom
  ])
  func `a quarter turn exchanges the axes`(orientation: VideoPresentation.Orientation) throws {
    #expect(orientation.swapsAxes)
    let aspect = try #require(presentation(1920, 1080, orientation).displayAspectRatio)
    #expect(abs(aspect - 9.0 / 16.0) < 1e-9)
  }

  @Test(arguments: [
    VideoPresentation.Orientation.topLeft, .topRight, .bottomLeft, .bottomRight
  ])
  func `a flip or half turn keeps the axes`(orientation: VideoPresentation.Orientation) throws {
    #expect(!orientation.swapsAxes)
    let aspect = try #require(presentation(1920, 1080, orientation).displayAspectRatio)
    #expect(abs(aspect - 16.0 / 9.0) < 1e-9)
  }

  @Test
  func `pixel aspect and a quarter turn compose once`() throws {
    // 8:9 pixels give 4:3; the quarter turn inverts that, applying neither twice.
    let aspect = try #require(presentation(720, 480, sar: (8, 9), .rightTop).displayAspectRatio)
    #expect(abs(aspect - 3.0 / 4.0) < 1e-9)
  }

  @Test
  func `unusable sizes yield no aspect and never a non-finite value`() {
    #expect(presentation(0, 480).displayAspectRatio == nil)
    #expect(presentation(720, 0).displayAspectRatio == nil)
    #expect(presentation(-1, 480).displayAspectRatio == nil)
    #expect(presentation(.nan, 480).displayAspectRatio == nil)
    #expect(presentation(.infinity, 480).displayAspectRatio == nil)
  }
}
