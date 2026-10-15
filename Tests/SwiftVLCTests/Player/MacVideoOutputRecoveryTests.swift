#if os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import CLibVLC
import CustomDump
import Testing

extension Logic {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct MacVideoOutputRecoveryTests {
    @Test
    func `waits for deselection before restoring the expected track`() async {
      var selections: [String?] = ["video", nil, nil]
      var events: [String] = []

      let outcome = await MacVideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: {
          events.append("current")
          return true
        },
        playbackState: {
          events.append("playing")
          return .playing
        },
        selectedTrackID: {
          let selection = selections.removeFirst()
          events.append("selected:\(selection ?? "none")")
          return selection
        },
        waitForDeselection: {
          events.append("wait")
        },
        reselectTrack: { trackID in
          events.append("reselect:\(trackID)")
        }
      ).run()

      #expect(outcome == .reselectSubmitted(deselectionObserved: true))
      expectNoDifference(
        events,
        [
          "current",
          "selected:video",
          "wait",
          "current",
          "selected:none",
          "current",
          "playing",
          "selected:none",
          "current",
          "reselect:video"
        ]
      )
    }

    @Test
    func `aborts when the media or native player changes while waiting`() async {
      var isCurrent = true
      var selectedTrack: String? = "video"
      var reselectedTracks: [String] = []

      let outcome = await MacVideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: { isCurrent },
        playbackState: { .playing },
        selectedTrackID: { selectedTrack },
        waitForDeselection: {
          selectedTrack = nil
          isCurrent = false
        },
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      #expect(outcome == .aborted)
      expectNoDifference(reselectedTracks, [])
    }

    @Test(
      arguments: [
        PlayerState.idle,
        .stopped,
        .stopping,
        .error,
      ]
    )
    func `does not restore video for terminal playback states`(state: PlayerState) async {
      var reselectedTracks: [String] = []

      let outcome = await MacVideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: { true },
        playbackState: { state },
        selectedTrackID: { nil },
        waitForDeselection: {},
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      #expect(outcome == .aborted)
      expectNoDifference(reselectedTracks, [])
    }

    @Test
    func `does not overwrite a different track selected during recovery`() async {
      var selections: [String?] = [nil, "replacement"]
      var reselectedTracks: [String] = []

      let outcome = await MacVideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: { true },
        playbackState: { .paused },
        selectedTrackID: { selections.removeFirst() },
        waitForDeselection: {},
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      #expect(outcome == .aborted)
      expectNoDifference(reselectedTracks, [])
    }

    @Test
    func `bounded polling still makes a final restore attempt`() async {
      var pollCount = 0
      var reselectedTracks: [String] = []

      let outcome = await MacVideoOutputRecovery(
        expectedTrackID: "video",
        maximumDeselectionPolls: 2,
        playbackIsCurrent: { true },
        playbackState: { .buffering },
        selectedTrackID: { "video" },
        waitForDeselection: { pollCount += 1 },
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      #expect(outcome == .reselectSubmitted(deselectionObserved: false))
      #expect(pollCount == 2)
      expectNoDifference(reselectedTracks, ["video"])
    }

    @Test
    func `cancellation during deselection prevents reselection`() async {
      var continuation: CheckedContinuation<Void, Never>?
      var reselectedTracks: [String] = []
      let task = Task { @MainActor in
        await MacVideoOutputRecovery(
          expectedTrackID: "video",
          playbackIsCurrent: { true },
          playbackState: { .playing },
          selectedTrackID: { "video" },
          waitForDeselection: {
            await withCheckedContinuation { continuation = $0 }
          },
          reselectTrack: { reselectedTracks.append($0) }
        ).run()
      }
      while continuation == nil { await Task.yield() }
      task.cancel()
      continuation?.resume()
      let outcome = await task.value
      #expect(outcome == .aborted)
      expectNoDifference(reselectedTracks, [])
    }

  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct MacVideoOutputRecoveryIntegrationTests {
    @Test
    func `player wrapper performs recovery through controlled native operations`() async throws {
      let player = Player(instance: TestInstance.shared)
      // These cases control media/state directly. Drain the native event
      // consumer before loading so its initial MediaChanged cannot replace
      // the exact Media wrapper while the controlled recovery is suspended.
      player.eventTask?.cancel()
      await player.eventTask?.value
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .playing)
      var selections: [String?] = ["video", "video", nil, nil]
      var events: [String] = []
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in
          let selection = selections.removeFirst()
          events.append("selected:\(selection ?? "none")")
          return selection
        },
        unselectVideoTrack: { _ in
          events.append("unselect")
        },
        reselectVideoTrack: { _, trackID in
          events.append("reselect:\(trackID)")
        },
        waitForDeselection: {
          events.append("wait")
        }
      )

      let activation = try #require(player.beginMacPiPOutputRebindActivation())
      #expect(player.macPiPOutputRebindSnapshot?.phase == .active)
      let recovery = try #require(
        player.reopenVideoOutputAfterDrawableWindowMove(
          using: native, nativePiPActivationRevision: activation
        )
      )
      #expect(player.macPiPOutputRebindSnapshot?.phase == .recovering)
      await recovery.value
      let snapshot = try #require(player.macPiPOutputRebindSnapshot)
      #expect(snapshot.activationRevision == activation)
      #expect(snapshot.playbackGeneration == player.generation)
      #expect(snapshot.nativeGeneration == player.nativeEventGeneration)
      #expect(snapshot.phase == .reselectSubmitted(deselectionObserved: true))

      expectNoDifference(
        events,
        [
          "selected:video",
          "unselect",
          "selected:video",
          "wait",
          "selected:none",
          "selected:none",
          "reselect:video"
        ]
      )
    }

    @Test
    func `player wrapper stops before unselecting when no video track is selected`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      var events: [String] = []
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in
          events.append("selected:none")
          return nil
        },
        unselectVideoTrack: { _ in events.append("unselect") },
        reselectVideoTrack: { _, _ in events.append("reselect") },
        waitForDeselection: { events.append("wait") }
      )

      let activation = try #require(player.beginMacPiPOutputRebindActivation())
      let recovery = player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: activation
      )
      #expect(player.macPiPOutputRebindSnapshot?.phase == .aborted)

      if recovery != nil {
        Issue.record("Expected recovery not to start without a selected video track")
      }
      expectNoDifference(events, ["selected:none"])
    }

    @Test(arguments: ["activation", "playback", "native", "abandoned", "cancelled"])
    func `pending recovery cannot mutate a successor owner`(change: String) async throws {
      let player = Player(instance: TestInstance.shared)
      // These cases control media/state directly. Drain the native event
      // consumer before loading so its initial MediaChanged cannot replace
      // the exact Media wrapper while the controlled recovery is suspended.
      player.eventTask?.cancel()
      await player.eventTask?.value
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .playing)
      let activation = try #require(player.beginMacPiPOutputRebindActivation())
      var continuation: CheckedContinuation<Void, Never>?
      var operations: [String] = []
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in "video" },
        unselectVideoTrack: { _ in operations.append("unselect") },
        reselectVideoTrack: { _, _ in operations.append("reselect") },
        waitForDeselection: {
          await withCheckedContinuation { continuation = $0 }
        }
      )
      let task = try #require(player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: activation
      ))
      while continuation == nil { await Task.yield() }
      switch change {
      case "activation":
        _ = try #require(player.beginMacPiPOutputRebindActivation())
      case "playback":
        try player.load(Media(url: TestMedia.twosecURL))
      case "native":
        try player.replaceNativePlayerForDrawablePlayback(target: nil)
      case "abandoned":
        player.updateMacPiPOutputRebind(activation, phase: .aborted)
      default:
        task.cancel()
      }
      let successor = player.macPiPOutputRebindSnapshot
      continuation?.resume()
      await task.value
      expectNoDifference(operations, ["unselect"])
      if change == "cancelled" {
        #expect(player.macPiPOutputRebindSnapshot?.playbackGeneration == player.generation)
        #expect(player.macPiPOutputRebindSnapshot?.nativeGeneration == player.nativeEventGeneration)
        #expect(player.nativeHandleRepresentsCurrentMedia)
        #expect(player.currentMedia != nil)
        #expect(!player.isShutdown)
        #expect(player.macPiPOutputRebindSnapshot?.phase == .aborted)
      } else {
        #expect(player.macPiPOutputRebindSnapshot == successor)
      }
    }

    @Test
    func `retained selection publishes bounded submission once without claiming output readiness`() async throws {
      let player = Player(instance: TestInstance.shared)
      // These cases control media/state directly. Drain the native event
      // consumer before loading so its initial MediaChanged cannot replace
      // the exact Media wrapper while the controlled recovery is suspended.
      player.eventTask?.cancel()
      await player.eventTask?.value
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused)
      let activation = try #require(player.beginMacPiPOutputRebindActivation())
      var operations: [String] = []
      var polls = 0
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in "video" },
        unselectVideoTrack: { _ in operations.append("unselect") },
        reselectVideoTrack: { _, _ in operations.append("reselect") },
        waitForDeselection: { polls += 1 }
      )
      let task = try #require(player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: activation
      ))
      #expect(player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: activation
      ) == nil)
      await task.value
      #expect(player.macPiPOutputRebindSnapshot?.phase == .reselectSubmitted(deselectionObserved: false))
      #expect(polls == 50)
      expectNoDifference(operations, ["unselect", "reselect"])
      #expect(player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: activation
      ) == nil)
      expectNoDifference(operations, ["unselect", "reselect"])
    }

    @Test
    func `missing media cannot arm an activation or invoke recovery native operations`() {
      let player = Player(instance: TestInstance.shared)
      #expect(player.beginMacPiPOutputRebindActivation() == nil)
      var operations: [String] = []
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in operations.append("selected"); return "video" },
        unselectVideoTrack: { _ in operations.append("unselect") },
        reselectVideoTrack: { _, _ in operations.append("reselect") },
        waitForDeselection: {}
      )
      #expect(player.reopenVideoOutputAfterDrawableWindowMove(using: native) == nil)
      expectNoDifference(operations, [])
    }

    @Test
    func `obsolete activation is rejected before native calls`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let first = try #require(player.beginMacPiPOutputRebindActivation())
      let second = try #require(player.beginMacPiPOutputRebindActivation())
      var operations: [String] = []
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in operations.append("selected"); return "video" },
        unselectVideoTrack: { _ in operations.append("unselect") },
        reselectVideoTrack: { _, _ in operations.append("reselect") },
        waitForDeselection: {}
      )
      #expect(player.reopenVideoOutputAfterDrawableWindowMove(
        using: native, nativePiPActivationRevision: first
      ) == nil)
      player.updateMacPiPOutputRebind(first, phase: .aborted)
      #expect(player.macPiPOutputRebindSnapshot?.activationRevision == second)
      #expect(player.macPiPOutputRebindSnapshot?.phase == .active)
      expectNoDifference(operations, [])
    }

    @Test
    func `live player wrapper exits safely without an active video output`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))

      let recovery = player.reopenVideoOutputAfterDrawableWindowMove()

      if recovery != nil {
        Issue.record("Expected recovery not to start without an active video output")
      }
    }

    @Test
    func `live native recovery operations are safe for an inactive player`() async {
      let player = Player(instance: TestInstance.shared)
      let native = MacVideoOutputRecoveryNativeOperations.live

      #expect(native.selectedTrackID(player.pointer) == nil)
      native.unselectVideoTrack(player.pointer)
      native.reselectVideoTrack(player.pointer, "video")
      await native.waitForDeselection()
    }

    @Test
    func `native track adapter adopts and returns a parsed track identifier`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      _ = try await media.parse()
      let trackList = try #require(
        libvlc_media_get_tracklist(media.pointer, libvlc_track_video)
      )
      defer { libvlc_media_tracklist_delete(trackList) }
      try #require(libvlc_media_tracklist_count(trackList) > 0)
      let track = try #require(libvlc_media_tracklist_at(trackList, 0))
      let id = try #require(track.pointee.psz_id)
      let expectedID = String(cString: id)
      let ownedTrack = try #require(libvlc_media_track_hold(track))

      #expect(nativeTrackID(adopting: ownedTrack) == expectedID)
    }
  }
}
#endif
