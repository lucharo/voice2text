# v2t for iPhone

An iPhone app and keyboard ([#75](https://github.com/lucharo/voice2text/issues/75)): a typing keyboard meant to be the
only one you need, with v2t dictation built in. Speech is transcribed on the iPhone; audio never leaves it.

Status: in development. Runs on the iOS Simulator; nothing has been installed on a phone yet.

## Build and test

```sh
cd ios
./setup.sh                 # word lists (pinned AOSP commit), then generate V2T.xcodeproj with xcodegen
./setup.sh test            # the app's unit tests on an iPhone simulator
(cd Packages/V2TKeyboardCore && swift test)   # keyboard engines and cleanup guard, on the Mac
```

Set `V2T_TEAM` to your Apple development team if it is not the default.

## How it fits together

| Part | Where | What it does |
| --- | --- | --- |
| Keyboard engines | `Packages/V2TKeyboardCore` (`V2TKeyboardCore`) | Layouts, word lists, autocorrect and suggestions, swipe decoding, the typing rules. No UIKit; tested on the Mac. |
| Cleanup guard | `Packages/V2TKeyboardCore` (`V2TCleanup`) | The Mac app's cleanup prompt and `keep_spoken_words` guard, ported to Swift and checked against the Python output (`tools/cleanup_golden.py`). |
| Keyboard | `Keyboard/` | The keyboard extension: keys drawn with Core Animation, touch handling, previews, long-press accents, swipe trail, held delete, space-bar cursor, the suggestion bar and the mic. |
| App | `App/` | Setup, the one-time model download, the microphone session, transcription (FluidAudio on the Neural Engine), cleanup, dictionary, history. |
| Shared | `Shared/` | Settings and the dictionary in the App Group, and the keyboard-to-app dictation channel. |

### Dictation from the keyboard

iOS gives keyboards no microphone, so the app records:

1. With no microphone session running, the keyboard's mic opens v2t once. v2t starts recording at once and asks you
   to swipe back to the app you were typing in (iOS offers no way to send you back automatically).
2. The session then stays on for 15 minutes after your last dictation (Keyboard settings: 5 min, 15 min, 1 hour or
   until turned off). During that time the mic records from the keyboard without leaving your app. The orange
   microphone dot shows while the session is on, and the app has a Stop microphone session button.
3. Only what you say between tapping the mic and tapping it again is kept; nothing else is buffered or saved.

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

What has been checked so far, and how:

| Behaviour | Checked by | Result |
| --- | --- | --- |
| Swipe decoding | 1,000 synthetic noisy traces per language (the test's own trace model) | EN 96.8% top-1, 99.7% top-3; ES 96.4%, 100%. Real-finger accuracy unmeasured |
| Autocorrect | 200 synthetic noisy-tap typos per language; 1,000 correctly typed common words | EN fixes 187, ES 189; changes 0 correct words. Real typing unmeasured |
| Typing rules (capitals, double-space full stop, revert, swipe spacing) | Unit tests, and UI tests driving the keyboard in the Simulator | See the test files |
| Keystroke latency | Not yet measured on a phone. Provisional target: under one 120 Hz frame (8 ms) of our own handling per key, logged as `latency` in the keyboard | Untested |
| Keyboard memory | Not yet measured. Provisional target: 40 MB, well under the ~60 MB commonly reported limit (Apple documents no number) | Untested |

The targets are our own provisional choices, not Apple figures. Parity with Apple's keyboard will only be claimed
from side-by-side measurements on a phone.

## Third-party code and data

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
