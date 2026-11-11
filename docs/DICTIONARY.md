# Project dictionary

## Terms

### Transcription

Conversion of recorded speech into text, before cleanup.

### Cleanup

An optional pass over an existing transcript to adjust wording or punctuation. It is measured separately from transcription.

### Word guard

The code that checks cleanup output against the spoken words. It reduces unwanted changes; it is not a guarantee of transcript accuracy.

### Word error rate

Substitutions, deletions and insertions divided by reference words. Each benchmark records its reference and normalization rules.

### Decode latency

Time spent transcribing audio already available to the benchmark. It excludes recording and cleanup unless a run explicitly states otherwise.

### First-token latency

Time until a cleanup model produces its first token, distinct from completing the cleanup response.

### Synthetic keyboard test

A test driven by generated traces or typing inputs. It does not measure real-finger accuracy.

### Product names

`voice2text` is the repository and Python distribution; `v2t` is its command-line executable. `Voice2Text` is the Mac app and `V2T` is the iOS project name. Their capitalization identifies different interfaces and must follow the source for that interface.

## Exceptions
