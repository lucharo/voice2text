# v2t for iPhone and iPad

An iPhone and iPad app and keyboard ([#75](https://github.com/lucharo/voice2text/issues/75)): a typing keyboard meant to be the
only one you need, with v2t dictation built in. Speech is transcribed on the device; audio never leaves it.
The iPad gets its own keyboard layouts, including the full keyboard with a number row on 13-inch iPads.

Status: internal TestFlight testing, with no public invitation. Builds 1 to 3 went to TestFlight on 5 November 2026
(build 3 is main as of #110), and build 1 ran on an iPhone 17 Pro. Nothing has run on an iPad: the iPad layouts have
only been rendered off-screen (the installed Simulator runtime offers no iPad). The user guide is
[docs/iphone.md](../docs/iphone.md), published at <https://v2t.luischav.es/iphone/>.

## Build and test

```sh
cd ios
./setup.sh                 # word lists (pinned AOSP commit) and next-word counts (pinned Tatoeba revision) via uv, then V2T.xcodeproj with xcodegen
./setup.sh test            # the app's unit and UI tests on an iPhone simulator (iPad UI tests skip there)
(cd Packages/V2TKeyboardCore && swift test)   # keyboard engines and cleanup guard, on the Mac
```

Set `V2T_TEAM` to your Apple development team if it is not the default. `tools/ExportOptions.plist` exports an
archive to App Store Connect for TestFlight (`xcodebuild -exportArchive … -exportOptionsPlist tools/ExportOptions.plist`);
with another team, change its `teamID` too.

Every push to `main` that touches `ios/` goes to TestFlight by itself ([testflight.yml](../.github/workflows/testflight.yml)):
CI runs the keyboard engine tests, archives, uploads, and stays red unless Apple accepts the build. Each build is
numbered one above the last upload, so there is nothing to bump. To upload `main` without a change, run the workflow
by hand from the Actions tab. `scripts/ci-testflight-secrets.sh` loads its secrets; run it again when the Apple Distribution
certificate or the App Store Connect key is renewed. Profiles come from App Store Connect on each run, so a renewed
profile with the same name needs no change.

Pushing an `ios-v<version>` tag submits that version's newest TestFlight build for App Store review
([appstore.yml](../.github/workflows/appstore.yml); [Maintainers](../docs/maintainers/index.md#iphone-app) has the details).

To upload from a Mac with the Apple Distribution certificate but no account in Xcode, sign manually instead. Install the
"v2t App Store" and "v2t keyboard App Store" profiles (App Store Connect API `GET /v1/profiles`, `profileContent`,
into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`), raise `CURRENT_PROJECT_VERSION` in `project.yml` above the last upload and rerun `./setup.sh`, then:

```sh
xcodebuild archive -project V2T.xcodeproj -scheme V2T -destination 'generic/platform=iOS' \
  -archivePath /tmp/V2T.xcarchive -xcconfig tools/AppStore.xcconfig
xcodebuild -exportArchive -archivePath /tmp/V2T.xcarchive -exportOptionsPlist tools/ExportOptions-manual.plist \
  -exportPath /tmp/V2T-export -authenticationKeyPath <AuthKey.p8> -authenticationKeyID <key id> \
  -authenticationKeyIssuerID <issuer id>
```

## How it fits together

| Part | Where | What it does |
| --- | --- | --- |
| Keyboard engines | `Packages/V2TKeyboardCore` (`V2TKeyboardCore`) | Layouts, word lists, autocorrect and suggestions, swipe decoding, the typing rules. No UIKit; tested on the Mac. |
| Cleanup guard | `Packages/V2TKeyboardCore` (`V2TCleanup`) | The Mac app's cleanup prompt and `keep_spoken_words` guard, ported to Swift and checked against the Python output (`tools/cleanup_golden.py`). |
| Keyboard | `Keyboard/` | The keyboard extension: keys drawn with Core Animation, touch handling, previews, long-press accents, swipe trail, held delete, space-bar cursor, the suggestion bar and the mic. |
| App | `App/` | Setup, the model download (only when you tap Download), the microphone session, transcription (FluidAudio on the Neural Engine), cleanup, dictionary, history. |
| Shared | `Shared/` | Settings and the dictionary in the App Group, and the keyboard-to-app dictation channel. |

### Dictation from the keyboard

iOS gives keyboards no microphone, so the app records:

1. With no microphone session running, the keyboard's mic opens v2t once. v2t starts recording at once and asks you
   to swipe back to the app you were typing in (iOS offers no way to send you back automatically).
2. The session then stays on for 15 minutes after your last dictation (Keyboard settings: 5 min, 15 min, 1 hour or
   until turned off). During that time the mic records from the keyboard without leaving your app. The orange
   microphone dot shows while the session is on, and the app has a Stop microphone session button.
3. Only what you say between tapping the mic and tapping it again is kept; nothing else is buffered or saved.
4. The keyboard's recording view and the app name the microphone in use ("iPhone Microphone", a wired headset).
   By default the session records from the iPhone's own microphone even with AirPods connected, so Bluetooth
   headphones stay in music mode and other apps' audio plays at its usual level. Microphone › Connected headset
   records from AirPods or a wired headset instead; with AirPods, music drops to call quality while the session is
   on. Not yet checked on a phone.
5. While you talk, the app transcribes what you have said so far in pieces of up to 14.9 s, each cut at the quietest
   moment near its 12 s mark (the Mac app's rule), so when you tap the mic again only the last piece is left. A
   dictation under 14.9 s is transcribed whole, as before (#112). Each dictation logs its timing under category
   `dictation`: how long speech took after Stop, and how many pieces were transcribed while you talked.

### What stays on the iPhone

- The speech model downloads only when you tap Download in the app (size in the table below). Storage in the app
  shows the space it takes, with its Neural Engine copy, and deletes it. Without the model, the keyboard's mic
  opens v2t on its download screen instead of recording.
- History keeps each dictation as text only, in one file; Storage shows its size and clears it. Audio is never
  saved: the app holds it in memory while it transcribes, then drops it.

### Keyboard debug log

An opt-in log of everything the keyboard does while you type, to find where it gets typing wrong (#162). Off by
default; **Languages and typing** › Debugging turns it on for 24 hours, and a red dot in the suggestion bar shows
while it records. It is written by `KeyboardDebugLog` (V2TKeyboardCore) as JSON lines to `KeyboardLog/keyboard.jsonl`
in the App Group, moving to `keyboard.1.jsonl` past 4 MB, so it never holds more than 8 MB. The app's Export
shares both files joined; Clear log deletes them.

- **Privacy.** Local only. Never recorded: fields whose content type asks for a password, a new password, a
  one-time code or card details (iOS already swaps in its own keyboard for secure fields; `keyboardType` has no
  password or card value, so it marks nothing on its own). A `skip` line names the reason, then nothing until
  the field changes. Dictation is recorded by length only: its words are in History already. The text before the
  cursor is recorded only as far as the engine reads it (`TypingContext`, the last 160 characters), when the host
  app changes it.
- **Without Full Access** iOS keeps the App Group, and so the switch, from the keyboard: it reads off and nothing
  is recorded. If the keyboard can read the switch but not write to the App Group, it writes to its own
  container, which the app cannot export.
- **Cost.** `log()` only appends to a buffer under a lock (0.15 µs a call on the Mac, release build); a
  background queue encodes and appends to the file every 64 events or second. Per key on the Mac (release build,
  English, key + engine + bar, the two arms interleaved, load average 54 to 85 from other builds), against the
  8 ms budget: log off mean 0.95, p95 2.43, p99 3.48 ms; log on 0.97, 2.46 and 3.28 ms
  (`swift test -c release -Xswiftc -enable-testing --filter perKeyCost`). The difference is within the noise.
  Phone untested.
- **Fetch.** `ios/tools/fetch_kb_log.sh` copies the log off a connected iPhone (`xcrun devicectl device copy from
  --domain-type appGroupDataContainer --domain-identifier group.es.luischav.v2t --source KeyboardLog`, which
  reads TestFlight builds too) or a Simulator (`--sim <udid>`) into `~/.v2t/eval/kb-logs/<device>-<time>/`. Then
  `uv run ios/tools/kb_log_report.py <that folder>` reports autocorrections kept and taken back, words deleted and
  retyped, swipes kept, bar taps by slot, taps read as swipes (#140) and keys per second; `--json` for the numbers.

Each line has `t` (milliseconds of system uptime, the clock of touch timestamps) and `e`, the event:

| `e` | Fields | When |
| --- | --- | --- |
| `appear`, `disappear` | full access, store, layout, languages, width, form, build | the keyboard opens or closes |
| `field` | keyboardType, contentType, autocorrect, capitalization, return | a new text field |
| `skip`, `resume`, `auto-off` | reason | a field the log never records; the 24 hours are up |
| `down` | n (finger), key, p, fingers down | a finger lands |
| `up` | n, key, liftKey, p, ms, travel, verdict (tap, swipe, accent, trackpad, rolled, cancelled), path (24 points) | it lifts |
| `rollover`, `swipe-start` | n, key, p, by | a finger typed early by a newer one lifting; a finger becomes a swipe |
| `key`, `act`, `cursor` | text and p; action; by | a character, another key, the space-bar trackpad |
| `swipe` | points, trace (48 points), candidates (word, score), applied, decodeMs | a swipe decoded |
| `swiped`, `picked` | word, alternatives; word, replaced | the engine typed a swipe; a bar tap replaced a word |
| `bar`, `pick` | words, kinds, bold; slot, word, emoji | the bar changed; a slot was tapped |
| `autocorrect`, `revert-offer`, `revert` | from, to, how (bar, address) | a correction; offered back after delete; undone |
| `ins`, `del` | text (chars for dictation) | the keyboard edited the document |
| `host` | kind, before | the app changed the text or moved the cursor |
| `page`, `emoji`, `dictation` | page, form, width; e, from; chars, words | |

### Which model this iPhone gets

One choice per iPhone, decided by Apple's own Apple Intelligence eligibility check (`SystemLanguageModel`):

| iPhone | Speech | Cleanup | Evidence |
| --- | --- | --- | --- |
| Apple Intelligence-compatible (iPhone 15 Pro and Pro Max, the iPhone 16 and 17 families, 18 Pro and Pro Max, 16e, 17e, Air, Duo) | Nemotron-Labs Unified ASR 0.6B, int8, 627 MB | Apple Intelligence with the Mac's prompt and guards; your dictionary's replacements otherwise | Measured on one iPhone 16 Pro only (#52, #85, #67) |
| Every other iPhone that runs iOS 26 | Parakeet TDT 0.6B v3 | Your dictionary's replacements only | FluidAudio's int8 Unified encoder failed to load on an A16 (#828, the Parakeet Unified sibling; Nemotron itself untried there) and is unverified on other earlier chips. Untested on these phones |

Model files come from Hugging Face at pinned revisions (`App/SpeechEngine.swift`).

## How close it is to Apple's keyboard

Apple gives third-party keyboards none of its own swipe, prediction or autocorrect engines (no such API in the iOS
27.1 SDK's UIKit headers), so v2t has its own. iOS also limits every third-party keyboard:

- No text selection, edit menu or system undo, and the space-bar cursor moves left and right only.
- Apple's keyboard takes over in password and phone-number fields, and in apps that refuse custom keyboards.
- Key previews on the top row draw over the suggestion bar, never above the keyboard.
- The globe and microphone below the keys on Face ID iPhones belong to iOS; no keyboard can put its own key there.
  v2t sets `hasDictationKey`, the one API for it (UIInputViewController.h: "the system dictation key, if
  provided, will be disabled"), since its own mic key dictates. Whether iOS then hides the microphone or only
  greys it out is unverified: the Simulator draws no key there. If it still shows, Settings › General ›
  Keyboard › Enable Dictation off removes it, for Apple's keyboard too.
- A keyboard never sees taps outside itself, and the app you type in decides when the keyboard hides (the only
  call a keyboard has is `dismissKeyboard()`), so v2t cannot hide when you tap away. The chevron at the end of
  the suggestion bar hides it on the iPhone; the iPad has a hide-keyboard key in the bottom row.

What has been checked so far, and how:

| Behaviour | Checked by | Result |
| --- | --- | --- |
| Swipe decoding | 1,000 synthetic noisy traces per language (the test's own trace model) | EN 96.5% top-1, 99.7% top-3; ES 95.6%, 100%. Real-finger accuracy unmeasured |
| Swipe, suggestions and next word as on a phone | `QualityEval`: 300 everyday English and 100 Spanish words, and 30 short messages swiped word by word, with finger-like traces (per-key scatter, a per-swipe offset, cut corners; "sloppy" has a 2.5 times larger offset and wider scatter) on the 402 pt iPhone layout with English and Spanish both on | Messages: EN 98.3% top-1, sloppy 89.6%; ES 89.7%, sloppy 84.6%. The next word is in the bar 37% of the time in English messages. Prints the full table: `swift test --filter QualityEval` |
| Autocorrect against Apple's keyboard | `AppleBehaviourTests`: 31 checks of what Apple's keyboard does, each with its source in [AUTOCORRECT.md](AUTOCORRECT.md) (when a correction applies, revert, contractions, names, addresses, text replacements, Spanish accents) | All 31 pass (20 before #114) |
| Autocorrect on real misspellings | `RealTypoEval`: Wikipedia's lists of common misspellings at pinned revisions (4,256 English, 20,227 Spanish, mostly missing accents), typed at the key centres. Scored: the 4,122 and 15,701 that are not themselves words and whose meant word is in the keyboard's word list | EN fixes 89.6% (a wrong word 8.9%, the meant word in the bar 93.4%); ES 91.1% (8.2%, 93.7%). Before #114: EN 83.6% (13.1%, 88.1%), ES 89.0% (10.0%, 91.2%) |
| Autocorrect on correct text | `RealTypoEval`: 1,043 Tatoeba sentences per language typed through the keyboard's engine | Changes 2 of 7,088 English words and 141 of 6,909 Spanish ones (220 before #114), mostly names at the start of a sentence and Spanish verb forms the word list lacks |
| Autocorrect, synthetic typos | 200 noisy-tap typos per language; 1,000 correctly typed common words | EN fixes 187, ES 187; changes 0 correct words |
| Typing rules (capitals, double-space full stop, revert, swipe spacing) | Unit tests, and UI tests driving the keyboard in the Simulator | See the test files |
| Keystroke latency | Not yet measured on a phone. Provisional target: under one 120 Hz frame (8 ms) of our own handling per key, logged as `latency` in the keyboard. On the Mac, `RealTypoEval` times key + suggestion bar + bold slot over 109,509 keys (release build) | Phone untested. Mac, English and Spanish on, with the Mac loaded by other builds: mean 1.2 ms, p95 3.3 ms, p99 4.2 ms; with #114's spelling-slip search off, in the same run, 0.6, 1.8 and 2.4 ms |
| Keyboard memory | Not yet measured. Provisional target: 40 MB, well under the ~60 MB commonly reported limit (Apple documents no number) | Untested |

Autocorrect is not yet measured with real fingers on a phone: the misspellings above were made on physical
keyboards, so the taps sit at the key centres and the touch model is not exercised; whether iOS turns the
straight quotes the keyboard types into curly ones is also unchecked.

The targets are our own provisional choices, not Apple figures. Parity with Apple's keyboard will only be claimed
from side-by-side measurements on a phone.

## Third-party code and data

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
