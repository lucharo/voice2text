import CoreGraphics
import Testing
@testable import V2TKeyboardCore

@Suite("RecordingUIStateTests")
struct RecordingUIStateTests {
  @Test func startsCompactWithKeysVisibleAndAudioClicksMutedWhileListening() {
    var ui = RecordingUIState()
    #expect(!ui.active)
    #expect(!ui.hidesKeyboard)
    #expect(!ui.mutesKeyClicks)
    #expect(ui.micKeyVisual == .idle)

    ui.update(active: true, listening: true)

    #expect(ui.presentation == .compact)
    #expect(ui.showsCompactBar)
    #expect(!ui.showsExpandedPanel)
    #expect(!ui.hidesKeyboard)
    #expect(ui.hidesSuggestionBar)
    #expect(ui.mutesKeyClicks)
    #expect(!ui.isModal)
    #expect(ui.micKeyVisual == .listening)
  }

  @Test func expandAndCollapsePreserveModeAcrossWaitingAndResetOnEnd() {
    var ui = RecordingUIState()
    ui.update(active: true, listening: true)
    ui.expand()
    #expect(ui.showsExpandedPanel)
    #expect(ui.hidesKeyboard)
    #expect(ui.isModal)

    // Transitioning from listening -> transcribing preserves expanded mode and unmutes clicks.
    ui.update(active: true, listening: false)
    #expect(ui.showsExpandedPanel)
    #expect(!ui.mutesKeyClicks)
    #expect(ui.micKeyVisual == .busy)

    ui.togglePresentation()
    #expect(ui.showsCompactBar)
    #expect(!ui.hidesKeyboard)

    ui.expand()
    #expect(ui.showsExpandedPanel)

    // Ending the session resets back to compact for the next dictation.
    ui.update(active: false, listening: false)
    #expect(ui.presentation == .compact)
    #expect(ui.micKeyVisual == .idle)
    #expect(!ui.hidesKeyboard)
  }

  @Test func typingWhileListeningAutoInsertsButTypingWhileWaitingOffersBanner() {
    var ui = RecordingUIState()
    ui.update(active: true, listening: true)
    ui.noteUserTyped()  // typing while recording is normal and must not block auto-insert
    ui.update(active: true, listening: false)
    #expect(!ui.typedWhileWaiting)

    let immediate = ui.receiveTranscript("hello world")
    #expect(immediate == .insertImmediately("hello world"))
    #expect(ui.pendingTranscript == nil)

    // New dictation where user types *after* Done while waiting.
    ui.update(active: false, listening: false)
    ui.update(active: true, listening: true)
    ui.update(active: true, listening: false)
    ui.noteUserTyped()
    #expect(ui.typedWhileWaiting)

    // Even if onState(.idle) runs before onText arrives, typedWhileWaiting must survive to trigger banner.
    ui.update(active: false, listening: false)
    let delivery = ui.receiveTranscript("second note")
    #expect(delivery == .offerBanner("second note"))
    #expect(ui.pendingTranscript == "second note")
    #expect(ui.acceptPendingTranscript() == "second note")
    #expect(ui.pendingTranscript == nil)

    // Dismissing clears pending transcript.
    ui.update(active: true, listening: true)
    ui.update(active: true, listening: false)
    ui.noteUserTyped()
    _ = ui.receiveTranscript("discard me")
    ui.dismissPendingTranscript()
    #expect(ui.pendingTranscript == nil)
  }
}

@Suite("CompactBarGeometryTests")
struct CompactBarGeometryTests {
  @Test func framesStayInsideBoundsAndNeverOverlapAcrossDeviceWidths() {
    let widths: [CGFloat] = [320, 375, 390, 430, 768, 1024]
    let height: CGFloat = 44
    let statusSize = CGSize(width: 42, height: 17)
    let longMicSize = CGSize(width: 240, height: 14)

    for w in widths {
      let bounds = CGRect(x: 0, y: 0, width: w, height: height)

      // 1. Listening with a long microphone name
      let gMic = CompactBarGeometry.compute(
        size: bounds.size, listening: true, statusSize: statusSize, micSize: longMicSize, hasMic: true, doneWidth: 74)
      let itemsMic = [gMic.cancel, gMic.status, gMic.mic, gMic.wave, gMic.expandButton, gMic.done]
      for r in itemsMic {
        #expect(r.width > 0 && r.height > 0)
        #expect(bounds.contains(r))
      }
      for i in 0..<itemsMic.count {
        for j in (i + 1)..<itemsMic.count {
          #expect(!itemsMic[i].intersects(itemsMic[j]))
        }
      }
      #expect(!gMic.dot.intersects(gMic.status))
      #expect(!gMic.dot.intersects(gMic.mic))
      #expect(gMic.wave.width >= 40)

      // 2. Listening without a microphone label
      let gNoMic = CompactBarGeometry.compute(
        size: bounds.size, listening: true, statusSize: statusSize, micSize: .zero, hasMic: false, doneWidth: 74)
      let itemsNoMic = [gNoMic.cancel, gNoMic.status, gNoMic.wave, gNoMic.expandButton, gNoMic.done]
      for r in itemsNoMic {
        #expect(r.width > 0 && r.height > 0)
        #expect(bounds.contains(r))
      }
      #expect(gNoMic.mic == .zero)
      #expect(gNoMic.wave.width >= 40)

      // 3. Transcribing / cleaning up
      let gWait = CompactBarGeometry.compute(
        size: bounds.size, listening: false, statusSize: CGSize(width: 120, height: 17), micSize: .zero, hasMic: false, doneWidth: 74)
      let itemsWait = [gWait.cancel, gWait.spinner, gWait.status, gWait.expandButton]
      for r in itemsWait {
        #expect(r.width > 0 && r.height > 0)
        #expect(bounds.contains(r))
      }
      for i in 0..<itemsWait.count {
        for j in (i + 1)..<itemsWait.count {
          #expect(!itemsWait[i].intersects(itemsWait[j]))
        }
      }
    }
  }
}
