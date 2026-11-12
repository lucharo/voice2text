import XCTest

/// The typing exercise (Debugging › Typing exercise): it turns the debug log on, shows a sentence, the v2t
/// keyboard types it, and Next moves on. `testAWholeExercise` types all ten sentences with the aim a little off
/// and some letters on the neighbouring key, and leaves the log and its exercise lines in the Simulator's App
/// Group: that is what `ios/tools/kb_log_report.py` and `LogReplayEval` were tried on.
@MainActor final class TypingExerciseUITests: XCTestCase {
  let app = XCUIApplication.v2t()

  func key(_ id: String) -> XCUIElement { app.descendants(matching: .any)["key.\(id)"] }
  var field: XCUIElement { app.textFields["v2t.exercise.field"] }
  var sentence: String { app.staticTexts["v2t.exercise.sentence"].label.replacingOccurrences(of: "Type: ", with: "") }
  var progress: String { app.staticTexts["v2t.exercise.progress"].label }

  func launch() {
    continueAfterFailure = false
    app.launchEnvironment["V2T_LAYOUT"] = "en"
    app.launchEnvironment["V2T_EXERCISE_LANGUAGES"] = "en"  // the Spanish sentences need accents from a long press
    app.launchEnvironment["V2T_RESET_DICTIONARY"] = "1"
    app.launchEnvironment["V2T_RESET_KEYBOARD_LOG"] = "1"  // the log off and empty: the exercise turns it on
    app.launch()
    // a fresh Simulator clone has not added the keyboard yet: add it once, as KeyboardUITests does
    if !app.staticTexts["Done: the v2t keyboard is on."].waitForExistence(timeout: 5) {
      app.terminate()
      allowFullAccess()
      app.launch()
    }
    _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready. Transcription runs on this'")).firstMatch.waitForExistence(timeout: 120)
    // whatever happens, the log is off again for the tests after this one, its files kept for the tools
    addTeardownBlock { @MainActor in
      let app = XCUIApplication.v2t()
      app.terminate()
      app.launchEnvironment["V2T_KEYBOARD_LOG_OFF"] = "1"
      app.launch()
      app.terminate()
    }
  }

  /// Languages and typing › Debugging › Typing exercise, then the v2t keyboard in its field.
  func openExercise() {
    let settings = app.buttons["Languages and typing"]
    reveal(settings, in: app)
    settings.tap()
    let link = app.buttons["settings.typingExercise"]
    reveal(link, in: app)
    XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
    link.tap()
    XCTAssertTrue(app.staticTexts["v2t.exercise.sentence"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["The keyboard debug log is now on for 24 hours, to record this exercise."].exists)
    XCTAssertEqual(progress, "Sentence 1 of 10")
    // the field has focus; the Simulator may start on Apple's keyboard: switch with the globe, as a user would
    for _ in 0..<5 where !key("letters-q").waitForExistence(timeout: 3) {
      let tip = app.buttons["Continue"].firstMatch  // a fresh Simulator's keyboard tips
      if tip.exists { tip.tap(); continue }
      if !app.keyboards.firstMatch.exists { field.tap() }
      let globe = app.buttons["Next keyboard"]
      if globe.exists { globe.tap() }
    }
    XCTAssertTrue(key("letters-q").waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.descendants(matching: .any)["v2t.debugLog"].waitForExistence(timeout: 5), "the keyboard is not recording")
  }

  /// Types `s` with the v2t keyboard: shift for a capital the keyboard has not given already, the numbers page
  /// for marks. `aim` places each letter's tap inside its key (0.5, 0.5 is the centre), by its index.
  func type(_ s: String, aim: (Int) -> CGVector = { _ in CGVector(dx: 0.5, dy: 0.5) }) {
    var letters = 0
    for ch in s {
      if ch == " " { key("space").tap(); continue }
      if ch.isLetter {
        if !key("letters-q").exists { key("page").tap() }  // back from the numbers page
        let k = key("letters-\(ch.lowercased())")
        if ch.isUppercase, k.label == k.label.lowercased() { key("shift").tap() }
        k.coordinate(withNormalizedOffset: aim(letters)).tap()
        letters += 1
      } else {
        if !key("numbers-\(ch)").exists { key("page").tap() }
        key("numbers-\(ch)").tap()
      }
    }
  }

  func testTypingASentenceMovesToTheNext() {
    launch()
    openExercise()
    let first = sentence
    shot("30-typing-exercise-empty")
    let words = first.split(separator: " ")
    type(words.prefix(words.count / 2).joined(separator: " "))
    shot("31-typing-exercise-mid-sentence")
    type(" " + words.dropFirst(words.count / 2).joined(separator: " "))
    XCTAssertFalse((field.value as? String ?? "").isEmpty)
    app.buttons["v2t.exercise.next"].tap()

    XCTAssertEqual(progress, "Sentence 2 of 10")
    XCTAssertNotEqual(sentence, first)
    XCTAssertEqual(field.value as? String ?? "", "Type the sentence here", "the field is not empty for the next sentence")
    XCTAssertTrue(key("space").exists, "the keyboard went away")  // on the numbers page after the full stop
  }

  func testAWholeExercise() {
    launch()
    openExercise()
    // most taps a little off centre; every eleventh letter lands just past its key's right edge, on the
    // neighbouring key when it has one
    let aim = { (i: Int) -> CGVector in
      i % 11 == 10 ? CGVector(dx: 1.2, dy: 0.5) : CGVector(dx: [0.3, 0.5, 0.7, 0.45][i % 4], dy: [0.6, 0.35, 0.5][i % 3])
    }
    for n in 1...10 {
      XCTAssertEqual(progress, "Sentence \(n) of 10")
      type(sentence, aim: aim)
      app.buttons["v2t.exercise.next"].tap()
    }
    XCTAssertTrue(app.descendants(matching: .any)["v2t.exercise.summary"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["10"].exists, app.debugDescription)
    shot("32-typing-exercise-summary")
    // the keyboard writes what it holds within a second; closing the app then takes the keyboard down
    sleep(2)
  }
}
