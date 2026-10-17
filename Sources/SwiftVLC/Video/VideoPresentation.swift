import CLibVLC
import CoreGraphics

/// How the selected video track is meant to be displayed, as libVLC reports it.
///
/// ``Player/videoSize`` is the decoded picture in stored pixels. The picture
/// libVLC puts on screen also applies the track's pixel (sample) aspect ratio
/// and orientation, so for anamorphic or rotated media the two shapes differ:
/// a 720 × 480 track with 8:9 pixels is shown at 4:3, not at 3:2.
public struct VideoPresentation: Sendable, Hashable {
  /// The sample (pixel) aspect ratio as the track reported it.
  public struct SampleAspectRatio: Sendable, Hashable {
    public let numerator: UInt32
    public let denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
      self.numerator = numerator
      self.denominator = denominator
    }
  }

  /// A track's orientation, mirroring libVLC's `libvlc_video_orient_t`.
  public enum Orientation: Sendable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight
    case leftTop, leftBottom, rightTop, rightBottom

    /// Whether the orientation exchanges the picture's horizontal and
    /// vertical axes (a transpose or a quarter turn).
    public var swapsAxes: Bool {
      switch self {
      case .topLeft, .topRight, .bottomLeft, .bottomRight: false
      case .leftTop, .leftBottom, .rightTop, .rightBottom: true
      }
    }

    init(_ native: libvlc_video_orient_t) {
      switch native {
      case libvlc_video_orient_top_right: self = .topRight
      case libvlc_video_orient_bottom_left: self = .bottomLeft
      case libvlc_video_orient_bottom_right: self = .bottomRight
      case libvlc_video_orient_left_top: self = .leftTop
      case libvlc_video_orient_left_bottom: self = .leftBottom
      case libvlc_video_orient_right_top: self = .rightTop
      case libvlc_video_orient_right_bottom: self = .rightBottom
      default: self = .topLeft
      }
    }
  }

  /// The decoded size in stored pixels, before pixel aspect and orientation.
  public let size: CGSize
  /// The reported pixel aspect ratio, or `nil` when the track left it
  /// unspecified (a zero numerator or denominator), which libVLC treats as square.
  public let sampleAspectRatio: SampleAspectRatio?
  public let orientation: Orientation

  public init(size: CGSize, sampleAspectRatio: SampleAspectRatio?, orientation: Orientation) {
    self.size = size
    self.sampleAspectRatio = sampleAspectRatio
    self.orientation = orientation
  }

  /// The displayed width over height: stored width times pixel aspect over
  /// stored height, inverted when the orientation exchanges the axes. `nil`
  /// when the size is unusable, so no caller divides by zero or sees a
  /// non-finite value.
  public var displayAspectRatio: Double? {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
    var aspect = Double(size.width) / Double(size.height)
    if let sar = sampleAspectRatio, sar.numerator > 0, sar.denominator > 0 {
      aspect *= Double(sar.numerator) / Double(sar.denominator)
    }
    if orientation.swapsAxes { aspect = 1 / aspect }
    return aspect.isFinite && aspect > 0 ? aspect : nil
  }
}

extension Player {
  /// The selected video track's decoded size, pixel aspect ratio and orientation.
  ///
  /// Read live from the same selected-track observation as ``videoSize``, with
  /// the same current-media guard, so the three values always describe one
  /// track and never a stale mirror combined with a live size. `nil` while no
  /// video track is selected or before the decoder has published a size.
  /// Observers are re-signaled on the same events as ``videoSize``.
  public var videoPresentation: VideoPresentation? {
    access(keyPath: \.videoSize)
    guard nativeHandleRepresentsCurrentMedia else { return nil }
    guard let track = libvlc_media_player_get_selected_track(pointer, libvlc_track_video) else { return nil }
    defer { libvlc_media_track_release(track) }
    guard track.pointee.i_type == libvlc_track_video, track.pointee.video != nil else { return nil }
    let video = track.pointee.video.pointee
    guard video.i_width > 0, video.i_height > 0 else { return nil }
    return VideoPresentation(
      size: CGSize(width: Int(video.i_width), height: Int(video.i_height)),
      sampleAspectRatio: video.i_sar_num > 0 && video.i_sar_den > 0
        ? .init(numerator: video.i_sar_num, denominator: video.i_sar_den)
        : nil,
      orientation: .init(video.i_orientation)
    )
  }
}
