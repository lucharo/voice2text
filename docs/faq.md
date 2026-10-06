# FAQ

## Is v2t still loading, or is it ready?

- **Ready:** the menu says **Ready**, or `v2t status` starts with `idle`.
- **Still loading:** the menu says "Loading transcription model…", or `v2t status` says
  `loading-stt` or `loading-cleanup`. The first launch downloads the models, so it takes longer.
- **Failed:** the menu says "Could not start — open Log", or `v2t status` says `launch-error` with
  the reason.

**Stop v2t** in the menu only means the engine process exists, not that it is ready. A real
dictation is the only end-to-end proof.

## Why does the menu app exist? Can't the engine just run on its own?

macOS gives the microphone to an app, not to a bare process. Started from a terminal, the engine
borrows that terminal's permissions; started on its own at login, it has none, and the microphone
is silently denied. `Voice2Text.app` is the app that holds the two permissions and starts the
engine, and `v2t service install` launches that same app at login.

## A dictation came out as nonsense. Which microphone did it use?

Look at the last few entries in the history:

```bash
sqlite3 ~/.v2t/history/history.sqlite \
  "select ts, device, audio_s, loud_frac, outcome from transcriptions order by id desc limit 5"
```

- `device` is the macOS input at the moment you started.
- `loud_frac` is the share of the recording with speech-level sound. A real dictation is well above
  0.1; a dead input is about 0.
- Below 2%, v2t already warned you at the time, in the log, a notification and `v2t status`.

The usual cause is a Bluetooth headset whose microphone another app (often Teams) is holding. Speak
and watch System Settings → Sound → Input; if the meter does not move, pick another input there.
The audio is still at `~/.v2t/run/last-recording.wav` for `v2t transcribe`.

## How do I move the pill or hide it?

Open the menu-bar icon and choose **Pill**:

- **Near text cursor**: the default. A speech bubble beside the text box, its tail at the caret;
  in a Ghostty split, at the bottom of the pane.
- **Bottom of screen**: always there.
- **Off**: no pill.

The choice persists across launches. The live transcript is experimental and off;
`live_transcript = true` under `[transcription]` in the [config](reference/config.md) turns it on.

## Can I install the menu app on a managed work Mac?

Yes. The Homebrew app is signed with a Developer ID certificate, notarised by Apple and stapled, so
macOS accepts it with no signing certificate on your Mac. Install it as in
[Getting started](getting-started.md#the-menu-app-optional). If your company's endpoint security
still blocks it, only your device administrator can allow it.

## Why does the menu app keep asking for Microphone or Accessibility?

Almost always because there are two copies of `Voice2Text.app`, usually an old `v2t menubar
install` build in `~/Applications` beside the Homebrew one in `/Applications`. macOS keeps one
permission per app identity, so the copy that asked last takes it from the other.

- The menu names a second copy and offers a button to remove it.
- After removing it, grant the permissions once more; **Reset Permissions** in the menu clears an
  old grant.
- One prompt right after a fresh install is expected.
