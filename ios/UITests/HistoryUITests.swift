import XCTest

/// History's cards: collapsed they are all one height, tapping the text shows all of it, Heard opens the words as
/// heard, Copy confirms, and Export is in the toolbar. Seeded with four dictations of very different lengths
/// (V2T_HISTORY), in a file of their own, so nothing needs the speech model.
@MainActor final class HistoryUITests: XCTestCase {
  let app = XCUIApplication.v2t()
  /// The Simulator's appearance, set from outside with `xcrun simctl ui <udid> appearance dark`; names the shots.
  var appearance: String { ProcessInfo.processInfo.environment["V2T_APPEARANCE"] ?? "light" }

  static let seed = """
    [{"id":"6F1C2A10-0000-4000-8000-000000000001","text":"Call me back after lunch.","date":"2026-11-12T18:40:00Z","language":"en",
      "timings":{"audio":2.1,"speech":0.08,"cleanup":0.62,"total":0.74,"piecesWhileRecording":0}},
     {"id":"6F1C2A10-0000-4000-8000-000000000002","text":"I went to the market on Saturday and they had run out of the good tomatoes again, so I bought peppers instead and made a stew that lasted the whole week. Next time I will go earlier in the morning, before the queue gets long, and I will bring the big bag so I can carry everything home on the bike without two trips. The man at the bread stall said they are opening a second shop near the station in December, which would save me the walk.",
      "heard":"I went to the market on Saturday and um they had run out of the good tomatoes again so I bought peppers instead and made a stew that lasted the whole week uh next time I will go earlier in the morning before the queue gets long and I will bring the big bag so I can carry everything home on the bike without two trips the man at the bread stall said they are opening a second shop near the station in December which would save me the walk",
      "date":"2026-11-12T18:12:00Z","language":"en",
      "timings":{"audio":98.4,"speech":0.12,"cleanup":1.74,"total":1.93,"piecesWhileRecording":9,"cleanedWhileRecording":3}},
     {"id":"6F1C2A10-0000-4000-8000-000000000003","text":"Remind me to send the invoice to Marta on Friday and to ask whether the meeting moved to Thursday.",
      "heard":"remind me to send the invoice to marta on friday and to ask whether the meeting moved to thursday",
      "date":"2026-11-11T09:05:00Z","language":"en",
      "timings":{"audio":6.3,"speech":0.1,"cleanup":0.95,"total":1.1,"piecesWhileRecording":1,"cleanedWhileRecording":0}},
     {"id":"6F1C2A10-0000-4000-8000-000000000004","text":"Mañana a las nueve en la estación.","date":"2026-11-10T07:30:00Z","language":"es"}]
    """

  /// History's cards only: the first page's rows stay in the tree under it.
  func card(_ i: Int) -> XCUIElement { app.cells.containing(.any, identifier: "v2t.history.text").element(boundBy: i) }
  func any(_ id: String, in e: XCUIElement) -> XCUIElement { e.descendants(matching: .any)[id].firstMatch }
  /// How many elements in `e` have this identifier or label (a scoped `firstMatch` found the other cards' too).
  func count(_ id: String, in e: XCUIElement) -> Int { e.descendants(matching: .any).matching(identifier: id).count }

  func openHistory() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_HISTORY"] = Self.seed
    app.launch()
    let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'History'")).firstMatch
    // a long first page at the largest text sizes: more swipes than `reveal` gives
    for _ in 0..<20 where !(link.exists && link.isHittable) { app.swipeUp(velocity: .slow) }
    XCTAssertEqual(link.label, "History (4)")
    link.tap()
    XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    XCTAssertTrue(card(0).waitForExistence(timeout: 5))
  }

  func testCardsAreOneHeightCollapsedAndOpenOnTap() {
    openHistory()
    // collapsed: a five-word, an 88-word and a 19-word dictation take the same height
    let heights = (0..<3).map { card($0).frame.height }
    XCTAssertEqual(heights[1], heights[0], accuracy: 1, "\(heights)")
    XCTAssertEqual(heights[2], heights[0], accuracy: 1, "\(heights)")
    // the figures, as VoiceOver reads them, and Heard only where the words were changed
    for label in ["88 words", "speech 0.1 seconds", "cleanup 1.7 seconds", "98 seconds spoken"] {
      XCTAssertTrue(any(label, in: card(1)).exists, "no \(label) on the long card")
    }
    XCTAssertEqual(count("v2t.history.heard", in: card(0)), 0, "Heard on a dictation nothing changed")
    XCTAssertEqual(count("v2t.history.heard", in: card(1)), 1)
    XCTAssertTrue(app.buttons["v2t.history.export"].isEnabled)
    shot("history-\(appearance)-collapsed")

    // the long card's text: tap to show all of it, and again to fold it
    let text = any("v2t.history.text", in: card(1))
    XCTAssertEqual(text.value as? String, "Collapsed")
    text.tap()
    XCTAssertEqual(text.value as? String, "Expanded")
    XCTAssertGreaterThan(card(1).frame.height, heights[1] + 80, "the text did not grow")
    sleep(1)  // the shot after the expand animation
    shot("history-\(appearance)-expanded")
    text.tap()
    XCTAssertEqual(card(1).frame.height, heights[1], accuracy: 1)

    // Heard on the third card opens what was heard, closed by default
    let heard = any("v2t.history.heard", in: card(2))
    XCTAssertEqual(count("v2t.history.heardText", in: card(2)), 0)
    heard.tap()
    XCTAssertEqual(heard.value as? String, "Shown")
    XCTAssertTrue(any("v2t.history.heardText", in: card(2)).waitForExistence(timeout: 2))
    sleep(1)
    shot("history-\(appearance)-heard-open")

    // Copy confirms in its own label
    let copy = any("v2t.history.copy", in: card(0))
    copy.tap()
    XCTAssertTrue(card(0).buttons["Copied"].waitForExistence(timeout: 2), app.debugDescription)

    // a dictation saved before timings shows its words only
    app.swipeUp(velocity: .slow)
    XCTAssertTrue(any("7 words", in: card(3)).exists)
    XCTAssertEqual(count("v2t.history.heard", in: card(3)), 0)
    XCTAssertEqual(card(3).descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH 'seconds spoken'")).count, 0)
    shot("history-\(appearance)-scrolled")
  }

  /// At the largest accessibility text size the figures wrap onto more lines, each whole and inside its card.
  func testFiguresWrapAtTheLargestTextSize() {
    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    openHistory()
    let c = card(0)  // the first: the cards below it are off screen and not yet drawn at this size
    let stats = ["5 words", "speech 0.1 seconds", "cleanup 0.6 seconds", "2.1 seconds spoken"].map { any($0, in: c) }
    for s in stats {
      XCTAssertTrue(s.exists, app.debugDescription)
      XCTAssertGreaterThanOrEqual(s.frame.minX, c.frame.minX)
      XCTAssertLessThanOrEqual(s.frame.maxX, c.frame.maxX, "\(s.label) runs past its card")
    }
    XCTAssertGreaterThan(Set(stats.map { Int($0.frame.minY) }).count, 1, "the figures stayed on one line")
    shot("history-\(appearance)-largest-text")
  }

  func testExportSharesTheHistory() {
    openHistory()
    let export = app.buttons["v2t.history.export"]
    XCTAssertTrue(export.isEnabled)
    export.tap()
    // the share sheet names the file it was handed
    let sheet = app.otherElements["ActivityListView"].firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
    shot("history-\(appearance)-export")
  }
}
