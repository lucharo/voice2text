# Help

## Is it ready?

The menu says **Ready**, or `v2t status` starts with `idle`. `loading-stt` and `loading-cleanup` mean the models are still loading. First use downloads them. `launch-error` includes the reason startup failed.

## Nothing happens when I hold Fn

Check Microphone and Accessibility access for your terminal or **Voice2Text**, whichever you launch. Set System Settings → Keyboard → **Press 🌐 key to** to **Do Nothing**. Hold Fn while speaking; a quick tap does not start dictation.

If Fn opens the emoji picker, the menu's **Globe Key** row opens that setting. To keep Fn for emoji, choose Right Command under **Settings → Hotkey** instead.

## The install used Python 3.14

The default Core ML backend needs Python 3.11 to 3.13. Reinstall with:

```bash
uv tool install --reinstall --python 3.13 voice2text
```

## It records, but does not paste

Click a text field before releasing Fn and check Accessibility permission. Recover the result with **Copy Last Transcription** in the menu or:

```bash
v2t history --last 1
```

Copy the displayed cleaned text and paste it into the intended field.

## The microphone is silent or the text is nonsense

Speak while watching System Settings → Sound → Input. If the input meter stays flat, choose another microphone. The dictation bubble's waveform shows the sound `v2t` captures. Check `v2t status` and the log for input warnings.

To retry the last recording:

```bash
v2t transcribe ~/.v2t/run/last-recording.wav
```

`behavior.keep_last_audio` must be enabled, as it is by default.

## Cleanup changed what I said

Compare the raw and cleaned text with `v2t history --last 1 --raw`. Try casual mode or `v2t --no-cleanup`. Use a [dictionary replacement](guide.md#dictionary) for a recurring spelling error. Cleanup cannot guarantee word-for-word fidelity.

## Permissions keep being requested

Check for two copies of **Voice2Text**, often in `/Applications` and `~/Applications`. The menu identifies a second copy. Keep one, then grant permissions again. **Reset Permissions** in the menu can clear an old grant after an app update.

## The bubble is misplaced or missing

Choose **Pill → Near text cursor**, **Bottom of screen** or **Off** in the menu. If an app does not expose its text cursor, the bubble uses a fallback position. Live words are off by default; enable **Settings → Live Words in Bubble (Experimental)** to try the preview.

## Which model should I choose?

Start with the default. [Benchmarks](benchmarks.md) shows the measured accuracy and speed trade-offs, with separate Mac, iPhone and cleanup results. [Configuration](reference/config.md) lists the available backends.

## Are there separate iPhone transcription and cleanup results?

Yes. [Benchmarks](benchmarks.md#on-the-iphone) separates speech recognition, cleanup fidelity and cleanup-engine timing, with links to the original measurements. The [Marimo notebook](benchmarks.md#marimo-notebook) covers Mac speech models; its working browser embed is still tracked separately.

## Where is the iPhone keyboard debug log?

In the app, open **Languages and typing → Debugging → Keyboard debug log**. See [Typing](iphone.md#typing) for what it records and how to export it. Check the version in TestFlight when a newly released feature is missing.

## How do TestFlight builds reach the App Store?

The [release guide](maintainers/index.md#how-do-i-promote-a-testflight-build-to-the-app-store) explains build selection and Apple review. It also covers [inviting friends and public links](maintainers/index.md#how-do-i-invite-friends-or-get-a-shareable-testflight-link).

<!-- FAQ dates: Created 2026-11-11; Updated 2026-11-11; Verified 2026-11-11. -->

## Where is the log?

`~/.v2t/run/v2t.log`. Include the relevant error and the output of `v2t config` when [reporting a problem](https://github.com/lucharo/voice2text/issues). Remove personal transcript text before posting.

## Which step made a dictation slow?

The log times transcription, cleanup and pasting separately. For an unusually slow cleanup, include the **stall mark** warning and nearby thread stacks in [#168](https://github.com/lucharo/voice2text/issues/168), after removing personal text. That investigation is still open.

---
<!-- doc-audit:last-reviewed -->
_Last reviewed: 2026-11-11 · commit `641c3a0` · verified against code._
