# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "soundfile"]
# ///
"""Render the amplitude envelope of a WAV as a symmetric bar waveform SVG.

usage: uv run waveform.py in.wav out.svg [bars]
"""
import sys
import numpy as np
import soundfile as sf

src, dst = sys.argv[1], sys.argv[2]
BARS = int(sys.argv[3]) if len(sys.argv) > 3 else 28
audio, sr = sf.read(src, dtype='float32', always_2d=True)
x = audio.mean(axis=1)
# trim leading/trailing silence so the word fills the mark
thr = 0.02 * np.abs(x).max()
idx = np.where(np.abs(x) > thr)[0]
x = x[idx[0]:idx[-1] + 1]
# RMS envelope over BARS windows
win = len(x) // BARS
env = np.array([np.sqrt(np.mean(x[i * win:(i + 1) * win] ** 2)) for i in range(BARS)])
env = env / env.max()
env = np.maximum(env, 0.06)  # keep a visible tick for near-silent windows

W = H = 72
pad = 12
usable = W - 2 * pad
gap = 1.6
bw = (usable - gap * (BARS - 1)) / BARS
maxh = 40
peak = int(np.argmax(env))
bars = []
for i, e in enumerate(env):
    h = max(2.4, e * maxh)
    bx = pad + i * (bw + gap)
    by = H / 2 - h / 2
    bars.append(f'<rect x="{bx:.2f}" y="{by:.2f}" width="{bw:.2f}" height="{h:.2f}" rx="{bw / 2:.2f}" fill="#f2e7ca"/>')
# accent: the loudest window, the moment the word lands
bx = pad + peak * (bw + gap)
h = max(2.4, env[peak] * maxh)
bars[peak] = f'<rect x="{bx:.2f}" y="{H / 2 - h / 2:.2f}" width="{bw:.2f}" height="{h:.2f}" rx="{bw / 2:.2f}" fill="#f2d581"/>'
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" aria-label="waveform of the words voice to text">'
       f'<rect width="{W}" height="{H}" fill="#11182d"/>' + ''.join(bars) + '</svg>')
open(dst, 'w').write(svg)
print(f'{len(x) / sr:.2f}s of speech, {BARS} bars, peak at {peak}; wrote {dst}')
