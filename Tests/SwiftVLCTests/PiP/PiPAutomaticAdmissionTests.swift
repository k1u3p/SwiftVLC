#if os(iOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import CLibVLC
import Testing
import UIKit

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPAutomaticAdmissionTests {
    @Test
    func `native admission preserves drawable and rejects displaced or invalidated owner`() throws {
      let player = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView(startsAutomaticallyFromInline: false)
      host.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
      host.layoutIfNeeded()
      host.attach(to: player)
      let backend = host.nativePiPBackend
      let attachment = try #require(host.drawableView.drawableAttachment)
      let pointer = player.pointer
      let nativeDrawable = try #require(libvlc_media_player_get_nsobject(pointer))
      let generation = player.generation
      let original = PiPController(
        player: player, nativeBackend: backend,
        startsAutomaticallyFromInline: false, managesAudioSession: false
      )
      defer { host.detach() }

      #expect(original.setStartsAutomaticallyFromInline(true))
      #expect(original.startsAutomaticallyFromInline)
      #expect(backend.startsAutomaticallyFromInline)
      // libVLC snapshots this immutable selector before the asynchronous
      // main-actor ready callback. It must stay false even after admission.
      #expect(attachment.canStartPictureInPictureAutomaticallyFromInline() == false)

      let successor = PiPController(
        player: player, nativeBackend: backend,
        startsAutomaticallyFromInline: true, managesAudioSession: false
      )
      #expect(original.setStartsAutomaticallyFromInline(false) == false)
      #expect(original.startsAutomaticallyFromInline)
      #expect(backend.startsAutomaticallyFromInline)
      #expect(successor.setStartsAutomaticallyFromInline(false))
      #expect(backend.startsAutomaticallyFromInline == false)
      #expect(successor.setStartsAutomaticallyFromInline(true))

      successor.invalidateForLifecycleEnd()
      #expect(successor.setStartsAutomaticallyFromInline(false) == false)
      #expect(successor.startsAutomaticallyFromInline)
      #expect(backend.startsAutomaticallyFromInline)
      #expect(player.pointer == pointer)
      #expect(player.generation == generation)
      #expect(libvlc_media_player_get_nsobject(pointer) == nativeDrawable)
      #expect(player.drawable === attachment)
      #expect(host.drawableView.drawableAttachment === attachment)
      #expect(original.isActive == false)
      #expect(successor.isActive == false)
      #expect(player.isPlaybackRequestedActive == false)
    }

    @Test
    func `detached native controller cannot change cached admission`() {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(
        player: player, nativeBackend: backend,
        startsAutomaticallyFromInline: false, managesAudioSession: false
      )
      backend.detach()

      #expect(controller.setStartsAutomaticallyFromInline(true) == false)
      #expect(controller.startsAutomaticallyFromInline == false)
      #expect(backend.startsAutomaticallyFromInline == false)
    }

    @Test
    func `direct public controller updates admission without rebinding video callbacks`() throws {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let registration = try #require(controller.callbackRegistration)
      let slot = try #require(registration.currentSlot)
      let avController = controller.pipController

      #expect(controller.setStartsAutomaticallyFromInline(false))
      #expect(controller.startsAutomaticallyFromInline == false)
      if let avController {
        #expect(avController.canStartPictureInPictureAutomaticallyFromInline == false)
      }
      #expect(controller.setStartsAutomaticallyFromInline(true))
      if let avController {
        #expect(avController.canStartPictureInPictureAutomaticallyFromInline)
      }
      #expect(controller.pipController === avController)
      #expect(registration.currentSlot === slot)
      #expect(controller.isActive == false)
      #expect(player.isPlaybackRequestedActive == false)

      controller.invalidateForLifecycleEnd()
      #expect(controller.setStartsAutomaticallyFromInline(false) == false)
      #expect(controller.startsAutomaticallyFromInline)
    }

    #if !targetEnvironment(simulator)
    // Native sample-buffer PiP is deliberately unavailable on the simulator.
    // Exercise actual AVKit policy through the production backend on device.
    @Test(.enabled(
      if: AVPictureInPictureController.isPictureInPictureSupported(),
      "Requires native AVKit Picture in Picture support"
    ))
    func `late native readiness and controller replacement use latest admission`() throws {
      let player = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView(startsAutomaticallyFromInline: false)
      host.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
      host.layoutIfNeeded()
      host.attach(to: player)
      let backend = host.nativePiPBackend
      let attachment = try #require(host.drawableView.drawableAttachment)
      let controller = PiPController(
        player: player, nativeBackend: backend,
        startsAutomaticallyFromInline: false, managesAudioSession: false
      )
      defer { host.detach() }
      let content = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(),
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let first = AutomaticAdmissionWindowProbe(content: content)
      let replacement = AutomaticAdmissionWindowProbe(content: content)
      #expect(first.avPipController.canStartPictureInPictureAutomaticallyFromInline == false)
      #expect(controller.setStartsAutomaticallyFromInline(true))
      backend.handlePictureInPictureReady(first)
      #expect(first.avPipController.canStartPictureInPictureAutomaticallyFromInline)

      #expect(controller.setStartsAutomaticallyFromInline(false))
      #expect(first.avPipController.canStartPictureInPictureAutomaticallyFromInline == false)
      let callbackAttachment = try #require(backend.callbackGenerations.currentAttachment())
      let stale = try #require(backend.callbackGenerations.reserveReadyCallback(for: callbackAttachment))
      let current = try #require(backend.callbackGenerations.reserveReadyCallback(for: callbackAttachment))
      backend.handlePictureInPictureReady(
        replacement, generation: current, mediaGeneration: player.generation
      )
      #expect(replacement.avPipController.canStartPictureInPictureAutomaticallyFromInline == false)
      #expect(controller.setStartsAutomaticallyFromInline(true))
      #expect(replacement.avPipController.canStartPictureInPictureAutomaticallyFromInline)

      backend.handlePictureInPictureReady(first, generation: stale, mediaGeneration: player.generation)
      #expect(first.avPipController.canStartPictureInPictureAutomaticallyFromInline == false)
      let successor = PiPController(
        player: player, nativeBackend: backend,
        startsAutomaticallyFromInline: true, managesAudioSession: false
      )
      #expect(controller.setStartsAutomaticallyFromInline(false) == false)
      #expect(controller.startsAutomaticallyFromInline)
      #expect(backend.startsAutomaticallyFromInline)
      #expect(replacement.avPipController.canStartPictureInPictureAutomaticallyFromInline)
      #expect(successor.setStartsAutomaticallyFromInline(false))
      #expect(replacement.avPipController.canStartPictureInPictureAutomaticallyFromInline == false)
      #expect(attachment.canStartPictureInPictureAutomaticallyFromInline() == false)
      #expect(player.drawable === attachment)
      #expect(controller.isActive == false)
      #expect(player.isPlaybackRequestedActive == false)
    }
    #endif
  }
}

#if !targetEnvironment(simulator)
@MainActor
private final class AutomaticAdmissionWindowProbe: NSObject {
  @objc let avPipController: AVPictureInPictureController

  init(content: AVPictureInPictureController.ContentSource) {
    avPipController = AVPictureInPictureController(contentSource: content)
    avPipController.canStartPictureInPictureAutomaticallyFromInline = false
    super.init()
  }
}
#endif
#endif
