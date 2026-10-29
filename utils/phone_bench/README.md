# iPhone bench

An iOS app that times speech-to-text and cleanup models on an iPhone. You give it a job file, it works
through the job by itself, and it resumes from its result files after any relaunch. The Mac only starts a
job and collects results, so you can unplug the phone partway through.

Runtimes ("arms") one app can alternate:

| runtime | set | what runs | model |
| --- | --- | --- | --- |
| `mlx` | cleanup | an LLM on the GPU through mlx-swift-lm | folder in Documents/models |
| `anemll` | cleanup | an ANEMLL Core ML LLM on the Neural Engine | folder in Documents/models |
| `afm` | cleanup | Apple Foundation Models (`options.wrap: "true"` for the wrapped prompt) | built in |
| `parakeet-coreml` | speech | Parakeet TDT v3 through FluidAudio on Core ML | bundled in Res/models |
| `mlx-stt` | speech | a speech model through mlx-audio-swift (`options.model_type`, default parakeet) | folder in Documents/models |
| `bark` | speech | Bark 3.0's Core ML encoder plus a Swift decoder (`options.units`: ane, gpu, cpu, all) | bundled in Res/bark |

## Set up

```sh
cd utils/phone_bench
./stage.py --from /path/to/Res   # clips, cleanup inputs and Core ML models; checked against res-manifest.json
./setup.sh build                 # fetches ANEMLL, generates the Xcode project, builds a Release app
```

`stage.py` describes each resource. They are not committed; `res-manifest.json` pins every file by SHA-256.
Set `V2T_TEAM` to your Apple development team before `setup.sh` if it is not the default.

Models the job reads from Documents/models come from `~/.v2t/eval/phone-models/<org>__<repo>` on the Mac,
for example:

```sh
hf download mlx-community/Qwen2.5-0.5B-Instruct-4bit --local-dir ~/.v2t/eval/phone-models/mlx-community__Qwen2.5-0.5B-Instruct-4bit
```

## Run a job

```sh
./phone_push.py jobs/smoke-q05.json             # install, copy models and the job, launch
./phone_sync.py jobs/smoke-q05.json --watch 120 # pull results every 2 min until the job ends
```

1. Plug the phone in (or pair it for Wi-Fi once in Xcode's Devices window) and unlock it.
2. `phone_push.py` installs the app, copies the job's models (skipping folders already there), writes the
   job to Documents/job.json and launches the app.
3. Put the app under Guided Access (below), then unplug if you like. Plugged in, the phone charges and each
   row says so; unplugged, rows show the battery falling.
4. `phone_sync.py` copies the results whenever the phone answers, over USB or Wi-Fi, and prints one line:
   items done per arm, the rate, the estimated end, the current block, the last row's age, thermal state
   and battery. Out of reach, it reports from the last copy. A local copy is only replaced by a phone copy
   that extends it; one that diverges (a reinstalled app, a job restarted under the same name) is kept
   beside it as `<file>.diverged-<time>.jsonl`, so synced results are never lost.

To see what the phone is doing without the Mac, look at its screen: it shows the arm, block and item.

### Keeping the app in front

iOS gives a background app no GPU, so an MLX arm stops dead the moment the app leaves the screen, and a
lock suspends every arm. The app turns off the idle timer, so the screen does not dim or lock by itself.
Guided Access stops a tap, a swipe or the side button from sending it away:

1. Settings › Accessibility › Guided Access: turn it on, set a passcode, and set Display Auto-Lock to Never.
2. Open the bench app and triple-click the side button, then tap Start. In Options you can turn off Touch
   and the Side Button too.
3. To leave, triple-click the side button and enter the passcode.

Turn Low Power Mode off before a run; every row records it.

If the app dies anyway (Jetsam, a crash), tap its icon: with no launch arguments it reads Documents/job.json
and resumes. `phone_sync.py --relaunch-after 10` does the same from the Mac once the phone is reachable and
no row has arrived for 10 minutes, provided the phone's job.json is still this job.

Background execution (`BGProcessingTask` with `requiresExternalPower`) could in principle carry the
Neural Engine and CPU arms while the phone is locked; it is not implemented or tested.

## The job file

```json
{
  "name": "smoke-q05",
  "set": "cleanup",
  "limit": 40,
  "block": 10,
  "order": "abba",
  "arms": [
    {"id": "anemll", "runtime": "anemll", "model": "anemll__anemll-Qwen-Qwen2.5-0.5B-Instruct-ctx2048-monolithic_0.3.5"},
    {"id": "mlx", "runtime": "mlx", "model": "mlx-community__Qwen2.5-0.5B-Instruct-4bit"}
  ]
}
```

| field | meaning |
| --- | --- |
| `name` | names the result files; a new name starts over, the same name resumes |
| `set` | `cleanup` (600 transcripts, Res/cleanup/inputs.jsonl) or `speech` (450 clips, Res/clips/manifest.tsv) |
| `offset`, `limit` | the slice of the set to run, in file order (default: all of it) |
| `rounds` | passes over the slice (default 1); speech timings used 3 |
| `block` | items one arm runs before the next arm takes over |
| `order` | `abba` (default: arms take turns, and each round reverses who goes first), `alternate` (ABAB) or `sequential` (all of one arm, then the next) |
| `arms` | `id` (unique, names its result file), `runtime` (table above), `model` (folder in Documents/models), `options` |

Every arm runs every item. The schedule is a fixed list of (arm, block) steps. At each launch the app takes
the first step whose arm has not done all of that block's items, so the result files are the only state:
kill the app mid-block and the next launch reruns only the items with no row. Two blocks in a row for the
same arm keep its model loaded; switching arms unloads one model and loads the other.

## Result files

In the app's Documents, copied by `phone_sync.py` to `~/.v2t/eval/phone-jobs/<name>/`:

- `<name>.<arm>.jsonl`: one `clean` (cleanup) or `clip` (speech) row per item with `id`, `key` (`<round>|<id>`
  when `rounds` > 1), `r`, `block`, `s` (seconds), the output (`clean` or `text`) and runtime fields (`ttft`,
  `tokens`, `limited`, `errors`); `start`, `load` and `unload` rows around each model load; `end` once the arm
  has done every item.
- `<name>.log.jsonl`: `start` per launch (the job, item count, items already done), `block_start` and
  `block_end`, a heartbeat every 10 s, `app` rows for each app-state change (resign_active, background,
  locked, memory_warning, ...), and `end` when every arm is done.

Every row carries `t` (Unix time on the phone), `thermal` (0 nominal to 3 critical), `low_power`, `battery`
(0 to 1), `charging`, `avail_mb` and, on most rows, `mb` (the app's footprint). A gap in the heartbeats means
the app was suspended or dead. The existing scorers read `clean` rows by `id`, so these files drop into
them unchanged.

## One app for MLX and ANEMLL

ANEMLL's Swift package asks for swift-transformers' `main` branch, and a local package's branch requirement
overrides the app's own version pin, which is why ANEMLL used to live in a second app. ANEMLL's core
compiles unchanged against swift-transformers 1.3.5, the version mlx-swift-lm's tokenizer loader uses, so
`setup.sh` clones ANEMLL at a pinned revision (its Swift package is a subfolder of the repo, which SwiftPM
cannot fetch by URL) and rewrites that one requirement to `exact: "1.3.5"`.
