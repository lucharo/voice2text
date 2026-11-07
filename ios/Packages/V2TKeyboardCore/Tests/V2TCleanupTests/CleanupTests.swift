import Testing
@testable import V2TCleanup

@Suite struct KeepSpokenWordsTests {
  @Test func appleModelGetsTheChunkInAQuotedBlock() {
    #expect(CleanupPrompt.appleFrame("so um the plan is fine") == "Dictation:\n\"\"\"\nso um the plan is fine\n\"\"\"\nCleaned:")
  }

  @Test func fillersRepeatsNumbersAndDictionaryFixesStayOut() {
    let result = keepSpokenWords(
      raw: "uh PR three five nine is is done by clot", clean: "PR #359 is done by Claude.", vocabulary: ["Claude"])

    #expect(result.text == "PR #359 is done by Claude.")
    #expect(result.counts == SpokenWordCounts(restored: 0, reverted: 0, removed: 0))
  }

  @Test func grammarEditsAreUndone() {
    let result = keepSpokenWords(raw: "she says it is fine", clean: "She said it's really fine.")

    #expect(result.text == "She says it is fine.")
    #expect(result.counts == SpokenWordCounts(restored: 0, reverted: 3, removed: 0))
  }

  @Test func droppedWordsComeBackBeforeTheFullStop() {
    let result = keepSpokenWords(raw: "send it to me please", clean: "Send it to me.")

    #expect(result.text == "Send it to me please.")
    #expect(result.counts == SpokenWordCounts(restored: 1, reverted: 0, removed: 0))
  }

  @Test func spanishAccentedWordsAlignWithTheirCapitalisedForms() {
    let result = keepSpokenWords(raw: "eh pues él está aquí", clean: "Él está aquí.")

    #expect(result.text == "eh pues Él está aquí.")
    #expect(result.counts == SpokenWordCounts(restored: 2, reverted: 0, removed: 0))
  }

  @Test func aDictionaryWordReplacesOnlyASimilarSoundingWord() {
    let fixed = keepSpokenWords(raw: "we met clod yesterday", clean: "We met Claude yesterday.", vocabulary: ["Claude"])
    let unrelated = keepSpokenWords(raw: "we met him yesterday", clean: "We met Claude yesterday.", vocabulary: ["Claude"])

    #expect(fixed.text == "We met Claude yesterday.")
    #expect(unrelated.text == "We met Him yesterday.")
  }
}

@Suite struct ChunkingAndGuardTests {
  @Test func runOnSpeechIsSplitOnWordBoundaries() {
    let chunks = chunkText(Array(repeating: "word", count: 300).joined(separator: " "))

    #expect(chunks.map { $0.split(separator: " ").count } == [120, 120, 60])
  }

  @Test func sentencesStayWholeWithinAChunk() {
    #expect(chunkText("One two. Three four. Five.", maxWords: 4) == ["One two. Three four.", "Five."])
  }

  @Test func strictModeRejectsASummary() {
    #expect(withinLengthGuard(raw: "one two three four five", clean: "One two.", mode: .strict) == false)
    #expect(withinLengthGuard(raw: "one two three four five", clean: "One two three.", mode: .strict) == true)
  }
}

@Suite struct CleanupPromptTests {
  @Test func vocabularyIsAppendedToTheSystemPrompt() {
    let messages = CleanupPrompt.messages(for: "x", mode: .casual, vocabulary: [" Claude ", "  "])

    #expect(messages.count == 10)
    #expect(messages[0].content.hasSuffix("write the term exactly as spelled here: Claude."))
    #expect(messages.last == ChatMessage(role: "user", content: "x"))
  }
}
