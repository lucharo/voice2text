# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "altair>=5.4",
#     "marimo",
#     "numpy",
#     "polars>=1.20",
#     "rapidfuzz",
#     "whisper-normalizer",
# ]
# ///
"""Speech-to-text model intake: every model we have run in the ASR grid, on one screen.

    uvx marimo edit --sandbox utils/model_intake/intake.py
    uvx marimo run --sandbox utils/model_intake/intake.py      # read-only

Reads the grid's per-clip results under ~/.v2t/eval/grid (scored by grid.score_set,
exactly as the grid's own report scores them) and the registry in models.toml beside
this file. Scores are cached in ~/.v2t/eval/grid/.intake-cache, keyed on the results
files' sizes and mtimes, so a load after the first takes under a second.
"""

import marimo

__generated_with = "0.25.2"
app = marimo.App(width="full", app_title="STT model intake")


@app.cell(hide_code=True)
def _(
    board,
    bullets,
    datetime,
    engines_page,
    gaps_note,
    GUTTER,
    html,
    INK,
    INK_2,
    LONDON,
    mo,
    overview_panels,
    overview_tiles,
    page,
    reported_page,
    rescore,
    score_meta,
    table_page,
    THEME_CSS,
    tile_row,
    tip,
    tradeoff_page,
    view,
    ZoneInfo,
):
    # The page: a header (title, when the results were scored, a hover help, the view and
    # rescore), the page tabs, then every page mounted, the inactive ones hidden by
    # visibility so a tab switch redraws nothing.
    _bullets = [
        ("WER", ("is words wrong per hundred reference words, lower is better. Short clips: the mean of "
                 "LibriSpeech clean, other and FLEURS Spanish (English-only models: the two English sets, drawn hollow).")),
        ("Your dictations", ("have no ground truth: the number there is disagreement with the local consensus, the medoid "
                             "of the local models' transcripts (mostly Parakeet variants). Wispr Flow is scored the same way.")),
        ("Wait", "is the median seconds from releasing the hotkey to the final text, one M4 Pro, one model at a time."),
        ("Disk", "is the weight files the engine reads, as published."),
        ("Reported", "numbers come from models.toml, each with its source and the date it was read."),
    ]
    _items = "".join(f"<li><b style='color:{INK}'>{html.escape(b)}</b> {html.escape(r)}</li>" for b, r in _bullets)
    _help = (
        "<style>.si-help{position:relative;display:inline-block;outline:none}"
        ".si-help .pop{display:none;position:absolute;left:0;top:140%;z-index:60;width:400px;max-width:80vw;"
        "background:var(--si-pop);border:1px solid var(--si-border);border-radius:8px;"
        "box-shadow:0 6px 18px rgba(0,0,0,0.18);padding:10px 14px;font-size:12px;font-weight:400;line-height:1.45}"
        ".si-help:hover .pop,.si-help:focus-within .pop{display:block}"
        ".si-help .pop ul{margin:0;padding-left:16px}.si-help .pop li{margin:3px 0}</style>"
        f'<span class="si-help" tabindex="0" style="font-size:12px;color:{INK_2};cursor:help">'
        f'ⓘ How to read this<div class="pop" style="color:{INK_2}"><ul>{_items}</ul></div></span>'
    )
    _at = datetime.fromtimestamp(score_meta["scored_at"], ZoneInfo(LONDON)).strftime("%d %b %H:%M")
    _src = f"results scored {_at}" + (" (from cache)" if score_meta["cached"] else f" in {score_meta['seconds']:.1f} s")
    if score_meta["incomplete"]:
        _short = "; ".join(f"{s}: {', '.join(f'{k} {d}/{t}' for k, (d, t) in v.items())}" for s, v in score_meta["incomplete"].items())
        _src += f' · <span{tip(bullets("Unfinished cells shrink every row of their set to the clips all finished", _short))} style="color:var(--si-warn);cursor:help">unfinished cells</span>'
    _header = mo.Html(
        '<div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap;border-bottom:1px solid var(--si-border);padding-bottom:6px">'
        f'<span style="font-size:20px;font-weight:600;color:{INK};white-space:nowrap">Speech-to-text model intake</span>'
        f'<span style="font-size:12px;color:{INK_2};white-space:nowrap">London time; {_src}</span>'
        f"{_help}{gaps_note}"
        f'<div style="margin-left:auto;display:flex;align-items:center;gap:16px;flex-wrap:wrap">{view}{rescore}</div>'
        "</div>"
    )
    _gap = f'<div style="height:{GUTTER}px"></div>'
    _overview = mo.Html(
        tile_row(overview_tiles)
        + _gap
        + board(
            "overview",
            overview_panels,
            wide=("minmax(0,1fr) minmax(0,1fr)", '"speed disk"'),
            mid=("minmax(0,1fr)", '"speed" "disk"'),
            narrow=("minmax(0,1fr)", '"speed" "disk"'),
        )
    )
    _pages = {
        "Overview": _overview, "Size × speed × accuracy": tradeoff_page, "Reported vs ours": reported_page,
        "Engines": engines_page, "Table": table_page,
    }
    _body = mo.Html(
        "<style>.si-pages{position:relative}"
        ".si-page.si-off{position:absolute;left:0;right:0;top:0;height:0;overflow:hidden;visibility:hidden;pointer-events:none}</style>"
        '<div class="si-pages">'
        + "".join(f'<div class="si-page{"" if name == page.value else " si-off"}">{body}</div>' for name, body in _pages.items())
        + "</div>"
    )
    mo.vstack([mo.Html(THEME_CSS), _header, page, _body], gap=0.6)
    return


@app.cell(hide_code=True)
def _():
    import hashlib
    import html
    import json
    import math
    import statistics
    import sys
    import textwrap
    import time
    import tomllib
    from datetime import datetime
    from pathlib import Path
    from zoneinfo import ZoneInfo

    import altair as alt
    import marimo as mo
    import polars as pl

    return (
        Path,
        ZoneInfo,
        alt,
        datetime,
        hashlib,
        html,
        json,
        math,
        mo,
        pl,
        statistics,
        sys,
        textwrap,
        time,
        tomllib,
    )


@app.cell(hide_code=True)
def _(mo, sys, tomllib):
    # The registry and the grid. grid.py is imported from the repo, so scores here are the
    # grid report's own numbers; it needs numpy, whisper-normalizer and rapidfuzz.
    HERE = mo.notebook_dir()
    REPO = HERE.parents[1]
    sys.path.insert(0, str(REPO / "utils" / "asr_grid"))
    import grid

    _reg = tomllib.loads((HERE / "models.toml").read_text())
    MODELS, SYSTEMS, SOURCES = _reg["models"], _reg["systems"], _reg["sources"]
    LONDON = "Europe/London"
    SHORT = ("ls-clean", "ls-other", "fleurs-es")
    VIEWS = {
        "Short clips, labelled (mean of 3 sets)": "short",
        "LibriSpeech clean": "ls-clean",
        "LibriSpeech other": "ls-other",
        "FLEURS Spanish": "fleurs-es",
        "LibriSpeech long (2 to 12 min)": "ls-long",
        "Your dictations (agreement, not truth)": "wispr",
    }
    ENGINES = {
        "parakeet-mlx": "parakeet-mlx",
        "mlx-audio": "mlx-audio",
        "mlx-whisper": "mlx-whisper",
        "coreml": "Core ML",
        "fermion": "Fermion",
        "cloud": "Cloud",
    }
    SHAPES = ["circle", "square", "diamond", "triangle-up", "cross", "triangle-down"]
    # v2t status: what it ships, what you can opt into, the rest. Palette blue, orange and a
    # neutral grey, never a red-green pair; the shape carries the engine.
    # A cloud reference (Wispr Flow) is aqua, the third slot of the same validated palette.
    STATUS = ["v2t default", "v2t opt-in", "not in v2t", "cloud reference"]
    STATUS_COLORS = ["#eb6834", "#2a78d6", "#898781", "#1baf7a"]


    def status_of(system):
        if SYSTEMS[system]["engine"] == "cloud":
            return STATUS[3]
        return {"default": STATUS[0], "opt-in": STATUS[1]}.get(SYSTEMS[system].get("v2t"), STATUS[2])
    return (
        ENGINES,
        LONDON,
        MODELS,
        SHAPES,
        SHORT,
        SOURCES,
        STATUS,
        STATUS_COLORS,
        SYSTEMS,
        VIEWS,
        grid,
        status_of,
    )


@app.cell(hide_code=True)
def _(html, mo, textwrap):
    # Page colours are CSS variables so cards and text follow marimo's light or dark theme.
    INK = "var(--si-ink)"
    INK_2 = "var(--si-ink-2)"
    THEME_CSS = (
        "<style>:root{--si-ink:#0b0b0b;--si-ink-2:#52514e;--si-track:#f0efec;--si-card:#fcfcfb;--si-pop:#fff;"
        "--si-border:rgba(11,11,11,0.10);--si-warn:#d03b3b}"
        "body.dark,body.dark-theme{--si-ink:var(--foreground);--si-ink-2:var(--muted-foreground);--si-track:#3b403e;"
        "--si-card:var(--card);--si-pop:var(--popover);--si-border:var(--border);--si-warn:#ff7b72}</style>"
    )
    # One grey for marks we colour ourselves, readable on light and dark cards.
    CHART_REF = "#82817c"
    GUTTER = 16
    CARD = (
        "border:1px solid var(--si-border);border-radius:8px;background:var(--si-card);"
        "padding:10px 12px 6px;min-width:0;box-sizing:border-box"
    )


    def tip(note):
        """A hover: a lead line, then "• " facts, each wrapped on its own."""
        if not note:
            return ""
        lines = [textwrap.fill(line, 64, subsequent_indent="  ") for line in note.split("\n")]
        return f' data-tooltip="{html.escape(chr(10).join(lines), quote=True)}"'


    def bullets(lead, *facts):
        return "\n".join([lead, *(f"• {f}" for f in facts if f)])


    def tile(value, label, caption="", note="", visual=""):
        """A compact stat tile, about 85 px: label, value, a small visual, one caption line."""
        visual = visual or '<div style="height:10px"></div>'
        return (
            f'<div{tip(note)} style="{CARD};padding:7px 10px;cursor:{"help" if note else "default"}">'
            f'<div style="font-size:11px;color:{INK_2};white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{html.escape(label)}</div>'
            f'<div style="font-size:20px;font-weight:700;color:{INK};line-height:1.25;white-space:nowrap">{html.escape(value)}</div>'
            f"{visual}"
            f'<div style="font-size:11px;color:{INK_2};white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{html.escape(caption)}</div></div>'
        )


    def share_bar(frac, color):
        frac = max(0.0, min(1.0, frac))
        return (
            f'<div style="height:6px;border-radius:3px;background:var(--si-track);margin:3px 0 2px;overflow:hidden">'
            f'<div style="width:{100 * frac:.1f}%;height:100%;background:{color}"></div></div>'
        )


    def tile_row(tiles):
        """Tiles filling whole rows: four go 4, 2 x 2 or 1 x 4 as the pane narrows."""
        n = len(tiles)
        basis = lambda cols: f"calc({100 / cols:.4f}% - {GUTTER * (cols - 1) / cols:.1f}px)"
        items = "".join(f'<div class="t" style="display:flex;min-width:0">{tl}</div>' for tl in tiles)
        return (
            f"<style>.si-tiles{n}{{container-type:inline-size}}"
            f".si-tiles{n}>.r{{display:flex;flex-wrap:wrap;gap:{GUTTER}px}}"
            f".si-tiles{n}>.r>.t{{flex:1 1 {basis(n)}}}.si-tiles{n}>.r>.t>div{{flex:1}}"
            f"@container (max-width:{190 * n}px){{.si-tiles{n}>.r>.t{{flex-basis:{basis(2)}}}}}"
            f"@container (max-width:420px){{.si-tiles{n}>.r>.t{{flex-basis:100%}}}}</style>"
            f'<div class="si-tiles{n}"><div class="r">{items}</div></div>'
        )


    def board(name, cells, wide, mid, narrow):
        """Cards on one CSS grid: (columns, areas) above 1,000 px, 640 to 1,000 px, and below."""
        def css(cols, areas):
            return f"grid-template-columns:{cols};grid-template-areas:{areas};"
        items = "".join(f'<div style="grid-area:{a};min-width:0;display:flex">{h}</div>' for a, h in cells.items())
        return (
            f"<style>.si-{name}{{container-type:inline-size}}"
            f".si-{name}>.g{{display:grid;gap:{GUTTER}px;{css(*wide)}}}"
            f"@container (max-width:1000px){{.si-{name}>.g{{{css(*mid)}}}}}"
            f"@container (max-width:640px){{.si-{name}>.g{{{css(*narrow)}}}}}</style>"
            f'<div class="si-{name}"><div class="g">{items}</div></div>'
        )


    def chart_ui(chart, height):
        """A chart filling its card: width from the card, no padding, no legend, no action menu."""
        return mo.ui.altair_chart(
            chart.properties(
                width="container", height=height, background="transparent",
                autosize={"type": "fit", "contains": "padding"},
                padding={"left": 0, "top": 4, "bottom": 0, "right": 0},
                usermeta={"embedOptions": {"actions": False}},
            ).configure_view(strokeWidth=0),
            chart_selection=False, legend_selection=False,
        )


    def panel(title, note, body, subtitle="", legend="", footer=""):
        """A card: title (caveats behind the i), an optional subtitle and legend row, the body."""
        sub = f'<div style="font-size:11px;color:{INK_2};line-height:1.3">{html.escape(subtitle)}</div>' if subtitle else ""
        return (
            f'<div style="{CARD};flex:1;display:flex;flex-direction:column">'
            f'<div style="font-size:13px;font-weight:600;color:{INK};line-height:1.3">{html.escape(title)} '
            f'<span{tip(note)} style="color:{INK_2};font-weight:400;cursor:help">ⓘ</span></div>'
            f'{sub}{legend}<div style="min-width:0;width:100%;margin-top:auto">{body}</div>{footer}</div>'
        )


    def legend_row(items):
        """One row of legend keys: (svg swatch, name)."""
        parts = "".join(
            f'<span style="display:inline-flex;align-items:center;gap:5px;white-space:nowrap">{sw}'
            f'<span style="color:{INK_2}">{html.escape(name)}</span></span>'
            for sw, name in items
        )
        return f'<div style="display:flex;flex-wrap:wrap;align-items:center;gap:4px 14px;font-size:11px;margin:3px 0 4px">{parts}</div>'


    def dot(color, hollow=False, shape="circle"):
        style = f"fill:{'none' if hollow else color};stroke:{color}"
        if shape == "square":
            mark = f'<rect x="2" y="2" width="8" height="8" style="{style}" stroke-width="1.6"/>'
        elif shape == "diamond":
            mark = f'<polygon points="6,1 11,6 6,11 1,6" style="{style}" stroke-width="1.6"/>'
        elif shape == "triangle-up":
            mark = f'<polygon points="6,1 11,11 1,11" style="{style}" stroke-width="1.6"/>'
        elif shape == "triangle-down":
            mark = f'<polygon points="1,1 11,1 6,11" style="{style}" stroke-width="1.6"/>'
        elif shape == "cross":
            mark = f'<path d="M4 1h4v3h3v4h-3v3h-4v-3h-3v-4h3z" style="{style}" stroke-width="1.2"/>'
        else:
            mark = f'<circle cx="6" cy="6" r="4.5" style="{style}" stroke-width="1.6"/>'
        return f'<svg width="12" height="12" style="flex:none">{mark}</svg>'


    def dash_line(color):
        return (
            f'<svg width="16" height="10" style="flex:none"><line x1="0" y1="5" x2="16" y2="5" style="stroke:{color}" '
            'stroke-width="1.5" stroke-dasharray="4 3"/></svg>'
        )


    return (
        CHART_REF,
        GUTTER,
        INK,
        INK_2,
        THEME_CSS,
        board,
        bullets,
        chart_ui,
        dash_line,
        dot,
        legend_row,
        panel,
        share_bar,
        tile,
        tile_row,
        tip,
    )


@app.cell(hide_code=True)
def _(VIEWS, mo):
    # Controls live in their own cell, so the cells that read them re-run when they change.
    view = mo.ui.dropdown(options=VIEWS, value="Short clips, labelled (mean of 3 sets)", label="Clips")
    rescore = mo.ui.button(label="re-read results", value=0, on_click=lambda v: (v or 0) + 1)
    # Tabs with empty panels as the page selector only; every page stays mounted (see the top cell).
    page = mo.ui.tabs({"Overview": "", "Size × speed × accuracy": "", "Reported vs ours": "", "Engines": "", "Table": ""})
    return page, rescore, view


@app.cell(hide_code=True)
def _(Path, grid, hashlib, json, pl, rescore, time):
    # Scores for every finished cell of every set, cached beside the grid's results. The cache
    # key is every results and manifest file's size and mtime plus grid.py's, so a new cell, a
    # rerun or a scoring change rescores; anything else reads the cache.
    _ = rescore.value  # the button re-checks the key
    _cache = grid.private_dir(grid.GRID / ".intake-cache")
    _files = (
        sorted(grid.RESULTS.glob("*/*.jsonl")) + sorted(grid.SETS.glob("*.jsonl"))
        + [p for p in (grid.WISPR / "results.jsonl",) if p.exists()] + [Path(grid.__file__)]
    )
    _key = hashlib.sha256(
        "\n".join(f"{p}:{p.stat().st_size}:{p.stat().st_mtime_ns}" for p in _files).encode()
    ).hexdigest()[:16]
    _meta_path, _data_path = _cache / "meta.json", _cache / "scores.parquet"
    SCORE_SCHEMA = {
        "set": pl.Utf8, "system": pl.Utf8, "base": pl.Utf8, "chunked": pl.Boolean, "mode": pl.Utf8,
        "n": pl.Int64, "wer": pl.Float64, "wait_p50": pl.Float64, "wait_p90": pl.Float64,
        "rtf": pl.Float64, "peak_gb": pl.Float64, "waits": pl.List(pl.Float64),
    }
    _old = json.loads(_meta_path.read_text()) if _meta_path.exists() else {}
    if _old.get("key") == _key and _data_path.exists():
        scores = pl.read_parquet(_data_path)
        score_meta = {**_old, "cached": True}
    else:
        _t0 = time.time()
        _rows, _incomplete = [], {}
        for _set in sorted(p.stem for p in grid.SETS.glob("*.jsonl")):
            if _set == "smoke":
                continue
            if _short := grid.incomplete_cells(_set):
                _incomplete[_set] = _short
            for _r in grid.score_set(_set) + (grid.score_wispr_flow() if _set == "wispr" else []):
                _rows.append({
                    "set": _set, "system": _r["system"], "base": _r["system"].removesuffix(grid.CHUNKED),
                    "chunked": _r["system"].endswith(grid.CHUNKED), "mode": _r["mode"], "n": _r["n"],
                    "wer": 100 * _r["wer"], "wait_p50": _r["wait_p50"], "wait_p90": _r["wait_p90"],
                    "rtf": _r["rtf"], "peak_gb": _r["peak_gb"], "waits": [float(w) for w in _r["waits"]],
                })
        scores = pl.DataFrame(_rows, schema=SCORE_SCHEMA)
        score_meta = {"key": _key, "scored_at": time.time(), "seconds": time.time() - _t0, "incomplete": _incomplete}
        _tmp = _cache / ".scores.parquet.tmp"
        scores.write_parquet(_tmp)
        _tmp.replace(_data_path)
        _tmp = _cache / ".meta.json.tmp"
        _tmp.write_text(json.dumps(score_meta))
        _tmp.replace(_meta_path)
        score_meta = {**score_meta, "cached": False}
    return score_meta, scores


@app.cell(hide_code=True)
def _(ENGINES, MODELS, SYSTEMS, bullets, grid, scores, tip):
    # Intake gaps: grid systems with no registry entry draw nowhere, registry systems that
    # never ran draw nowhere either; both are listed in the header so neither goes unnoticed.
    _ran = set(scores["base"].unique().to_list())
    _no_entry = sorted(_ran - set(SYSTEMS))
    _never_ran = sorted(set(SYSTEMS) - _ran)
    _bad = sorted(s for s, v in SYSTEMS.items() if v["model"] not in MODELS or v["engine"] not in ENGINES)
    _not_in_grid = sorted(set(SYSTEMS) - set(grid.SYSTEMS) - set(grid.WISPR_FLOW))
    _facts = []
    if _no_entry:
        _facts.append(f"ran in the grid, no models.toml entry (not drawn): {', '.join(_no_entry)}")
    if _never_ran:
        _facts.append(f"in models.toml, no finished grid cell: {', '.join(_never_ran)}")
    if _not_in_grid:
        _facts.append(f"in models.toml, not in grid.py's SYSTEMS: {', '.join(_not_in_grid)}")
    if _bad:
        _facts.append(f"unknown model or engine: {', '.join(_bad)}")
    gaps_note = (
        f'<span{tip(bullets("Registry and grid disagree", *_facts))} style="font-size:12px;color:var(--si-warn);cursor:help">'
        f"{len(_facts)} intake gap{'s' if len(_facts) != 1 else ''}</span>"
        if _facts else ""
    )
    return (gaps_note,)


@app.cell(hide_code=True)
def _(
    ENGINES,
    grid,
    MODELS,
    pl,
    scores,
    SHORT,
    statistics,
    STATUS,
    status_of,
    SYSTEMS,
    view,
):
    # The selected view as one row per system: WER, wait, disk and its registry facts. The
    # short-clip view pools the three labelled sets like plot_pareto.py: the mean of the sets'
    # WERs, the median wait over all their clips; an English-only model needs only the two
    # English sets and is flagged hollow, since its mean covers different clips.
    _key = view.value
    _known = scores.filter(pl.col("base").is_in(list(SYSTEMS)))
    if _key == "short":
        _rows = []
        for _sys in sorted(_known.filter(~pl.col("chunked"))["base"].unique().to_list()):
            _cells = _known.filter((pl.col("base") == _sys) & ~pl.col("chunked") & pl.col("set").is_in(SHORT))
            _en = _sys in grid.ENGLISH_ONLY
            if _cells.height < (2 if _en else 3):
                continue
            _peaks = [p for p in _cells["peak_gb"].to_list() if p is not None]
            _rows.append({
                "system": _sys, "base": _sys, "chunked": False,
                "wer": float(_cells["wer"].mean()),
                "wait_p50": statistics.median([w for ws in _cells["waits"].to_list() for w in ws]),
                "rtf": float(_cells["rtf"].mean()), "peak_gb": max(_peaks) if _peaks else None,
                "sets": _cells.height, "hollow": _en,
            })
        _frame = pl.DataFrame(_rows, schema={
            "system": pl.Utf8, "base": pl.Utf8, "chunked": pl.Boolean, "wer": pl.Float64, "wait_p50": pl.Float64,
            "rtf": pl.Float64, "peak_gb": pl.Float64, "sets": pl.Int64, "hollow": pl.Boolean,
        })
    else:
        _frame = (
            _known.filter(pl.col("set") == _key)
            .select("system", "base", "chunked", "wer", "wait_p50", "rtf", "peak_gb")
            .with_columns(pl.lit(1).cast(pl.Int64).alias("sets"), pl.lit(False).alias("hollow"))
        )


    def _label(system, chunked):
        s = SYSTEMS[system]
        m = MODELS[s["model"]]
        twins = [k for k, v in SYSTEMS.items() if v["model"] == s["model"]]
        out = m["label"]
        if len(twins) > 1:
            out += f" ({ENGINES[s['engine']]}, {s['precision']})"
        return out + (" in 30 s pieces" if chunked else "")


    def _short(system, chunked):
        # the chart label: the model's short name, plus what tells its twins apart
        s = SYSTEMS[system]
        twins = [v for v in SYSTEMS.values() if v["model"] == s["model"]]
        out = MODELS[s["model"]].get("short", MODELS[s["model"]]["label"])
        if len(twins) > 1:
            engines_differ = len({v["engine"] for v in twins}) > 1
            out += f" · {ENGINES[s['engine']] if engines_differ else s['precision']}"
        return out + (" · pieces" if chunked else "")




    _facts = [
        {
            "system": r["system"],
            "label": _label(r["base"], r["chunked"]),
            "short": _short(r["base"], r["chunked"]),
            "model": SYSTEMS[r["base"]]["model"],
            "model_label": MODELS[SYSTEMS[r["base"]]["model"]]["label"],
            "engine": ENGINES[SYSTEMS[r["base"]]["engine"]],
            "precision": SYSTEMS[r["base"]]["precision"],
            "disk_gb": SYSTEMS[r["base"]].get("disk_gb"),
            "params_b": MODELS[SYSTEMS[r["base"]]["model"]].get("params_b"),
            "licence": MODELS[SYSTEMS[r["base"]]["model"]]["licence"],
            "creator": MODELS[SYSTEMS[r["base"]]["model"]]["creator"],
            "status": status_of(r["base"]),
            "note": SYSTEMS[r["base"]].get("note", ""),
        }
        for r in _frame.iter_rows(named=True)
    ]
    _schema = {k: pl.Utf8 for k in ("system", "label", "short", "model", "model_label", "engine", "precision", "licence", "creator", "status", "note")}
    _schema.update({"disk_gb": pl.Float64, "params_b": pl.Float64})
    view_frame = _frame.join(pl.DataFrame(_facts, schema=_schema), on="system", how="left").sort("wer")
    return (view_frame,)


@app.cell(hide_code=True)
def _(pl):
    def pareto(frame, x):
        """The lower-left front on (x, wer) over the comparable (filled) points."""
        best, keep = float("inf"), []
        for r in frame.filter(~pl.col("hollow")).sort([x, "wer"]).iter_rows(named=True):
            if r["wer"] < best:
                keep.append(r["system"])
                best = r["wer"]
        return keep

    return (pareto,)


@app.cell(hide_code=True)
def _(
    alt,
    bullets,
    CHART_REF,
    chart_ui,
    dash_line,
    dot,
    ENGINES,
    html,
    INK,
    INK_2,
    legend_row,
    math,
    panel,
    pareto,
    pl,
    SHAPES,
    share_bar,
    STATUS,
    STATUS_COLORS,
    tile,
    view,
    view_frame,
    VIEWS,
):
    # Overview: four tiles and the two trade-offs, WER against the wait and against disk.
    # On long clips a system can run whole or in 30 s pieces; the charts keep its better run.
    _f = view_frame.sort("wer").unique("base", keep="first", maintain_order=True).with_row_index("rank", offset=1)
    _view_name = next(k for k, v in VIEWS.items() if v == view.value)
    _ylabel = "disagreement with the local consensus (%)" if view.value == "wispr" else "WER (%), lower is better"


    # Artificial Analysis-style trade-off charts: better is up and left, every point
    # labelled in its creator's colour, labels placed by a small greedy search so they
    # neither overlap each other nor the points, and the quadrant better than the median
    # on both axes shaded.
    _creators = sorted(set(_f["creator"].to_list()))
    _palette = ["#2a78d6", "#eb6834", "#1baf7a", "#8c5bd6", "#d6486e", "#c08a00", "#3aa6b9", "#6f6e69", "#a0522d"]
    _creator_color = {c: _palette[i % len(_palette)] for i, c in enumerate(_creators)}
    _H = 380  # plot height in px; widths assume ~560 px for label boxes


    def _place(us, vs, texts, order, w_px=520, h_px=_H - 50):
        """Greedy label placement in plot-unit space (0..1 both ways, v up).

        For each point, in `order`, try eight spots around it and keep the one that
        overlaps placed labels and all points least and stays inside the plot."""
        cw, lh = 6.2 / w_px, 14 / h_px  # one character's width, one line's height
        pr_u, pr_v = 7 / w_px, 7 / h_px  # a point's radius
        placed, out = [], [None] * len(us)
        cands = [(1, 0, "left"), (-1, 0, "right"), (0, 1, "center"), (0, -1, "center"),
                 (1, 1, "left"), (-1, 1, "right"), (1, -1, "left"), (-1, -1, "right")]

        def box(u, v, w, align):
            x0 = u if align == "left" else (u - w if align == "right" else u - w / 2)
            return (x0, v - lh / 2, x0 + w, v + lh / 2)

        def overlap(a, b):
            return max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))

        for i in order:
            w = cw * len(texts[i]) + 2 / w_px
            best = None
            for k, (du, dv, align) in enumerate(cands):
                for step in (1, 2, 3.2):
                    u = us[i] + du * (pr_u + 3 / w_px) * step
                    v = vs[i] + dv * (pr_v + lh / 2) * step
                    b = box(u, v, w, align)
                    cost = sum(overlap(b, pb) for pb in placed) * 50
                    cost += sum(overlap(b, (us[j] - pr_u, vs[j] - pr_v, us[j] + pr_u, vs[j] + pr_v)) for j in range(len(us))) * 30
                    cost += (max(0, -b[0]) + max(0, b[2] - 1) + max(0, -b[1]) + max(0, b[3] - 1)) * 10
                    cost += k * 1e-4 + (step - 1) * 2e-4
                    if best is None or cost < best[0]:
                        best = (cost, u, v, align, b)
            placed.append(best[4])
            out[i] = (best[1], best[2], best[3])
        return out


    def _scatter(x, title, fmt):
        # a cloud system has nothing on disk (and a clip without a wait has no wait): left out
        src = _f.filter(pl.col(x).is_not_null() & (pl.col(x) > 0)).sort("wer")
        front = pareto(src, x)
        # outliers stay on the chart at its edge, labelled with their value, so the
        # rest are not squeezed into a band (a looping model reads 29%)
        cap = max(sorted(src["wer"].to_list())[src.height // 2] * 2.5, 8.0)
        src = src.with_columns(
            pl.col("wer").clip(upper_bound=cap).alias("wer_plot"), (pl.col("wer") > cap).alias("off"),
        )
        xs, ys = src[x].to_list(), src["wer_plot"].to_list()
        lx_lo, lx_hi = math.log(min(xs)) - 0.25, math.log(max(xs)) + 0.25
        y_lo, y_hi = min(ys) - 0.08 * (max(ys) - min(ys) + 0.5), max(ys) + 0.08 * (max(ys) - min(ys) + 0.5)
        us = [(math.log(v) - lx_lo) / (lx_hi - lx_lo) for v in xs]
        vs = [(y_hi - v) / (y_hi - y_lo) for v in ys]  # reversed: lower WER is higher up
        shipped = [st != STATUS[2] and st != STATUS[3] for st in src["status"].to_list()]
        texts = [
            t + (" (v2t)" if sh else "") + (f" ▼ {w:.0f}%" if off else "")
            for t, sh, w, off in zip(src["short"].to_list(), shipped, src["wer"].to_list(), src["off"].to_list())
        ]
        order = sorted(range(len(xs)), key=lambda i: (not shipped[i], src["system"][i] not in front, ys[i]))
        spots = _place(us, vs, texts, order)
        frame = src.with_columns(
            pl.Series("text", texts),
            pl.Series("lab_x", [math.exp(lx_lo + u * (lx_hi - lx_lo)) for u, _, _ in spots]),
            pl.Series("lab_y", [y_hi - v * (y_hi - y_lo) for _, v, _ in spots]),
            pl.Series("align", [a for _, _, a in spots]),
            pl.Series("shipped", shipped),
            pl.col("system").is_in(front).alias("front"),
        )
        xdom, ydom = [math.exp(lx_lo), math.exp(lx_hi)], [y_hi, y_lo]
        enc = {
            "x": alt.X(f"{x}:Q", title=title, scale=alt.Scale(type="log", domain=xdom, nice=False),
                       axis=alt.Axis(grid=True, gridOpacity=0.35, labelFlush=True, format="~g", tickCount=6)),
            "y": alt.Y("wer_plot:Q", title=_ylabel + "  (better ↑)", scale=alt.Scale(domain=ydom, nice=False),
                       axis=alt.Axis(grid=True, gridOpacity=0.35)),
        }
        tooltip = [
            alt.Tooltip("label:N", title="system"), alt.Tooltip("creator:N"),
            alt.Tooltip("wer:Q", format=".2f", title="WER %"),
            alt.Tooltip("wait_p50:Q", format=".2f", title="wait p50 (s)"),
            alt.Tooltip("disk_gb:Q", format=".3f", title="disk (GB)"),
            alt.Tooltip("peak_gb:Q", format=".2f", title="peak memory (GB)"),
            alt.Tooltip("engine:N"), alt.Tooltip("precision:N"), alt.Tooltip("status:N", title="v2t"),
            alt.Tooltip("params_b:Q", format=".2g", title="params (B)"), alt.Tooltip("licence:N"),
            alt.Tooltip("note:N"),
        ]
        color = alt.Color("creator:N", scale=alt.Scale(domain=_creators, range=[_creator_color[c] for c in _creators]), legend=None)
        mx, my = sorted(xs)[len(xs) // 2], sorted(ys)[len(ys) // 2]
        quad = pl.DataFrame({"x0": [xdom[0]], "x1": [mx], "y0": [my], "y1": [y_lo]})
        base = alt.Chart(frame)
        layers = [
            alt.Chart(quad).mark_rect(color="#1baf7a", opacity=0.07).encode(
                x=alt.X("x0:Q", scale=alt.Scale(type="log", domain=xdom, nice=False)), x2="x1:Q",
                y=alt.Y("y0:Q", scale=alt.Scale(domain=ydom, nice=False)), y2="y1:Q"),
            alt.Chart(quad).mark_text(align="left", baseline="top", dx=6, dy=6, fontSize=11, color="#1baf7a", fontWeight=600)
            .encode(x="x0:Q", y="y1:Q", text=alt.value("Most attractive quadrant")),
            alt.Chart(pl.DataFrame({"m": [mx]})).mark_rule(color=CHART_REF, strokeDash=[2, 3], opacity=0.6).encode(x="m:Q"),
            alt.Chart(pl.DataFrame({"m": [my]})).mark_rule(color=CHART_REF, strokeDash=[2, 3], opacity=0.6).encode(y="m:Q"),
            alt.Chart(frame.filter(pl.col("front")).sort(x)).mark_line(color=CHART_REF, strokeWidth=1.2, opacity=0.6).encode(**enc),
            base.mark_rule(color=CHART_REF, strokeWidth=0.6, opacity=0.5).encode(**enc, x2="lab_x:Q", y2="lab_y:Q"),
            base.transform_filter("datum.shipped").mark_point(size=300, filled=False, color="#0b0b0b", strokeWidth=1.4).encode(**enc),
            base.transform_filter("!datum.hollow").mark_circle(size=95, opacity=1, stroke="white", strokeWidth=1)
            .encode(**enc, color=color, tooltip=tooltip),
            base.transform_filter("datum.hollow").mark_point(filled=False, size=95, strokeWidth=2)
            .encode(**enc, color=color, tooltip=tooltip),
            *[
                base.transform_filter(f"datum.align == '{a}' && {'' if bold else '!'}(datum.shipped || datum.front)")
                .mark_text(align=a, baseline="middle", fontSize=11, fontWeight=700 if bold else 500)
                .encode(x="lab_x:Q", y="lab_y:Q", text="text:N", color=color)
                for a in ("left", "right", "center") for bold in (True, False)
            ],
        ]
        return chart_ui(alt.layer(*layers), _H), ""


    _legend = legend_row(
        [(dot(_creator_color[c]), c) for c in _creators]
        + [(dot("#0b0b0b", hollow=True), "ringed: v2t ships it")]
        + [(dash_line(CHART_REF), "median; solid grey line: best trade-off")]
        + ([(dot(CHART_REF, hollow=True), "hollow: English only, 2 sets")] if view.value == "short" else [])
    )
    _speed = _scatter("wait_p50", "wait after release, median (s, log)", lambda v: f"{v:.2f} s")
    _disk = _scatter("disk_gb", "weights on disk (GB, log)", lambda v: f"{v:.2g} GB")
    overview_panels = {
        "speed": panel(
            "Accuracy vs speed", "Wait: the median seconds from releasing the hotkey to the final text, one M4 Pro, "
            "one model on the GPU at a time. Better is up and left; the shaded box beats the median on both axes.",
            _speed[0], footer=_speed[1], subtitle=_view_name, legend=_legend,
        ),
        "disk": panel(
            "Accuracy vs size on disk", "Disk: the weight files the engine reads, as published (models.toml). "
            "Peak memory, where measured (cells from 14 Oct), is in the hover.",
            _disk[0], footer=_disk[1], subtitle=_view_name, legend=_legend,
        ),
    }

    _default = _f.filter(pl.col("status") == STATUS[0]).sort("wer")
    _comparable = _f.filter(~pl.col("hollow"))
    _best = _comparable.sort("wer").row(0, named=True) if _comparable.height else None
    _fast = _f.sort("wait_p50").row(0, named=True) if _f.height else None
    _models = _f["model"].n_unique() if _f.height else 0
    if _default.height:
        _d = _default.row(0, named=True)
        _rank = _f.sort("wer")["system"].to_list().index(_d["system"]) + 1
        _dtile = tile(
            f"{_d['wer']:.2f}% · {_d['wait_p50']:.2f} s", "v2t default", f"#{_rank} of {_f.height} on WER",
            note=_d["label"], visual=share_bar(1 - (_rank - 1) / max(_f.height - 1, 1), STATUS_COLORS[0]),
        )
    else:
        _dtile = tile("–", "v2t default", "not run on these clips")
    overview_tiles = [
        tile(f"{_models} models · {_f.height} runs", "drawn in this view", "a run: one model, one engine, one precision",
             note=bullets("A model is one set of weights; a run is that model on one engine at one precision",
                          "Parakeet v3, for instance, runs three ways: parakeet-mlx, mlx-audio and Core ML")),
        _dtile,
        tile(f"{_best['wer']:.2f}%", "lowest WER", _best["label"],
             note=bullets(_best["label"], "English-only models (hollow) are left out: their mean covers fewer sets") if view.value == "short" else _best["label"]) if _best else tile("–", "lowest WER"),
        tile(f"{_fast['wait_p50']:.2f} s", "shortest wait", _fast["label"], note=_fast["label"]) if _fast else tile("–", "shortest wait"),
    ]
    return overview_panels, overview_tiles


@app.cell(hide_code=True)
def _(
    alt,
    board,
    CHART_REF,
    chart_ui,
    dot,
    ENGINES,
    html,
    INK,
    INK_2,
    legend_row,
    MODELS,
    panel,
    pl,
    scores,
    SOURCES,
    STATUS,
    STATUS_COLORS,
    status_of,
    SYSTEMS,
    tip,
):
    # Reported vs ours on the datasets both cover: LibriSpeech clean and other (the leaderboard's
    # full test sets against our 150-clip samples) and FLEURS Spanish. Each system is drawn
    # against its model's reported number, so an engine or precision that costs accuracy shows
    # as a gap even where the model itself is fine.
    _sets = {"ls-clean": "LibriSpeech clean", "ls-other": "LibriSpeech other", "fleurs-es": "FLEURS Spanish"}


    def _rep(model, metric):
        hit = [r for r in MODELS[model].get("reported", []) if r["metric"] == metric]
        return hit[0] if hit else None


    _cells = {}
    for _set, _name in _sets.items():
        _rows = []
        for _r in scores.filter((pl.col("set") == _set) & ~pl.col("chunked")).iter_rows(named=True):
            if _r["base"] not in SYSTEMS:
                continue
            _s = SYSTEMS[_r["base"]]
            _rp = _rep(_s["model"], _set)
            if _rp is None:
                continue
            _twins = sum(1 for v in SYSTEMS.values() if v["model"] == _s["model"]) > 1
            _label = MODELS[_s["model"]]["label"] + (f" · {ENGINES[_s['engine']]} {_s['precision']}" if _twins else "")
            _rows.append({
                "label": _label, "ours": _r["wer"], "reported": _rp["value"], "gap": _r["wer"] - _rp["value"],
                "status": status_of(_r["base"]), "source": SOURCES[_rp["source"]]["name"],
            })
        _frame = pl.DataFrame(_rows, schema={
            "label": pl.Utf8, "ours": pl.Float64, "reported": pl.Float64, "gap": pl.Float64, "status": pl.Utf8, "source": pl.Utf8,
        }).sort("ours")
        _order = _frame["label"].to_list()
        _y = alt.Y("label:N", sort=_order, title=None, axis=alt.Axis(labelLimit=260, labelFontSize=11))
        _tt = [alt.Tooltip("label:N", title="system"), alt.Tooltip("ours:Q", format=".2f", title="ours %"),
               alt.Tooltip("reported:Q", format=".2f", title="reported %"), alt.Tooltip("gap:Q", format="+.2f", title="ours minus reported"),
               alt.Tooltip("source:N")]
        _x = alt.X("ours:Q", title="WER (%)", axis=alt.Axis(grid=False, labelFlush=True), scale=alt.Scale(zero=True, nice=True))
        _base = alt.Chart(_frame)
        _chart = alt.layer(
            _base.mark_rule(color=CHART_REF, strokeWidth=1.5).encode(x=_x, x2="reported:Q", y=_y, tooltip=_tt),
            _base.mark_point(filled=False, size=80, strokeWidth=1.8, color=CHART_REF).encode(x="reported:Q", y=_y, tooltip=_tt),
            _base.mark_point(filled=True, size=90, opacity=0.95).encode(
                x=_x, y=_y, tooltip=_tt,
                color=alt.Color("status:N", scale=alt.Scale(domain=STATUS, range=STATUS_COLORS), legend=None)),
        )
        _median_gap = _frame["gap"].median() if _frame.height else None
        _sub = (f"{_frame.height} systems; median gap {_median_gap:+.2f} points (ours minus reported)"
                if _frame.height else "no system with a reported number")
        _cells[_set] = panel(
            _name, "Ours: 150 seeded clips, MLX or Core ML on an M4 Pro, scored by grid.score_set. Reported: the full "
            "test set, the model's reference implementation on a GPU (Open ASR Leaderboard). Same normalisation (Whisper's).",
            chart_ui(_chart, max(110, 22 * _frame.height)), subtitle=_sub,
        )

    # The headline reported numbers per model, beside our short-clip mean for its best system.
    _short = (
        scores.filter(pl.col("set").is_in(list(_sets)) & ~pl.col("chunked") & pl.col("base").is_in(list(SYSTEMS)))
        .group_by("base").agg(pl.col("wer").mean().alias("wer"), pl.len().alias("n"))
    )
    _best_ours = {}
    for _r in _short.iter_rows(named=True):
        _m = SYSTEMS[_r["base"]]["model"]
        if _m not in _best_ours or _r["wer"] < _best_ours[_m][0]:
            _best_ours[_m] = (_r["wer"], _r["n"], _r["base"])


    def _cell(model, metric):
        rp = _rep(model, metric)
        if rp is None:
            return f'<td style="color:{INK_2};text-align:right">–</td>'
        src = SOURCES[rp["source"]]
        note = f"{src['name']}, read {src['read']}" + (f"; {rp['note']}" if rp.get("note") else "")
        return f'<td{tip(note)} style="text-align:right;cursor:help"><a href="{html.escape(src["url"])}" target="_blank" style="color:{INK}">{rp["value"]:.2f}</a></td>'


    _hdr = "".join(f'<th style="text-align:{a};padding:3px 8px;color:{INK_2};font-weight:500">{h}</th>' for h, a in (
        ("model", "left"), ("by", "left"), ("params", "right"), ("licence", "left"), ("languages", "right"),
        ("Open ASR avg", "right"), ("AA-WER", "right"), ("ours, short clips", "right")))
    _body = ""
    for _id, _m in sorted(MODELS.items(), key=lambda kv: _best_ours.get(kv[0], (99,))[0]):
        _o = _best_ours.get(_id)
        _params = f"{_m['params_b']:g}B" if "params_b" in _m else "–"
        _en = " (EN, 2 sets)" if _o and _o[1] < 3 else ""
        _ours = (f'<td{tip(f"best system: {_o[2]}; mean of {_o[1]} sets")} style="text-align:right;cursor:help">{_o[0]:.2f}{_en}</td>'
                 if _o else f'<td style="color:{INK_2};text-align:right">not run</td>')
        _body += (
            "<tr style='border-top:1px solid var(--si-border)'>"
            f'<td style="padding:3px 8px"><a href="{html.escape(_m["card"])}" target="_blank" style="color:{INK}">{html.escape(_m["label"])}</a></td>'
            f'<td style="padding:3px 8px;color:{INK_2}">{html.escape(_m["creator"])}</td>'
            f'<td style="text-align:right;padding:3px 8px">{_params}</td>'
            f'<td style="padding:3px 8px;color:{INK_2}">{html.escape(_m["licence"])}</td>'
            f'<td style="text-align:right;padding:3px 8px">{_m.get("languages", "–")}</td>'
            + _cell(_id, "oasr-avg") + _cell(_id, "aa-wer") + _ours + "</tr>"
        )
    _table = (
        f'<table style="border-collapse:collapse;width:100%;font-size:12px;color:{INK}">'
        f"<thead><tr>{_hdr}</tr></thead><tbody>{_body}</tbody></table>"
    )
    _legend = legend_row([(dot(CHART_REF, hollow=True), "reported")] + [(dot(c), f"ours, {s}") for s, c in zip(STATUS, STATUS_COLORS)])
    reported_page = (
        _legend
        + board(
            "reported",
            {**_cells, "table": panel(
                "What each model's publishers and leaderboards report", "Each number links to its source; hover for the "
                "date read. Open ASR avg covers 9 English datasets; AA-WER is Artificial Analysis's index over "
                "agent talk, VoxPopuli and Earnings22, often through a hosted API. Neither is on our clips, so "
                "compare them across models, not with our column.", _table)},
            wide=("repeat(3,minmax(0,1fr))", '"ls-clean ls-other fleurs-es" "table table table"'),
            mid=("minmax(0,1fr) minmax(0,1fr)", '"ls-clean ls-other" "fleurs-es fleurs-es" "table table"'),
            narrow=("minmax(0,1fr)", '"ls-clean" "ls-other" "fleurs-es" "table"'),
        )
    )
    return (reported_page,)


@app.cell(hide_code=True)
def _(
    ENGINES,
    INK,
    INK_2,
    MODELS,
    STATUS,
    STATUS_COLORS,
    SYSTEMS,
    VIEWS,
    html,
    panel,
    pl,
    tip,
    view,
    view_frame,
):
    # Engines: which engine runs which model, and how it did in this view. One colour scale
    # for the whole grid: the tint depends only on the WER printed in the cell.
    _f = view_frame.filter(~pl.col("chunked")) if view.value not in ("ls-long", "wispr") else view_frame
    _wers = _f["wer"].to_list()
    _lo, _hi = (min(_wers), max(_wers)) if _wers else (0, 1)


    def _tint(w):
        # light to dark blue over this view's range: more ink, more error
        t = 0 if _hi == _lo else (w - _lo) / (_hi - _lo)
        return f"rgba(42,120,214,{0.08 + 0.42 * t:.2f})"


    _hdr = "".join(f'<th style="padding:4px 8px;color:{INK_2};font-weight:500;text-align:left">{h}</th>' for h in ["model", "params", "licence"])
    _hdr += "".join(f'<th style="padding:4px 8px;color:{INK_2};font-weight:500;text-align:left">{html.escape(e)}</th>' for e in ENGINES.values())
    _rows = ""
    for _id, _m in MODELS.items():
        _params = f"{_m['params_b']:g}B" if "params_b" in _m else "–"
        _cells = ""
        for _eng in ENGINES:
            _systems = [s for s, v in SYSTEMS.items() if v["model"] == _id and v["engine"] == _eng]
            if not _systems:
                _cells += f'<td style="padding:4px 8px;color:{INK_2}">–</td>'
                continue
            _parts = []
            for _s in _systems:
                _hit = _f.filter(pl.col("base") == _s).sort("wer")
                _v2t = SYSTEMS[_s].get("v2t")
                _badge = (f' <span style="font-size:10px;color:#fff;background:{STATUS_COLORS[STATUS.index("v2t " + _v2t)]};'
                          f'border-radius:3px;padding:0 4px">v2t {_v2t}</span>') if _v2t else ""
                if _hit.height:
                    _r = _hit.row(0, named=True)
                    _disk = SYSTEMS[_s].get("disk_gb")
                    _note = (f"{_s}\n• WER {_r['wer']:.2f}%\n• wait p50 {_r['wait_p50']:.2f} s"
                             + (f"\n• disk {_disk:.3f} GB" if _disk else "\n• cloud: nothing on disk"))
                    _parts.append(
                        f'<div{tip(_note)} style="background:{_tint(_r["wer"])};border-radius:4px;padding:2px 6px;margin:1px 0;cursor:help">'
                        f'<b>{_r["wer"]:.2f}%</b> · {_r["wait_p50"]:.2f} s <span style="color:{INK_2}">{html.escape(SYSTEMS[_s]["precision"])}</span>{_badge}</div>'
                    )
                else:
                    _parts.append(f'<div style="color:{INK_2};padding:2px 6px">{html.escape(SYSTEMS[_s]["precision"])}: not on these clips{_badge}</div>')
            _cells += f'<td style="padding:3px 6px">{"".join(_parts)}</td>'
        _rows += (
            "<tr style='border-top:1px solid var(--si-border)'>"
            f'<td style="padding:4px 8px;white-space:nowrap"><a href="{html.escape(_m["card"])}" target="_blank" style="color:{INK}">{html.escape(_m["label"])}</a></td>'
            f'<td style="padding:4px 8px">{_params}</td><td style="padding:4px 8px;color:{INK_2}">{html.escape(_m["licence"])}</td>'
            f"{_cells}</tr>"
        )
    _view_name = next(k for k, v in VIEWS.items() if v == view.value)
    engines_page = panel(
        "Which engine runs which model", "Each cell: WER and median wait for that model on that engine in the "
        "selected view, tinted on one scale (darker, more error). A dash: we have no system for that pair. "
        "Engines are the runtimes the grid ran; v2t ships parakeet-mlx and, opt-in, Core ML and mlx-whisper.",
        f'<div style="overflow-x:auto"><table style="border-collapse:collapse;width:100%;font-size:12px;color:{INK}">'
        f"<thead><tr>{_hdr}</tr></thead><tbody>{_rows}</tbody></table></div>",
        subtitle=_view_name,
    )
    return (engines_page,)


@app.cell(hide_code=True)
def _(
    CHART_REF,
    INK,
    INK_2,
    STATUS,
    STATUS_COLORS,
    VIEWS,
    alt,
    chart_ui,
    dot,
    html,
    legend_row,
    math,
    panel,
    pl,
    tip,
    view,
    view_frame,
):
    # Size, speed and accuracy at once, as parallel axes (Luis's pick, 23 Oct). Only runs with
    # all three numbers are drawn: a cloud reference has no size and is left out.
    _view_name = next(k for k, v in VIEWS.items() if v == view.value)
    _f = view_frame.filter(pl.col("wait_p50").is_not_null()).sort("wer").with_row_index("rank", offset=1)
    _sized = _f.filter(pl.col("disk_gb").is_not_null())
    _color = alt.Color("status:N", scale=alt.Scale(domain=STATUS, range=STATUS_COLORS), legend=None)
    _tt = [
        alt.Tooltip("label:N", title="system"), alt.Tooltip("wer:Q", format=".2f", title="WER %"),
        alt.Tooltip("wait_p50:Q", format=".2f", title="wait p50 (s)"), alt.Tooltip("disk_gb:Q", format=".3f", title="disk (GB)"),
        alt.Tooltip("engine:N"), alt.Tooltip("precision:N"), alt.Tooltip("status:N", title="v2t"),
    ]
    _shown = set(_sized["status"].to_list())
    _status_legend = [(dot(c), s) for s, c in zip(STATUS, STATUS_COLORS) if s in _shown]


    def _key(frame):
        parts = []
        for r in frame.iter_rows(named=True):
            size = "cloud" if r["disk_gb"] is None else f"{r['disk_gb']:.2g} GB"
            parts.append(
                f'<span style="white-space:nowrap"><span style="color:{STATUS_COLORS[STATUS.index(r["status"])]};font-weight:600">'
                f'{r["rank"]}</span> {html.escape(r["short"])} '
                f'<span style="color:{INK_2}">{r["wer"]:.2f}% · {r["wait_p50"]:.2f} s · {size}</span></span>'
            )
        return f'<div style="display:flex;flex-wrap:wrap;gap:2px 12px;font-size:11px;margin-top:4px">{"".join(parts)}</div>'


    # Every axis points the same way: values grow upwards, so the best (least) sits at the bottom
    # and a line that stays low is good on all three. Disk and wait on log scales, WER linear.
    _axes = [("disk_gb", "size on disk", True, "GB"), ("wait_p50", "wait", True, "s"), ("wer", "WER", False, "%")]
    _rows, _ticks = [], []
    for _i, (_col, _name, _log, _unit) in enumerate(_axes):
        _vals = _sized[_col].to_list()
        _t = (lambda v: math.log(v)) if _log else (lambda v: v)
        _lo, _hi = min(_t(v) for v in _vals), max(_t(v) for v in _vals)
        for _r in _sized.iter_rows(named=True):
            _rows.append({**{k: _r[k] for k in ("system", "label", "short", "status", "wer", "wait_p50", "disk_gb", "engine", "precision", "rank")},
                          "axis": _i, "axis_name": _name, "y": (_t(_r[_col]) - _lo) / ((_hi - _lo) or 1)})
        for _v, _yy in ((min(_vals), 0.0), (max(_vals), 1.0)):
            _ticks.append({"axis": _i, "y": _yy, "text": f"{_v:.2g} {_unit}", "align": "right"})
        _ticks.append({"axis": _i, "y": 1.08, "text": f"{_name} · lower is better ↓", "align": "center"})
    _long = pl.DataFrame(_rows)
    _x = alt.X("axis:Q", axis=None, scale=alt.Scale(domain=[-0.15, 2.15]))
    _y = alt.Y("y:Q", axis=None, scale=alt.Scale(domain=[-0.05, 1.12]))
    _chart = alt.layer(
        alt.Chart(pl.DataFrame({"axis": [0, 1, 2], "y0": [0.0] * 3, "y1": [1.0] * 3}))
        .mark_rule(color=CHART_REF, strokeWidth=1).encode(x=_x, y=alt.Y("y0:Q", axis=None, scale=alt.Scale(domain=[-0.05, 1.12])), y2="y1:Q"),
        alt.Chart(_long.filter(pl.col("status") != STATUS[0])).mark_line(strokeWidth=1.6, opacity=0.75).encode(
            x=_x, y=_y, detail="system:N", color=_color, tooltip=_tt),
        alt.Chart(_long.filter(pl.col("status") == STATUS[0])).mark_line(strokeWidth=4, opacity=0.9).encode(
            x=_x, y=_y, detail="system:N", color=_color, tooltip=_tt),
        alt.Chart(_long).mark_point(filled=True, size=40).encode(x=_x, y=_y, color=_color, tooltip=_tt),
        alt.Chart(_long.filter(pl.col("axis") == 2)).mark_text(align="left", dx=8, fontSize=10, fontWeight=600, color=CHART_REF)
        .encode(x=_x, y=_y, text="rank:Q"),
        *[
            alt.Chart(pl.DataFrame(_ticks).filter(pl.col("align") == a))
            .mark_text(align=a, dx=-10 if a == "right" else 0, fontSize=11, color=CHART_REF)
            .encode(x=_x, y=_y, text="text:N")
            for a in ("right", "center")
        ],
    )
    _body = chart_ui(_chart, 420)
    _legend = legend_row(_status_legend)
    _title, _note = "One line per run: size, wait and WER, best at the bottom of every axis", (
        "Each axis grows upwards over its own range (size and wait on log scales), so the lowest point is the "
        "best and a line that stays low is good on all three. Cloud references have no size and are left out.")
    tradeoff_page = panel(_title, _note, _body, subtitle=_view_name, legend=_legend, footer=_key(_sized))
    return (tradeoff_page,)


@app.cell(hide_code=True)
def _(MODELS, SYSTEMS, VIEWS, mo, pl, scores):
    # Table: every system on every set, the numbers behind the charts.
    _names = {v: k for k, v in VIEWS.items()}
    _wide = (
        scores.filter(pl.col("base").is_in(list(SYSTEMS)))
        .with_columns(pl.col("wer").round(2), pl.col("wait_p50").round(2))
        .pivot(on="set", index="system", values=["wer", "wait_p50"])
    )
    _facts = pl.DataFrame(
        [
            {
                "system": s, "model": MODELS[v["model"]]["label"], "engine": v["engine"], "precision": v["precision"],
                "disk GB": v.get("disk_gb"), "v2t": v.get("v2t", ""),
            }
            for s, v in SYSTEMS.items()
        ],
        schema={"system": pl.Utf8, "model": pl.Utf8, "engine": pl.Utf8, "precision": pl.Utf8, "disk GB": pl.Float64, "v2t": pl.Utf8},
    )
    _wide = _wide.with_columns(pl.col("system").str.replace(r"\+chunked$", "").alias("_base"))
    _table = _facts.rename({"system": "_base"}).join(_wide, on="_base", how="right").drop("_base")
    _order = ["ls-clean", "ls-other", "fleurs-es", "ls-long", "wispr"]
    _cols = [f"{m}_{s}" for s in _order for m in ("wer", "wait_p50") if f"{m}_{s}" in _table.columns]
    _table = _table.select(["system", "model", "engine", "precision", "disk GB", "v2t", *_cols]).rename(
        {c: f"{'WER %' if c.startswith('wer') else 'wait s'} · {_names.get(c.split('_', 2)[-1], c)}" for c in _cols}
    )
    table_page = mo.ui.table(_table, page_size=30, selection=None, show_column_summaries=False)
    return (table_page,)


if __name__ == "__main__":
    app.run()
