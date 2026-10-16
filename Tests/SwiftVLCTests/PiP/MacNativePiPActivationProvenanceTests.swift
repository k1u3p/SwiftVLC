#if os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AppKit
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct MacNativePiPActivationProvenanceTests {
    private func identity(of envelope: PiPEventEnvelope) throws -> MacPiPActivationIdentity {
      try #require(envelope.macPiPActivationIdentity)
    }

    private func makePlayer(instance: VLCInstance = TestInstance.shared) async throws -> Player {
      let player = Player(instance: instance)
      player.eventTask?.cancel()
      await player.eventTask?.value
      try player.load(Media(url: TestMedia.twosecURL))
      return player
    }

    private func activate(_ player: Player) throws -> MacPiPActivationIdentity {
      _ = try #require(player.beginMacPiPOutputRebindActivation())
      return try #require(player.macPiPOutputRebindSnapshot).activationIdentity
    }

    private func collect(_ count: Int, from stream: AsyncStream<PiPEventEnvelope>) async -> [PiPEventEnvelope] {
      await withTaskGroup(of: [PiPEventEnvelope].self) { group in
        group.addTask {
          var events: [PiPEventEnvelope] = []
          for await event in stream {
            events.append(event)
            if events.count == count { break }
          }
          return events
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(2))
          return []
        }
        let events = await group.next() ?? []
        group.cancelAll()
        return events
      }
    }

    private func currentSnapshot(of controller: PiPController) async throws -> PiPSnapshot {
      var iterator = controller.pipSnapshots.makeAsyncIterator()
      return try #require(await iterator.next())
    }

    @Test
    func `queued same-media activations retain the identity captured at their source`() async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let first = try activate(player)
      backend.setActive(true)
      backend.setActive(false)
      let second = try activate(player)
      backend.setActive(true)

      let events = await collect(3, from: stream)
      try #require(events.count == 3)
      #expect(first.activationRevision != second.activationRevision)
      #expect(try identity(of: events[0]) == first)
      #expect(try identity(of: events[1]) == first)
      #expect(try identity(of: events[2]) == second)
      #expect(controller.isActive)
      backend.setActive(false)
    }

    @Test
    func `queued historical start and stop publish the final inactive snapshot once`() async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let before = try await currentSnapshot(of: controller)
      let activation = try activate(player)
      backend.setActive(true)
      backend.setActive(false)

      let events = await collect(2, from: stream)
      let after = try await currentSnapshot(of: controller)
      try #require(events.count == 2)
      #expect(!controller.isActive)
      #expect(!after.isActive)
      #expect(after.revision == before.revision + 1)
      #expect(try identity(of: events[0]) == activation)
      #expect(try identity(of: events[1]) == activation)
    }

    @Test
    func `retained controller final inactive snapshot refreshes the successor media generation`() async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let before = try await currentSnapshot(of: controller)
      try player.load(Media(url: TestMedia.silenceURL))
      let activation = try activate(player)
      backend.setActive(true)
      backend.setActive(false)

      let events = await collect(2, from: stream)
      let after = try await currentSnapshot(of: controller)
      try #require(events.count == 2)
      #expect(activation.playbackGeneration == player.generation)
      #expect(activation.playbackGeneration != before.mediaGeneration)
      #expect(try identity(of: events[0]) == activation)
      #expect(try identity(of: events[1]) == activation)
      #expect(!controller.isActive)
      #expect(!after.isActive)
      #expect(after.mediaGeneration == player.generation)
      #expect(after.revision == before.revision + 1)
    }

    @Test
    func `controller reconstruction preserves queued source activation identities`() async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let original = PiPController(player: player, nativeBackend: backend)
      let first = try activate(player)
      backend.setActive(true)
      backend.setActive(false)
      let successor = PiPController(player: player, nativeBackend: backend)
      let stream = successor.pipEventEnvelopes
      let second = try activate(player)
      backend.setActive(true)

      let events = await collect(3, from: stream)
      try #require(events.count == 3)
      #expect(backend.owner === successor)
      #expect(try identity(of: events[0]) == first)
      #expect(try identity(of: events[1]) == first)
      #expect(try identity(of: events[2]) == second)
      backend.setActive(false)
      withExtendedLifetime(original) {}
    }

    @Test(arguments: ["media", "native"])
    func `queued transitions retain original generations after player replacement`(replacement: String) async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let first = try activate(player)
      backend.setActive(true)
      backend.setActive(false)
      if replacement == "media" {
        try player.load(Media(url: TestMedia.silenceURL))
      } else {
        try player.replaceNativePlayerForDrawablePlayback(target: nil)
      }
      let second = try activate(player)
      backend.setActive(true)

      let events = await collect(3, from: stream)
      try #require(events.count == 3)
      if replacement == "media" {
        #expect(first.playbackGeneration != second.playbackGeneration)
      } else {
        #expect(first.nativeGeneration != second.nativeGeneration)
      }
      #expect(try identity(of: events[0]) == first)
      #expect(try identity(of: events[1]) == first)
      #expect(try identity(of: events[2]) == second)
      backend.setActive(false)
    }

    @Test(arguments: [false, true])
    func `real presenter start returns its source identity and retains it through close`(reenters: Bool) async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-audio", "--quiet"])
      let player = try await makePlayer(instance: instance)
      let host = MacNativePiPHostView()
      let probe = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(pictureInPictureViewControllerFactory: { probe })
      let backend = MacNativePiPBackend(presenter: presenter, runtimeIsAvailable: { true })
      backend.adopt(hostView: host, drawableView: host.drawableView)
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      var sourceIdentity: MacPiPActivationIdentity?
      probe.onPresent = {
        sourceIdentity = player.macPiPOutputRebindSnapshot?.activationIdentity
        if reenters {
          _ = player.beginMacPiPOutputRebindActivation()
        }
      }
      let initialPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = true
      let result = controller.requestStart()
      PiPController.allowsPrivateMacOSAPI = initialPrivateAPI
      probe.onPresent = nil

      #expect(result == .accepted)
      let source = try #require(sourceIdentity)
      #expect(controller.macPiPStartActivationIdentity == source)
      if reenters {
        #expect(player.macPiPOutputRebindSnapshot?.activationIdentity != source)
      }
      let starts = await collect(1, from: stream)
      try #require(starts.count == 1)
      #expect(try identity(of: starts[0]) == source)

      let delegate = try #require(probe.delegate as? MacPrivatePiPDelegate)
      backend.stop()
      delegate.didClose()
      #expect(controller.macPiPStartActivationIdentity == source)
      let stops = await collect(1, from: stream)
      try #require(stops.count == 1)
      #expect(try identity(of: stops[0]) == source)
      #expect(controller.macPiPStartActivationIdentity == source)

      PiPController.allowsPrivateMacOSAPI = false
      let refused = controller.requestStart()
      PiPController.allowsPrivateMacOSAPI = initialPrivateAPI
      #expect(refused == .notPossible)
      #expect(controller.macPiPStartActivationIdentity == nil)
    }

    @Test
    func `busy reentry preserves native PiP capability and permits retry after reselection`() async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-audio", "--quiet"])
      let player = try await makePlayer(instance: instance)
      player._setStateForTesting(state: .playing)
      let host = MacNativePiPHostView()
      let probe = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(pictureInPictureViewControllerFactory: { probe })
      let backend = MacNativePiPBackend(presenter: presenter, runtimeIsAvailable: { true })
      let initialPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = true
      backend.adopt(hostView: host, drawableView: host.drawableView)
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      #expect(controller.isPossible)
      let activation = try #require(player.beginMacPiPOutputRebindActivation())
      var selectedTrack: String? = "video"
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in selectedTrack },
        unselectVideoTrack: { _ in selectedTrack = nil },
        reselectVideoTrack: { _, id in selectedTrack = id },
        waitForDeselection: {}
      )
      let returning = try #require(player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: activation
      ))
      let recovering = player.macPiPOutputRebindSnapshot

      let refused = controller.requestStart()

      #expect(refused == .notPossible)
      #expect(backend.isPossible)
      #expect(backend.owner === controller)
      #expect(controller.macPiPStartActivationIdentity == nil)
      #expect(player.macPiPOutputRebindSnapshot == recovering)
      #expect(selectedTrack == nil)
      #expect(probe.presentCount == 0)
      await returning.value
      await Task.yield()
      #expect(controller.isPossible)
      #expect(selectedTrack == "video")

      let retry = controller.requestStart()

      #expect(retry == .accepted)
      #expect(backend.isPossible)
      #expect(controller.macPiPStartActivationIdentity?.activationRevision != activation)
      #expect(probe.presentCount == 1)
      let delegate = try #require(probe.delegate as? MacPrivatePiPDelegate)
      delegate.didClose()
    }

    @Test
    func `retired and closed presenter delegates cannot control a successor`() async throws {
      let player = try await makePlayer()
      let host = MacNativePiPHostView()
      let probe = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(pictureInPictureViewControllerFactory: { probe })
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player
      var actions: [String] = []
      func start(_ label: String) -> Bool {
        presenter.start(
          player: player,
          hostView: host,
          drawableView: host.drawableView,
          mediaController: mediaController,
          onActiveChanged: { _, _ in },
          onPlay: { actions.append("\(label):play") },
          onPause: { actions.append("\(label):pause") }
        )
      }
      try #require(start("A"))
      let retired = try #require(probe.delegate as? MacPrivatePiPDelegate)
      retired.didClose()
      try #require(start("B"))
      let current = try #require(probe.delegate as? MacPrivatePiPDelegate)

      retired.play()
      retired.pause()
      retired.stop()
      #expect(actions.isEmpty)
      actions.removeAll()
      current.play()
      current.pause()
      current.stop()
      #expect(actions == ["B:play", "B:pause", "B:pause"])
      current.willClose()
      current.pause()
      #expect(actions == ["B:play", "B:pause", "B:pause", "B:pause"])
      current.didClose()
      actions.removeAll()
      retired.play()
      retired.pause()
      retired.stop()
      current.play()
      current.pause()
      current.stop()
      #expect(actions.isEmpty)
    }

    @Test
    func `displaced controller cannot clear or stop its successors accepted activation`() async throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-audio", "--quiet"])
      let player = try await makePlayer(instance: instance)
      let host = MacNativePiPHostView()
      let probe = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(pictureInPictureViewControllerFactory: { probe })
      let backend = MacNativePiPBackend(presenter: presenter, runtimeIsAvailable: { true })
      backend.adopt(hostView: host, drawableView: host.drawableView)
      backend.attach(to: player)
      let original = PiPController(player: player, nativeBackend: backend)
      let successor = PiPController(player: player, nativeBackend: backend)
      let stream = successor.pipEventEnvelopes
      let initialPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = true
      let accepted = successor.requestStart()
      PiPController.allowsPrivateMacOSAPI = false
      let refused = original.requestStart()
      PiPController.allowsPrivateMacOSAPI = initialPrivateAPI

      #expect(accepted == .accepted)
      let source = try #require(player.macPiPOutputRebindSnapshot?.activationIdentity)
      #expect(refused == .backendUnavailable)
      #expect(original.macPiPStartActivationIdentity == nil)
      #expect(successor.macPiPStartActivationIdentity == source)
      original.stop()
      #expect(probe.dismissCount == 0)
      #expect(backend.isActive)
      let starts = await collect(1, from: stream)
      try #require(starts.count == 1)
      #expect(try identity(of: starts[0]) == source)
      #expect(successor.macPiPStartActivationIdentity == source)
      #expect(successor.isActive)
      #expect(probe.dismissCount == 0)

      let delegate = try #require(probe.delegate as? MacPrivatePiPDelegate)
      backend.stop()
      delegate.didClose()
      #expect(successor.macPiPStartActivationIdentity == source)
    }

    @Test
    func `explicit stop from a retired activation cannot cancel the active successor`() async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let first = try activate(player)
      backend.setActive(true, activationIdentity: first, sourcePlayer: player)
      backend.setActive(false, activationIdentity: first, sourcePlayer: player)
      let second = try activate(player)
      backend.setActive(true, activationIdentity: second, sourcePlayer: player)

      backend.setActive(false, activationIdentity: first, sourcePlayer: player)

      #expect(backend.isActive)
      let events = await collect(3, from: stream)
      try #require(events.count == 3)
      #expect(controller.isActive)
      #expect(try identity(of: events[2]) == second)
      backend.setActive(false, activationIdentity: second, sourcePlayer: player)
    }

    @Test
    func `late and duplicate starts cannot resurrect completed activation signals`() async throws {
      let player = try await makePlayer()
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)
      let stream = controller.pipEventEnvelopes
      let first = try activate(player)
      backend.setActive(true, activationIdentity: first, sourcePlayer: player)
      backend.setActive(false, activationIdentity: first, sourcePlayer: player)
      let second = try activate(player)
      backend.setActive(true, activationIdentity: second, sourcePlayer: player)
      backend.setActive(false, activationIdentity: second, sourcePlayer: player)

      backend.setActive(true, activationIdentity: first, sourcePlayer: player)
      backend.setActive(true, activationIdentity: second, sourcePlayer: player)

      #expect(!backend.isActive)
      let events = await collect(4, from: stream)
      try #require(events.count == 4)
      #expect(try identity(of: events[0]) == first)
      #expect(try identity(of: events[1]) == first)
      #expect(try identity(of: events[2]) == second)
      #expect(try identity(of: events[3]) == second)
      #expect(!controller.isActive)
      #expect(!(try await currentSnapshot(of: controller)).isActive)
    }
  }
}
#endif
