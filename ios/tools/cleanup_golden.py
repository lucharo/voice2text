#!/usr/bin/env python3
"""Write the golden fixture the Swift cleanup port (V2TCleanup) is tested against, from the real Python in
v2t/backends.py. Run from the repo root and commit the output:

    uv run python ios/tools/cleanup_golden.py

Every case records the Python inputs and outputs; the Swift tests assert byte-for-byte equality. Hand-written
cases cover each branch of keep_spoken_words in English and Spanish; a seeded fuzz adds edit shapes nobody
thought of. A table of the code points Python's `\\w` and `str.isdigit()` accept pins the Unicode semantics.
"""
import difflib
import json
import random
import re
import sys
import unicodedata
from pathlib import Path

from v2t import backends

OUT = Path(__file__).resolve().parents[1] / "Packages/V2TKeyboardCore/Tests/V2TCleanupTests/golden.json"

VOCAB = ["Claude", "Claude Code", "Codex", "GPT-4", "5.1"]
NFD_CAFE = unicodedata.normalize("NFD", "café")

# (raw, clean, vocabulary)
KEEP = [
    # the Python suite's cases (tests/test_smoke.py)
    *[(r, c, ["Claude", "Claude Code"]) for r, c in [
        ("send three red boxes tomorrow", "Send 3 blue boxes tomorrow."),
        ("it says twenty five percent", "It said 25%."),
        ("send three red boxes tomorrow", "Send 3 boxes tomorrow."),
        ("she says", "She said."),
        ("ship it", "Ship it to Claude."),
        ("we think it is", "We think it's."),
        ("send clod the report today", "Send Claude today."),
        ("clock code is great", "Claude Code is great."),
        ("she leaves clod stays", "She left. Claude stays."),
        ("send clod one today", "Send Claude today."),
        ("I can can attend on Friday", "I attend on Friday."),
        ("send it to me please", "Send it to me."),
        ("it is fine", "It's fine."),
        ("we met clod yesterday", "We met Claude yesterday."),
    ]],
    *[(r, c, VOCAB) for r, c in [
        ("ask codecs and clot", "Ask Codex and Claude."),
        ("ask gpt four for help", "Ask GPT-4 for help."),
        ("please ask clot clot about it", "Please ask Claude about it."),
        ("use model five point one", "Use model 5.1."),
        ("we met him yesterday", "We met Claude yesterday."),
        ("uh at a good size", "Codex at a good size."),
        ("ship it on friday", "Ship Claude Code Codex on Friday."),
        ("ask clot today", "Ask Claude Codex today."),
    ]],
    ("uh PR three five nine is is done by clot", "PR #359 is done by Claude.", ["Claude"]),
    ("she says it is fine", "She said it's really fine.", []),
    ("um I think that we should ship the migration and then test it on friday",
     "I think we should ship the migration, then test it on Friday.", []),
    # equal, and empty sides
    ("hello there", "Hello there.", []),
    ("", "", []),
    ("hello there", "", []),
    ("", "Hello there.", []),
    ("   ", "  ", []),
    # insert: added words come out, the end mark moves onto the last word kept
    ("we ship today", "We really ship today.", []),
    ("ship it", "Ship it to you", []),
    ("ship it", "Ship it. Thanks!", []),
    ("hello there", "Hello — there.", []),
    ("hello there", "Hello there — friend…", []),
    ("we met", "We met Claude.", ["Claude"]),
    # replace: peeled head and tail, punctuation carried, sentence case
    ("she said that", "She says that.", []),
    ("it was good. then we left", "It is good. Then we leave.", []),
    ("they go home", "They went home!", []),
    ("send three boxes", "Send 3 boxes?", []),
    ("send three boxes", "Send four boxes.", []),
    ("send twenty five boxes", "Send 25 boxes.", []),
    ("we paid twenty five dollars", "We paid $25.", []),
    ("half past three", "3:30.", []),
    ("it is twenty five percent off", "It's 25% off.", []),
    ("the pr three five nine merged", "The PR #359 merged.", []),
    ("i think it is", "I think it's.", []),
    ("he is.", "He's.", []),
    ("we think it is.", "We think it's.", []),
    ("i am ok", "I'm OK.", []),
    ("clot said hi", "Claude said hi.", ["Claude"]),
    ("tell clod hi", "Tell Claude, hi.", ["Claude"]),
    ("tell the team hi", "Tell Claude hi.", ["Claude"]),
    ("ask gpt four and clot", "Ask GPT-4 and Claude.", VOCAB),
    ("model five point one ships", "Model 5.1 ships.", VOCAB),
    ("five point one", "5.1 Claude.", VOCAB),
    ("codecs codecs ship it", "Codex ship it.", VOCAB),
    ("x squared", "x².", []),
    ("send it now please now", "Send it, please, now.", []),
    # delete: fillers, repeats, words put back before the end mark
    ("um hello", "Hello.", []),
    ("um uh erm hello there mm", "Hello there.", []),
    ("the the report", "The report.", []),
    ("can can can attend", "Attend.", []),
    ("I think that we should go", "I think we should go.", []),
    ("send it to me please.", "Send it to me.", []),
    ("send it to me please now", "Send it to me!", []),
    ("hello — there", "Hello there.", []),
    ("so basically we ship", "We ship.", []),
    ("we ship it it", "We ship it.", []),
    ("ship the migration and then test", "Ship the migration, then test.", []),
    # Spanish: accents and ñ are word characters, number words are English only
    ("eh pues mañana vamos a la playa", "Mañana vamos a la playa.", []),
    ("él está aquí", "Él está aquí.", []),
    ("qué tal estás", "Que tal estas?", []),
    ("el niño dijo que sí", "El niño dijo que sí.", []),
    ("tengo veinticinco años", "Tengo 25 años.", []),
    ("tengo tres hermanos", "Tengo 3 hermanos.", []),
    ("dijo que que vendría mañana", "Dijo que vendría mañana.", []),
    ("bueno pues creo que sí", "Creo que sí.", []),
    ("habla con clod mañana", "Habla con Claude mañana.", ["Claude"]),
    ("habla con el jefe mañana", "Habla con Claude mañana.", ["Claude"]),
    ("la cigüeña voló", "La cigüeña voló.", []),
    ("vamos al cine y luego cenamos", "Vamos al cine, luego cenamos.", []),
    ("ella dice que está bien", "Ella dijo que está bien.", []),
    # Python str semantics: Unicode whitespace, apostrophes, case mapping, NFC vs NFD, digits
    ("hola\u00a0mundo", "Hola mundo.", []),
    ("one\x1ctwo three", "One two three.", []),
    ("zero\u200bwidth", "Zero width.", []),
    ("it’s fine", "It's fine.", []),
    ("ΟΔΟΣ καλός", "οδος καλός.", []),
    ("İstanbul calling", "istanbul calling.", []),
    (NFD_CAFE + " time", "Café time.", []),
    ("café time", NFD_CAFE.capitalize() + " time.", []),
    ("send ٣ boxes", "Send 3 boxes.", []),
    ("snake_case word", "Snake case word.", []),
    ("ßtraße ok", "SStraße ok.", []),
]

FUZZ_WORDS = "the a send it report clod codecs three five twenty um uh can is said says we ship today mañana qué".split()
FUZZ_CLEAN = ["Claude", "Codex", "3", "25", "#42", "it's", "Send", "The", "—", "really"]


def fuzz_cases(n: int) -> list[tuple[str, str, list[str]]]:
    rng = random.Random(75)
    cases = []
    for _ in range(n):
        raw = [rng.choice(FUZZ_WORDS) for _ in range(rng.randint(1, 9))]
        clean = list(raw)
        for _ in range(rng.randint(1, 3)):
            op = rng.choice(["drop", "swap", "add", "punct", "case", "dup"])
            i = rng.randrange(len(clean)) if clean else 0
            if op == "drop" and clean:
                del clean[i]
            elif op == "swap" and clean:
                clean[i] = rng.choice(FUZZ_CLEAN)
            elif op == "add":
                clean.insert(i, rng.choice(FUZZ_CLEAN + FUZZ_WORDS))
            elif op == "punct" and clean:
                clean[i] += rng.choice([".", ",", "?", "!", "…", ";"])
            elif op == "case" and clean:
                clean[i] = clean[i][:1].upper() + clean[i][1:]
            elif op == "dup" and clean:
                clean.insert(i, clean[i])
        if clean:
            clean[0] = clean[0][:1].upper() + clean[0][1:]
            clean[-1] += rng.choice(["", ".", "?"])
        cases.append((" ".join(raw), " ".join(clean), rng.choice([[], ["Claude"], VOCAB])))
    return cases


SOUNDS = [
    ("clock", "Claude"), ("clot", "Claude"), ("clod", "Claude"), ("the", "Claude"), ("codecs", "Codex"),
    ("gpt", "GPT-4"), ("four", "GPT-4"), ("him", "Claude"), ("uh", "Codex"), ("", ""), ("a", ""),
    ("jose", "José"), ("nino", "Niño"), ("parakeet", "Parakeet"), ("para kit", "Parakeet"),
    ("whisper", "Whisper"), ("we spur", "Whisper"), ("ollama", "Ollama"), ("llama", "Ollama"),
    ("qwen", "Qwen"), ("when", "Qwen"), ("y", "why"), ("h", "a"), ("hhh", "www"),
]

CHUNKS = [
    (" ".join(f"Sentence number {i} has exactly seven words." for i in range(40)), 120),
    (" ".join(["word"] * 300), 120),
    ("", 120),
    ("   \n  ", 120),
    ("One. Two! Three? Four… Five", 2),
    ("One.  Two.\tThree.\nFour. Five.", 1),
    ("Wait... what?! Yes.", 120),
    ("No break.Here", 120),
    ("A b c. D e f g h. I j.", 4),
    ("A b c. D e f g h i j k. L.", 3),
    ("Hola. ¿Qué tal? Muy bien, gracias. Adiós.", 3),
    ("  Leading and trailing.   ", 120),
    ("Mr. Smith went. To town.", 2),
]

GUARD = [
    ("one two three four five", "One two three.", "strict"),
    ("one two three four five", "One two three.", "casual"),
    ("one two three four five", "One two three four.", "casual"),
    ("one two three four five", "One two.", "strict"),
    ("a b c d e f g h i j", "A b c d e f g h i j k l m.", "strict"),
    ("a b c d e f g h i j", "A b c d e f g h i j k l m n.", "casual"),
    ("", "", "strict"),
    ("", "Hello.", "casual"),
    ("hello", "", "casual"),
    ("hola mundo", "Hola mundo.", "strict"),
    ("a b c d e", "A b c.", "strict"),
    ("a b c d", "A b c.", "casual"),
    ("so uh we have uh we have set a course", "So we have set a course.", "casual"),
    ("so uh we have uh we have set a course", "So we have set a course.", "strict"),
    ("the the plan um is is fine", "The plan.", "casual"),
    ("Uh, uh. The, the plan", "The plan.", "casual"),
    ("uh we have uh we have set a clear course uh and we deliver", "We have set a clear course and we deliver.", "casual"),
    ("we have set we have set it", "We have set it.", "casual"),
    ("I think I think so", "I think so.", "casual"),
]

MESSAGES = [
    ("raw words", "casual", []),
    ("hello um there", "strict", []),
    ("x", "casual", ["Claude", "  ", "", " Parakeet  ", "GPT-4"]),
    ("¿qué tal?", "strict", ["José ", "Niño"]),
]

BARE = ["Hello,", "it's", "it’s", "Mañana.", "ÉL", "#42", "x²", "½", "snake_case", "—", "...", "ΟΔΟΣ",
        "Σ", "İstanbul", NFD_CAFE, "Straße", "٣", "a-b", "ǅemal", "ⅷ"]

OPCODES = [
    ("the cat sat on the mat".split(), "a cat sat on a mat".split(), False),
    ("a b c d e".split(), "e d c b a".split(), False),
    ("x x x y".split(), "x y y y".split(), False),
    ([], "a b".split(), False),
    ("a b".split(), [], False),
    ([], [], False),
    (["w"] * 210 + ["z"], ["w"] * 205 + ["z"], True),
    (["w"] * 210 + ["z"], ["w"] * 205 + ["z"], False),
]

RATIOS = [
    ("abcd", "bcde"), ("clck", "cld"), ("", ""), ("a", ""), ("tide", "diet"),
    ("ab" * 150, "ba" * 120 + "c"), ("qwertyuiop" * 25, "qwertyuiop" * 24 + "x"),
]


def ranges(pred) -> list[list[int]]:
    out, start = [], None
    for cp in range(sys.maxunicode + 2):
        hit = cp <= sys.maxunicode and pred(chr(cp))
        if hit and start is None:
            start = cp
        elif not hit and start is not None:
            out.append([start, cp - 1])
            start = None
    return out


def main() -> None:
    keep = KEEP + fuzz_cases(60)
    word = re.compile(r"\w")
    golden = {
        "python": sys.version.split()[0],
        "unicode": unicodedata.unidata_version,
        "keep_spoken_words": [
            {"raw": r, "clean": c, "vocabulary": v, "text": t, "counts": counts}
            for r, c, v in keep
            for t, counts in [backends.keep_spoken_words(r, c, v)]
        ],
        "sounds_alike": [{"spoken": s, "written": w, "alike": backends.sounds_alike(s, w)} for s, w in SOUNDS],
        "chunk_text": [{"text": t, "max_words": m, "chunks": backends.chunk_text(t, m)} for t, m in CHUNKS],
        "within_length_guard": [
            {"raw": r, "clean": c, "mode": m, "ok": backends.within_length_guard(r, c, m)} for r, c, m in GUARD
        ],
        "cleanup_messages": [
            {"text": t, "mode": m, "vocabulary": v, "messages": backends.cleanup_messages(t, m, v)}
            for t, m, v in MESSAGES
        ],
        "bare": [{"token": t, "bare": backends._bare(t)} for t in BARE],
        "opcodes": [
            {"a": a, "b": b, "autojunk": j,
             "opcodes": [list(op) for op in difflib.SequenceMatcher(a=a, b=b, autojunk=j).get_opcodes()]}
            for a, b, j in OPCODES
        ],
        "ratio": [{"a": a, "b": b, "ratio": difflib.SequenceMatcher(a=a, b=b).ratio()} for a, b in RATIOS],
        "word_char_ranges": ranges(lambda ch: bool(word.match(ch))),
        "digit_ranges": ranges(str.isdigit),
        "space_ranges": ranges(str.isspace),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(golden, ensure_ascii=True, indent=1) + "\n")
    print(f"wrote {OUT} ({len(keep)} keep_spoken_words cases)")


if __name__ == "__main__":
    main()
