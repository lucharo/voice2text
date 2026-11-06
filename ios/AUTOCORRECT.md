# Autocorrect: Apple's keyboard as the reference

What Apple's iPhone keyboard does with autocorrect, item by item, with the source for each, and whether v2t's
keyboard does the same. Each item is a test in
`Packages/V2TKeyboardCore/Tests/V2TKeyboardCoreTests/AppleBehaviourTests.swift`; print the table with
`swift test --filter AppleBehaviour 2>&1 | grep '^behaviour'`.

Apple documents only part of its keyboard's behaviour. Where it does not, the item says what the source is,
and "observed" items rest on widely reported behaviour rather than a specification.

## Sources

1. Apple, iPhone User Guide (iOS 27), "Use predictive text on iPhone",
   https://support.apple.com/guide/iphone/use-predictive-text-iphd4ea90231/ios (read 2026-11-05).
2. Apple, iPhone User Guide (iOS 27), "Type with the onscreen keyboard on iPhone",
   https://support.apple.com/guide/iphone/type-with-the-onscreen-keyboard-iph3c50f96e/ios
3. Apple, iPhone User Guide (iOS 27), "Change typing assistance options for Magic Keyboard with iPhone",
   https://support.apple.com/guide/iphone/change-typing-assistance-options-iph6e86c4826/ios
4. Apple, iPhone User Guide (iOS 27), "Set up shorthand for frequently used text on iPhone",
   https://support.apple.com/guide/iphone/set-up-shorthand-iph6d01d862/ios
5. Apple, App Extension Programming Guide, "Custom Keyboard",
   https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
6. Apple Developer Documentation, `UILexicon` and `UIInputViewController.requestSupplementaryLexicon(completion:)`,
   https://developer.apple.com/documentation/uikit/uilexicon
7. Apple Developer Documentation, `UITextInputTraits.smartQuotesType` and `smartDashesType`,
   https://developer.apple.com/documentation/uikit/uitextinputtraits/smartquotestype
8. Apple Newsroom, "iOS 17 makes iPhone more personal and intuitive" (2023-06-05),
   https://www.apple.com/newsroom/2023/06/ios-17-makes-iphone-more-personal-and-intuitive/
9. Ask Different, "How can I add an autocorrect mapping to the iOS dictionary?" (ill → I'll stopped in iOS 6),
   https://apple.stackexchange.com/questions/69391
10. Google, Gboard Help, "Get word suggestions & fix mistakes", https://support.google.com/gboard/answer/7068415
11. Microsoft Support, "How does the spacebar work with autocorrect in Microsoft SwiftKey Keyboard?",
    https://support.microsoft.com/en-us/swiftkey-keyboard/how-does-the-spacebar-work-with-autocorrect-in-microsoft-swiftkey-keyboard
12. Microsoft Support, "How does the Microsoft SwiftKey Prediction Bar work?",
    https://support.microsoft.com/en-us/swiftkey-keyboard/how-does-the-microsoft-swiftkey-prediction-bar-work

## Checklist

| # | Apple's keyboard | Source | Test id |
| --- | --- | --- | --- |
| 1 | A correction applies when you enter a space or punctuation, or tap Return | [1] "Accept a correction: Enter a space or punctuation, or tap Return" | `space-applies`, `punctuation-applies`, `return-applies` |
| 2 | The bar shows your original word in quotation marks; tapping it keeps it | [1] "Tap your original word (shown as the option in quotation marks)" | `bar-shows-typed`, `tap-typed-keeps` |
| 3 | A correction can be rejected; rejecting the same one a few times stops it | [1] "If you reject the same suggestion a few times, iPhone stops suggesting it." v2t stops after one rejection | `backspace-reverts`, `reverted-not-recorrected` |
| 4 | Deleting back into a corrected word offers the original back | Observed; [8] describes corrected words "temporarily underlined" with a tap to revert, which custom keyboards cannot draw [5] | `backspace-reverts` |
| 5 | Missing apostrophes are put back: dont, im, youre, cant, wont, whats | Observed | `dont`, `im`, `youre`, `cant-wont`, `whats` |
| 6 | Common words that are also contractions without the apostrophe stay: ill, its, were, well, hell (the contraction is in the bar) | [9] (ill → I'll was dropped because ill is a word); observed | `ill-its-kept` |
| 6a | An apostrophe you typed stays as typed: a curly one (don’t) is not rewritten, a plural possessive (parents') keeps it | Observed | `curly-apostrophe`, `plural-possessive` |
| 7 | A lone i becomes I, and i'm, i'll, i'd become I'm, I'll, I'd | Observed | `lone-i`, `i-contractions` |
| 8 | Capitalised words in mid-sentence (names) are not turned into common words; a misspelt known name is fixed (Britian → Britain) | Observed; [3] says auto-capitalisation "capitalizes proper nouns" | `capitalised-mid-sentence` |
| 9 | Web addresses, email addresses, @handles and #hashtags are left alone | Observed; [5] says the system keyboard adapts to URL and email fields | `url`, `email`, `handle-hashtag` |
| 10 | Words with digits are left alone (10am, 2nd) | Observed | `numbers` |
| 11 | Words in the user's dictionary are never corrected away; text replacements expand (omw → On my way!) | [4]; [6]: custom keyboards get the user's text replacements and contact names through `UILexicon` | `user-dictionary`, `text-replacement` |
| 12 | A real word is not swapped for a near one; a single letter other than i is left alone | Observed | `real-word-kept`, `single-letter` |
| 13 | A correction keeps the capitals typed (Teh → The) | Observed | `keeps-capitals` |
| 14 | Double-tapping space types a full stop and a space | [2], [3], [5] | `double-space` |
| 15 | Capitals at the start of a sentence | [3], [5] | `auto-capitals` |
| 16 | Smart quotes and dashes | [7]: a property of the text field, which UIKit applies "based on the keyboard type". Not checked here: whether UIKit converts text a custom keyboard inserts is unverified | none |
| 17 | Spanish: missing accents restored (cancion → canción), real words without accents stay (como) | Observed | `es-accents`, `es-rare-variant` |

## Results

Before #114, 20 of the 31 checks passed; now all 31 do. The 11 that failed:

| Check | Before | Now |
| --- | --- | --- |
| `curly-apostrophe`, `plural-possessive` | "don’t" was rewritten "don't"; "parents'" lost its apostrophe | Kept as typed |
| `capitalised-mid-sentence` | Names were corrected into words ("Susan" → "Usan" in Spanish) | Only a known name can replace them ("Britian" → "Britain") |
| `cant-wont`, `whats`, `es-rare-variant`, `i-contractions` | Any word in the lists stayed, so "cant", "whats", "ano", "i'm" did | A rare word becomes its much commoner apostrophe or accent spelling; i' takes the capital |
| `url`, `email`, `handle-hashtag` | Each part of an address or handle was corrected | Left as typed |
| `text-replacement` | No text replacements | The user's replacements and contact names come from the system (UILexicon) |

On misspellings people made (`RealTypoEval`, Wikipedia's lists, release build:
`swift test -c release -Xswiftc -enable-testing --filter RealTypoEval`):

| Set | Fixed | Wrong word | Meant word in the bar |
| --- | --- | --- | --- |
| English, 4,122 misspellings, before | 83.6% | 13.1% | 88.1% |
| English, now | 89.6% | 8.9% | 93.4% |
| Spanish, 15,701 misspellings, before | 89.0% | 10.0% | 91.2% |
| Spanish, now | 91.1% | 8.2% | 93.7% |

Typing 1,043 correct Tatoeba sentences per language, autocorrect changed 8 English and 220 Spanish words before,
2 and 141 now. No Spanish misspelling corpus of real typing errors was found; the Spanish Wikipedia list is
the spelling bots' list, so it leans to missing accents.

Still different from Apple's keyboard, or unmeasured:

- **Real fingers.** The misspellings were typed on physical keyboards, so the taps sit at the key centres. How
  autocorrect does with touches on a phone is unmeasured.
- **Names at the start of a sentence** are still corrected when the word list lacks them ("Tom" → "Ton" with
  only Spanish on); a capitalised typo cannot be told from a name there.
- **Learning.** v2t learns a word after one rejection; it does not learn words you type often without
  rejecting a correction.
- **Smart quotes and dashes** are left to the host field; unverified.
- **Corrections after punctuation** cannot be reverted with delete, only after a space.

## Where Gboard and SwiftKey differ

- **Space can insert a prediction.** SwiftKey's space bar inserts the middle prediction when autocorrect is on,
  and an option makes it always insert a prediction, next words included [11]; Apple and Gboard only correct a
  misspelt word. v2t follows Apple.
- **Undo is backspace in all three.** Gboard undoes an automatic correction with Backspace [10]; SwiftKey shows
  the earlier predictions again after Backspace [12]; Apple offers the original back [1]. v2t follows Apple.
- **Removing a suggestion.** Gboard lets you drag a suggestion to a bin to stop it [10]; Apple stops after a
  few rejections [1]. v2t learns the word after one rejection.
- **Quick period** in SwiftKey [11] is Apple's double-space full stop.
