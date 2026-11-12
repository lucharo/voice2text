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
`swift test -c release -Xswiftc -enable-testing --filter RealTypoEval`). Of 4,256 English and 20,227 Spanish
entries, the scored ones are those that are not words themselves (57 and 701 real-word errors are left out) and
whose meant word is in the keyboard's word list (77 and 3,825 are not):

| Set | Fixed | Wrong word | Meant word in the bar |
| --- | --- | --- | --- |
| English, 4,122 scored, before | 83.6% | 13.1% | 88.1% |
| English, now | 89.6% | 8.9% | 93.4% |
| Spanish, 15,701 scored, before | 89.0% | 10.0% | 91.2% |
| Spanish, now | 91.1% | 8.2% | 93.7% |

Typing 1,043 correct Tatoeba sentences per language, autocorrect changed 8 English and 220 Spanish words before,
2 and 141 now. No Spanish misspelling corpus of real typing errors was found; the Spanish Wikipedia list is
the spelling bots' list, so it leans to missing accents.

### After a real typing log (2026-11-12)

A debug log of 355 keys typed on an iPhone 17 Pro (English and Spanish on, build 123), typed again through the
engine with its touch points (`LogReplayEval`, ios/README.md "Keyboard debug log"), had 10 autocorrections, 4 of
them taken back. It showed four things, each now a rule with a weight tuned on the misspelling sets
(`AutocorrectRulesTests` types the log's own words):

| What the log showed | Rule | In the log |
| --- | --- | --- |
| A first letter dropped for a commoner word | Skipping the first touch, or reading it as a far letter, costs 2 more | "hvent" was "vent", now "haven't" |
| A last letter left off was only ever a completion | The word one letter longer is a correction, at the cost of a letter missed inside a word | "som" was "son", now "some"; "lov" was left, now "love" |
| The best correction was applied whatever a completion scored, and the bar did not show it (42 of 269 keys) | When a commoner longer word leads the correction by 1 nat, the letters are left as unfinished; otherwise the bar's middle slot is the word a space puts in | "wanre" was "wants", now left with "wanted" in the bar |
| Any correction of a non-word was applied, however unlikely | A correction scoring under -18 is not applied | none in this log ("mojnf" is still "mong", at -13.3) |

Each language also keeps its own beam (one beam for all halved each language's share once a second was on), and
the bar's completions after one and two letters come from a table of the whole list rather than a scan that
stopped 4,000 entries in ("co" now offers "could").

| Set | Fixed | Wrong word | Left as typed | Meant word in the bar |
| --- | --- | --- | --- | --- |
| English, 4,122 scored, before | 89.6% | 8.9% | 1.5% | 93.4% |
| English, now | 89.5% | 6.2% | 4.3% | 93.7% |
| Spanish, 15,701 scored, before | 91.1% | 8.2% | 0.6% | 93.7% |
| Spanish, now | 90.9% | 6.7% | 2.5% | 93.7% |
| English with Spanish on, now | 89.5% | 6.2% | 4.3% | 93.8% |

Typing the 1,043 correct sentences per language, autocorrect changed 2 English and 141 Spanish words before, 0
and 126 now. The trade is deliberate: about a third fewer wrong words in English for 5 fewer fixes of 4,122, since
a wrong word has to be deleted and a misspelling left alone does not.

### On real phone taps (2026-11-12)

`NoisyTypingEval` types the phone taps of Vertanen and Kristensson's noisy-typing dataset (CC BY 4.0,
https://osf.io/5xwng/, fetched by `tools/fetch_noisy_typing.py`): Enron email sentences copied on an iPhone 4 or a
Nexus 4, which the authors force aligned to the words meant, typed here a word at a time with the words before
as context. Each dataset keyboard is mapped onto the 402 pt layout by one straight line for x and one for y
through the letter centres; after it, the share of taps that type the meant key is within 0.2 points of the
share nearest it on the dataset's own keyboard (86.1% against 86.3% on development, 83.5% against 83.6% on test).
The typists saw no recognition while typing, many saw no key popups, and some typed on keyboards a third or a
sixth of a phone's, so a word was tapped right less often than on a keyboard that shows each key: the full-size
keyboards with popups are the part closest to v2t. Release build:
`swift test -c release -Xswiftc -enable-testing --filter NoisyTypingEval 2>&1 | grep '^noisy'`.

| Set (English) | Words | Tapped right | Of those, changed | Tapped wrong | Fixed | Wrong word | Left as typed | Meant word in the bar |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Development, all | 15,305 | 61.3% | 2 | 5,929 | 74.2% | 5.5% | 20.3% | 89.0% |
| Development, full-size with popups | 5,728 | 64.8% | 1 | 2,016 | 79.9% | 2.9% | 17.3% | 92.8% |
| Test, all | 45,757 | 56.4% | 30 | 19,952 | 69.4% | 7.6% | 23.0% | 84.5% |
| Test, full-size with popups | 16,766 | 72.1% | 15 | 4,681 | 70.2% | 6.4% | 23.5% | 83.4% |
| Test, all, taps moved to their keys' centres | 45,757 | 56.4% | 36 | 19,952 | 50.3% | 14.1% | 35.6% | 64.4% |

The last four columns are shares of the words tapped wrong. 11.7% of those on the test split are words
themselves ("hone" for "home"), which autocorrect leaves by design: up to 11.7 of its 23.0 points left as typed.
Moving each tap to the centre of the key it typed loses 19 points of fixes: the touch model reads where the
finger lifted.

The stretched-word and near-tie rules (#192) show on these taps as they do on the misspelling sets: before
them the test split fixed 70.9% and made a wrong word of 10.0%; with them, 69.4% and 7.6%.

Tuned on the development split (`V2T_TYPO_TUNE=... --filter NoisyTypingTuning`), the touch spread is the only
constant that moves it. A wider one fixes more real taps and costs the key-centre measures (this table was
measured before #192's rules):

| `touchStd` | Test fixed / wrong | Test full-size fixed / wrong | RealTypo EN wrong | RealTypo ES wrong | Bar after 3 letters (EN) |
| --- | --- | --- | --- | --- | --- |
| 0.42 (kept) | 70.9% / 10.0% | 71.3% / 7.9% | 6.2% | 6.7% | 41.0% |
| 0.46 | 72.2% / 9.4% | 71.8% / 7.7% | 7.0% | 6.8% | 40.3% |
| 0.50 | 73.0% / 9.0% | 72.0% / 7.8% | 7.4% | 7.1% | 39.6% |
| 0.55 | 73.3% / 9.0% | 71.6% / 8.3% | 8.5% | 7.6% | 36.6% |

The evals are deterministic, so their run-to-run noise is nil and any rise in a wrong-word rate counts; no
default changed. At 0.42 the neighbour floor (0 to 1) moved no development row by more than 0.4 points. At 0.5 a
neighbour cutoff of 1.4 key widths fixed 2.3 points fewer than 1.8, and 2.2 and 2.6 matched it; a skip or
missed-letter penalty of 4 or 6 did up to 0.7 points worse than 5; the spelling-slip (6, 8), vowel (4, 6),
first-touch (1, 3) and last-letter (4, 6) penalties moved no row by more than 0.3.

Still different from Apple's keyboard, or unmeasured:

- **Real fingers.** The misspellings were typed on physical keyboards, so the taps sit at the key centres. One
  log of real touches has been replayed (above); it is 72 words from one typist, tapping only, no swipes. The
  noisy-typing dataset (above) is real taps from the participants of seven studies (126 listed in their readmes), but on an iPhone 4 or a Nexus 4, copying
  text, mostly without key popups: noisier than typing on a keyboard that shows each key.
- **Names at the start of a sentence** are still corrected when the word list lacks them ("Tom" → "Ton" with
  only Spanish on); a capitalised typo cannot be told from a name there.
- **Learning.** v2t learns a word after one rejection, and a kept word no word list knows ("marimo" over
  "merino") also goes into the v2t dictionary as a term, so dictation spells it too. It does not learn words
  you type often without rejecting a correction.
- **Smart quotes and dashes** are left to the host field; unverified.
- **Corrections after punctuation** cannot be reverted with delete, only after a space.
- **A hyphen before an address** ("exmaple-site.com") still corrects its first part: a hyphen applies the
  correction, so compound words are corrected part by part.

### Stretched words (2026-11-12)

A letter typed three or more times in a row is stretched on purpose ("saaame", "soooo", "yessss"), and the
nearest word is never what was meant: those became "salaam", "soon" and "yeasts". Such letters now stay as
typed (`Suggester.stretchedRun`, `AutocorrectRulesTests`). The one exception is a run of exactly three that
is one tap too many on a double letter ("boook" → "book", "cannnot" → "cannot"); four or more in a row is
never corrected. The misspelling sets have 15 English and 4 Spanish words with a run of three and none
longer, and all but two ("asssassans", "resssurecting") are the extra tap. English fixes go from 3,688 to
3,687 of 4,122 with wrong words unchanged at 256, and Spanish does not move.

### After a second typing log (2026-11-12, build 124)

A second log from the same phone, 191 keys and 37 words on build 124, had 6 autocorrections. Replayed
(`LogReplayEval`):

| Typed | Meant | Build 124 | Now |
| --- | --- | --- | --- |
| acutally | actually | actually | actually |
| ica | I can | ova | left as typed |
| tye | type | the | the |
| issus | issues | left as typed | left as typed |
| ecpt | except | left as typed | left as typed |
| lle | like | left as typed | left as typed |

"ica" became "ova" with "ice" 0.1 behind it: when two different words are about as likely, either may be the
one meant. The best correction must now lead the next word by 0.5 (`Suggester.runnerUpLead`), or the letters
stay. On the misspelling sets that gives up about one fix for each wrong word avoided:

| `runnerUpLead` | English fixed / wrong | Spanish fixed / wrong |
| --- | --- | --- |
| 0 (before) | 89.4% / 6.2% | 90.9% / 6.7% |
| 0.25 | 88.6% / 5.2% | 90.1% / 5.6% |
| 0.5 (now) | 87.7% / 4.5% | 89.4% / 4.6% |
| 0.75 | 86.7% / 3.9% | 88.7% / 3.9% |
| 1 | 85.6% / 3.3% | 87.8% / 3.3% |

At 0.5 both logs keep every correction that was right; 0.75 would also have left "tye" alone, but it leaves
"fnd" (find) and "som" (some) from the first log as typed. The meant word stays in the bar as often as before
(93.7%).

Still open from this log: "tye" becomes "the" where "type" was meant (0.6 ahead of "rye"); "issus" is in the
English list, so it is a real word and stays; "ecpt" and "lle" are two slips in three or four letters and the
bar does not offer the meant word.

The same log is the first check of the edge-touch fix on a phone: delete presses within 30 pt of the screen
edge took a median 18 ms from touch to deletion (2 presses) against 96 ms on build 123 (8 presses),
and edge letters 29 ms from lift to key (5) against 38 ms (7); keys elsewhere stayed at 20 ms. The bar came up
a median 4.5 ms after a key (95th percentile 8.8 ms) against 7.3 ms (19.9 ms).

## Where Gboard and SwiftKey differ

- **Space can insert a prediction.** SwiftKey's space bar inserts the middle prediction when autocorrect is on,
  and an option makes it always insert a prediction, next words included [11]; Apple and Gboard only correct a
  misspelt word. v2t follows Apple.
- **Undo is backspace in all three.** Gboard undoes an automatic correction with Backspace [10]; SwiftKey shows
  the earlier predictions again after Backspace [12]; Apple offers the original back [1]. v2t follows Apple.
- **Removing a suggestion.** Gboard lets you drag a suggestion to a bin to stop it [10]; Apple stops after a
  few rejections [1]. v2t learns the word after one rejection.
- **Quick period** in SwiftKey [11] is Apple's double-space full stop.
