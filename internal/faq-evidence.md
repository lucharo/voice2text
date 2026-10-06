<!-- Maintainer-only. Never built into the docs site; public pages never link here. -->

# User FAQ: sources and verification

The answers users read are in `docs/faq.md`. These are the original entries with their code sources, measurements and verification dates, including notes from the managed work Mac.

## How can I tell whether Voice2Text is still loading or healthy?

**Short answer:** “Loading transcription model…” means startup is still in progress. “Stop v2t”
only means the engine process exists; it does not prove the models are ready. The app is ready when
the menu says “Ready” or `v2t status` reports `idle`, permissions are granted, and no launch error is
shown. That confirms service-level health, but only a real hold-and-release hotkey dictation (Fn by
default) confirms end-to-end recording, transcription, cleanup and paste.

If the menu remains on a loading state, allow first-launch model loading to finish and inspect
**Log**. “Could not start — open Log” or a non-empty error field from `v2t status` is an explicit
failure. During active use, `recording`, `transcribing`, and `cleaning` are healthy working states.

### Sources

- [Menu state rendering](../v2t/native/Voice2Text.swift) — maps startup, ready, active and error
  states and shows why “Stop v2t” can appear before readiness.
- [Status command](../v2t/cli.py) — reports live state, selected models, mode and launch error.
- [Smoke tests](../tests/test_smoke.py) — verifies the `idle` status output and error-state
  behaviour.
- [README usage](../README.md) — documents the live menu states, `v2t status`, permissions and
  the hotkey interaction.

_Created: 2026-08-29 · Updated: 2026-08-29 · Verified: 2026-08-29 · Scope/version: v0.3.0
behaviour._

## Why did the models take 45 seconds to load, and does v2t ever need the Hugging Face revision checks?

**Short answer:** The weights load in about 2 s from the local cache. The rest was Hugging Face's
revision check, one round trip per model file, which stalls on slow or SSL-intercepted networks.
Measured on hotel Wi-Fi: Parakeet 45 s → 0.5 s and the cleanup model 19 s → 1.2 s with the checks
off. v2t now turns them off whenever the model's snapshot is already in the cache, and never needs
them at that point: a dictation tool has no reason to follow upstream weight updates on a warm start.
The checks still run for a first download or a partial cache, where the network is genuinely needed.

### Sources

- [`load_cache_first`](../v2t/backends.py) — flips `huggingface_hub.constants.HF_HUB_OFFLINE`
  around the load when `cached_locally` finds a snapshot, and retries online on failure.
- [Smoke tests](../tests/test_smoke.py) — `test_cached_models_load_without_hub_revision_checks`
  and `test_partial_cache_falls_back_to_an_online_load`.
- [README startup time](../README.md#startup-time) — the user-facing statement.

_Created: 2026-09-04 · Updated: 2026-09-04 · Verified: 2026-09-04 (timings measured on an M4 Pro)._

## Why does the login service need the menu app? Why can't the engine just run all the time?

**Short answer:** Because macOS grants the microphone to an app identity, not to a bare process. The
engine is a Python process; started from a terminal it borrows that terminal's Microphone and
Accessibility grants, and started by `launchd` on its own it has no identity to be granted to, so
the microphone is silently denied. `Voice2Text.app` exists to be that identity: it asks for the two
permissions once, then starts and supervises one warm engine, and `v2t service install` launches the
same bundle at login so both routes share one stable grant. On a managed Mac that blocks unsigned
apps, the working alternative is a terminal window that stays open with `v2t` running; a Developer
ID-signed and notarised bundle would restore the menu route there.

### Sources

- [Menu app source](../v2t/native/Voice2Text.swift) — requests microphone and accessibility, then
  launches the engine with `V2T_LAUNCH_CONTEXT=menubar`.
- [LaunchAgent](../v2t/service.py) — `ProgramArguments` runs the app bundle, not Python.
- [README menu-bar section](../README.md#optional-menu-bar-app) — permissions paragraph.

_Created: 2026-09-04 · Updated: 2026-09-04 · Verified: 2026-09-04 · Scope: v0.3.x on macOS 26; the
launchd-without-bundle path has not been re-tested on this macOS version._

## How do I change between the pill styles?

**Short answer:** Open the menu-bar waveform icon and choose **Pill**. **Near text cursor** is the
default; in an app that exposes no text caret it sits at the bottom of the focused field or pane.
**Bottom of screen** pins it there, and **Off** hides it.

The bubble sits at the caret in apps that report caret bounds through accessibility: native text
views (TextEdit, Notes, Mail, Messages, Xcode) and, since 0.5.5, Chromium and Electron fields with
text in them (Chrome, Brave, Claude, Slack), measured from the character before the caret. An empty
Chromium field reports no caret, so the pill sits just below the field. Ghostty 1.3.1 reports its
focused pane but not where the cursor is inside it (its accessibility view has no caret-bounds
call), so there the pill sits at the bottom of the pane you are typing in.

The live transcript is experimental and off by default since 0.5.5: `live_transcript = true` under
`[transcription]` in `config.toml` turns it on. Words appear about 1 s after you say them, but an
early wrong word can pull you into correcting yourself mid-sentence. Cleanup shows a live seconds
counter. Placement persists across launches. See the
[README pill controls](../README.md#optional-menu-bar-app) for Esc and Undo behaviour.

### Sources

- [Native menu and pill](../v2t/native/Voice2Text.swift) — selector, defaults, caret and pane
  anchors, rendering.
- [Ghostty 1.3.1 surface view](https://github.com/ghostty-org/ghostty/blob/v1.3.1/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift)
  — accessibility overrides, none for caret bounds.
- [Streaming constants](../v2t/backends.py) — `STREAM_CHUNK_S`, `PREVIEW_STEP_S` and the
  2026-10-06 preview measurements.
- [Engine status](../v2t/app.py) and [smoke tests](../tests/test_smoke.py) — streaming capability.

_Created: 2026-10-05 · Updated: 2026-10-05 · Verified: 2026-10-05 · Scope: v0.5.0 source,
native build and automated checks; live selector interaction was not exercised in this audit._

## A dictation came out as noise. Which microphone did v2t record from, and was it live?

**Short answer:** Look at the dictation's history row: `sqlite3 ~/.v2t/history/history.sqlite
"select ts, device, audio_s, loud_frac, peak, outcome from transcriptions order by id desc limit 5"`.
`device` is the macOS default input at the moment the recording started, and `loud_frac` is the
share of the recording with speech-level sound (a real dictation reads well above 0.1; a dead
input reads about 0, often with a `peak` near 1.0 from the pop of a Bluetooth link opening). When
`loud_frac` is under 2%, v2t already told you at the time: the text was pasted, but the log, a
macOS notification and the `warning` field of `v2t status` named the device and the level. The
usual cause is a Bluetooth headset whose hands-free (HFP) microphone link another app holds, Teams
in particular. Check System Settings → Sound → Input while speaking; if the meter does not move,
pick another input there. The last recording's audio is kept at `~/.v2t/run/last-recording.wav`
for `v2t transcribe`.

### Sources

- [Level measurement](../v2t/app.py) — `audio_levels` and `level_warning` define `loud_frac`
  (100 ms frames above RMS 0.01, in runs of three or more, so a click does not count) and the 2%
  threshold; `_default_input_name` records the device.
- [History schema](../v2t/config.py) — `HISTORY_COLUMNS` lists every column, including
  `device`, `rms`, `peak`, `zero_frac`, `loud_frac`, `level_warning` and `outcome`.
- [README history](../README.md) — the same query and the warning's three surfaces.

_Created: 2026-09-11 · Verified: 2026-09-11 (a 62 s headset recording with `loud_frac` 0.0 and a
1.0 peak at 1.6 s; the built-in microphone read as `loud_frac` above 0.9 in tests)._

## How do I get the menu app onto a Mac that has no Apple signing identity, such as a managed work laptop?

**Short answer:** Install the prebuilt one. `brew trust --tap lucharo/voice2text && brew trust --cask lucharo/voice2text/voice2text`
(Homebrew 6 refuses to load a third-party tap it has not been told to trust), then `brew tap lucharo/voice2text https://github.com/lucharo/voice2text.git` and
`brew install --cask voice2text` put a `Voice2Text.app` signed with a Developer ID Application
certificate (team `7V3HZUL435`), notarised by Apple and stapled, into `/Applications`; Gatekeeper
accepts it with no certificate on the installing Mac. The engine is still `uv tool install
voice2text`: the shell carries no user paths and finds `~/.v2t` and that interpreter at launch,
and its menu says "v2t is not installed" with the command to run when it cannot. `v2t menubar
install` still compiles a local copy into `~/Applications` when a signing identity is available,
but refuses once the cask is installed, because two copies share one bundle ID and take each other's
permissions (see the next question). On the GSK-managed Mac the notarised cask launches and
endpoint security (defendpointd) logs no rule match for it. If endpoint security refuses the
notarised app, the block is on the publisher team, which only the
device administrator can allow-list.

### Sources

- [Release script](../scripts/release-macos.sh) — `v2t menubar build` for the portable bundle,
  then notarise, staple, verify, upload to the GitHub Release and rewrite the cask.
- [Cask](../Casks/voice2text.rb) — served straight from the GitHub Release; the repository is
  public, so no token is involved.
- [Swift shell](../v2t/native/Voice2Text.swift) — the launch-time fallback to `~/.v2t` and the
  `uv tool` interpreter when nothing is baked into Info.plist.

_Verified: 2026-09-28 · Scope: v0.4.1. Allow-listing the team on a managed Mac is outside this
repository._

## Why does the menu app ask for Microphone or Accessibility again when I already granted it?

**Short answer:** Usually because a second copy of `Voice2Text.app` exists, most often an old
`v2t menubar install` build in `~/Applications` beside the cask in `/Applications`. Both carry the
bundle ID `com.lucharo.voice2text`, and macOS keeps one grant per ID pinned to one signature, so
whichever copy asks last takes the grant from the other, and Spotlight may open either. Since
v0.4.1 the menu names a second copy with a button that bins it (or hands over to `/Applications`),
and `v2t menubar install` refuses beside the cask. After removing the extra copy, one fresh grant
sticks; **Reset Permissions** in the menu clears a grant pinned to an older signature. A single
re-prompt right after `tccutil reset` or a first install is expected. Since v0.4.1 Start also waits
for the Accessibility switch instead of failing, so you no longer press Start twice.

### Sources

- [Swift shell](../v2t/native/Voice2Text.swift) — `otherCopy`, `resolveOtherCopy`,
  `resetPermissions` and the `awaiting-accessibility` phase.
- [Menu app install](../v2t/menubar.py) — the refusal when the cask copy exists.
- The unified log shows the cause: `log show --predicate 'subsystem == "com.apple.TCC"'` prints
  `Failed to match existing code requirement` with each copy's `binary_path`.

_Verified: 2026-09-28 · Scope: v0.4.1. Diagnosed on the GSK Mac, where a 0.3.0 ad-hoc build in
`~/Applications` was taking the cask's grants._

## Where does the app icon come from?

**Short answer:** From the waveform logo in `assets/logo/` (the real waveform of the words "voice
to text", from #18). Since v0.4.1 `assets/logo/app-icon.sh` renders `logo.svg` onto the macOS icon
grid into `v2t/native/AppIcon.icns`, and the bundle build copies it into `Contents/Resources` with
`CFBundleIconFile`, so both the cask and `v2t menubar install` show it in Finder and the privacy
panes. The menu-bar glyph is a separate SF Symbol that changes with state.

### Sources

- [Logo README](../assets/logo/README.md) — how the logo and the icon are regenerated.
- [Menu app build](../v2t/menubar.py) — where the icon enters the bundle.

_Verified: 2026-09-28 · Scope: v0.4.1._
