# Logo

The mark is the real waveform of the words "voice to text", spoken by Kokoro
(`mlx-community/Kokoro-82M-bf16`, voice `af_heart`) and kept here as
`voice-to-text.wav`. `waveform.py` turns that file into `logo.svg`: the
RMS envelope over 16 windows, drawn as a symmetric bar waveform on the navy
`#11182d`, bars in cream `#f2e7ca`, the loudest window in gold `#f2d581`.
`logo-28.svg` is the same audio at 28 bars for larger sizes.

Regenerate:

```sh
uvx --from mlx-audio --with "misaki[en]" python -m mlx_audio.tts.generate \
  --model mlx-community/Kokoro-82M-bf16 --text "voice to text" --voice af_heart \
  --output_path assets/logo --file_prefix voice-to-text
uv run assets/logo/waveform.py assets/logo/voice-to-text.wav assets/logo/logo.svg 16
```
