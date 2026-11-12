# Privacy

v2t collects no data. It has no account, no analytics, no ads and no tracking, and its maintainer
receives nothing about you or your use of it.

## On iPhone and iPad

- **Your speech** is transcribed on the device. The recording and the text stay on it.
- **What you type** with the v2t keyboard stays on the device, apart from the words you keep
  (below). The keyboard asks for Full Access only so it can ask the v2t app to record; it sends
  nothing anywhere.
- **Cleanup** with Apple Intelligence runs on the device too.
- **History** is kept on the device until you delete it, in the app or by deleting the app.
- **Your dictionary and the words you keep on the keyboard** are kept on the device and, unless you
  turn off **Sync with iCloud** on the Dictionary screen, copied to your other iPhones and iPads
  through your private iCloud database. Only your iCloud account can open that database, v2t's
  maintainer cannot see it, and it counts toward your iCloud storage. The words are encrypted on
  the device before they go; with Advanced Data Protection on, only your devices hold the keys.
  Nothing else goes to iCloud: never audio.
- **The speech model download** is the one time v2t itself uses the network. When you tap Download, the
  app fetches the model's files from [Hugging Face](https://huggingface.co/privacy), which, like any
  website, sees your device's IP address. v2t sends nothing else with the request.

TestFlight builds also share crash reports and feedback with the maintainer when you choose to
send them through TestFlight; Apple's [TestFlight terms](https://www.apple.com/legal/internet-services/itunes/testflight/)
cover that.

## On the Mac

Speech is transcribed on your Mac. The Mac app uses the network to download models from Hugging
Face when it first needs them and to ask PyPI whether a newer version exists. Cleanup with Ollama
uses the Ollama server on your own Mac by default; if you set `ollama.url` to another machine, v2t
sends the transcript and your dictionary's terms to that server for cleanup.

## Contact

Questions about privacy go to a [GitHub issue](https://github.com/lucharo/voice2text/issues) or to
the maintainer, Luis Chaves Rodriguez, through [luischav.es](https://luischav.es).
