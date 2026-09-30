"""Render the ASR grid as one self-contained HTML page (numbers only, no transcript text).

    python report_html.py --headline "..." --sub "..."    # -> ~/.v2t/eval/grid/<date>-grid-report.html

Two scatters (your dictations; the labelled sets pooled): error against the wait after
release, one dot per system, colour and shape by pipeline. A table carries every number.
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).parent))
import grid  # noqa: E402

LABELLED = ["ls-clean", "ls-other", "fleurs-es"]
NAMES = {
    "parakeet-v3": "Parakeet v3 (today)",
    "parakeet-ultra": "Parakeet Ultra",
    "whisper-turbo": "Whisper turbo",
    "nemotron-3.5-stream": "Nemotron 3.5 streaming",
    "voxtral-rt-4bit": "Voxtral Realtime 4B",
    "qwen3-asr-1.7b": "Qwen3-ASR 1.7B",
    "qwen3-asr-1.7b-8bit": "Qwen3-ASR 1.7B 8-bit",
    "parakeet-v3-mlxaudio": "Parakeet v3 via mlx-audio",
    "whisper-turbo-mlxaudio": "Whisper turbo via mlx-audio",
}
PIPELINES = {
    "hacky": "v2t's rule: whole-file under 60 s, streamed above",
    "stream": "natively streaming",
    "offline": "whole-file after release",
}


def collect() -> dict:
    sets = {
        name: {r["system"]: r for r in grid.score_set(name)}
        for name in LABELLED + ["wispr"]
    }
    systems = sorted(set().union(*[set(rows) for rows in sets.values()]))
    out = []
    for system in systems:
        per_set = {name: sets[name].get(system) for name in sets}
        labelled = [per_set[name] for name in LABELLED if per_set[name]]
        waits = [w for r in labelled for w in r["waits"]]
        pooled = (
            {
                "wer": sum(r["errors"] for r in labelled)
                / sum(r["words"] for r in labelled),
                "p50": grid.q(waits, 0.5),
                "p90": grid.q(waits, 0.9),
                "n": sum(r["n"] for r in labelled),
            }
            if len(labelled) == len(LABELLED)
            else None
        )
        wispr = per_set["wispr"]
        out.append(
            {
                "id": system,
                "name": NAMES.get(system, system),
                "mode": grid.SYSTEMS[system][2],
                "sets": {
                    name: None if not r else {"wer": r["wer"], "n": r["n"]}
                    for name, r in per_set.items()
                },
                "labelled": pooled,
                "wispr": None
                if not wispr
                else {
                    "wer": wispr["wer"],
                    "p50": wispr["wait_p50"],
                    "p90": wispr["wait_p90"],
                    "max": wispr["wait_max"],
                    "rtf": wispr["rtf"],
                    "n": wispr["n"],
                },
            }
        )
    return {"systems": out, "pipelines": PIPELINES}


PAGE = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>ASR grid for v2t · __DATE__</title>
<script>try{document.documentElement.dataset.theme=localStorage.getItem('html-theme')||'system'}catch{document.documentElement.dataset.theme='system'}</script>
<style>
:root{color-scheme:light dark;--font:system-ui,-apple-system,'Segoe UI',sans-serif;--mono:ui-monospace,Menlo,monospace;
--bg:#fcfcfb;--fg:#0b0b0b;--fg2:#52514e;--fg3:#8a8984;--surface:#f4f4f2;--border:#e4e3df;--grid:#ecebe7;
--s-hacky:#2a78d6;--s-stream:#eb6834;--s-offline:#1baf7a}
:root[data-theme="dark"]{--bg:#1a1a19;--fg:#ffffff;--fg2:#c3c2b7;--fg3:#8f8e86;--surface:#232322;--border:#34332f;--grid:#2a2a28;
--s-hacky:#3987e5;--s-stream:#d95926;--s-offline:#199e70}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){--bg:#1a1a19;--fg:#ffffff;--fg2:#c3c2b7;--fg3:#8f8e86;
--surface:#232322;--border:#34332f;--grid:#2a2a28;--s-hacky:#3987e5;--s-stream:#d95926;--s-offline:#199e70}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--font);line-height:1.5}
main{max-width:1120px;margin:0 auto;padding:28px 24px 80px}
.top{display:flex;align-items:center;gap:12px}.kicker{font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:var(--fg3);font-weight:600}
.theme{margin-left:auto;font:12px var(--font);border:1px solid var(--border);background:var(--surface);color:var(--fg);border-radius:999px;padding:6px 11px;cursor:pointer}
h1{font-size:30px;font-weight:600;letter-spacing:-.02em;margin:8px 0 4px;max-width:30ch}
.sub{color:var(--fg2);font-size:17px;margin:0 0 22px;max-width:72ch}
.charts{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:18px}@media(max-width:860px){.charts{grid-template-columns:minmax(0,1fr)}}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px}
.card h2{font-size:15px;font-weight:600;margin:0}.card .note{font-size:12.5px;color:var(--fg2);margin:2px 0 6px}
svg text{font-family:var(--font)}.legend{display:flex;gap:16px;flex-wrap:wrap;font-size:12.5px;color:var(--fg2);margin:12px 0 4px}
.legend span{display:inline-flex;align-items:center;gap:6px}
table{border-collapse:collapse;width:100%;font-size:13.5px;margin-top:18px}th,td{padding:7px 9px;border-bottom:1px solid var(--border);text-align:right;white-space:nowrap}
th{font-weight:600;color:var(--fg2);font-size:12px}td:first-child,th:first-child,td:nth-child(2),th:nth-child(2){text-align:left}
td.best{font-weight:700}.tip{position:fixed;pointer-events:none;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:8px 10px;font-size:12.5px;
box-shadow:0 6px 24px rgba(0,0,0,.18);opacity:0;transition:opacity 80ms;max-width:280px}.tip b{display:block;margin-bottom:2px}
details{margin-top:22px;color:var(--fg2);font-size:14px}summary{cursor:pointer;color:var(--fg)}details li{margin:4px 0}
footer{margin-top:40px;font-size:12px;color:var(--fg3);border-top:1px solid var(--border);padding-top:12px}
</style></head><body><main>
<div class="top"><span class="kicker">voice2text · speech-to-text grid · __DATE__</span><button class="theme" id="theme">Theme: System</button></div>
<h1>__HEADLINE__</h1><p class="sub">__SUB__</p>
<div class="charts">
 <div class="card"><h2>Your 208 dictations</h2><p class="note">Disagreement with the other systems' consensus (not truth) · wait p50, whisker to p90</p><svg id="c-wispr" role="img" aria-label="Scatter: disagreement against wait on your dictations"></svg></div>
 <div class="card"><h2>Labelled clips: LibriSpeech clean + other, FLEURS Spanish</h2><p class="note">Word error rate pooled over 450 clips · wait p50, whisker to p90</p><svg id="c-labelled" role="img" aria-label="Scatter: WER against wait on labelled clips"></svg></div>
</div>
<div class="legend" id="legend"></div>
<table id="table"></table>
<details><summary>How this was measured</summary><ul>
<li>One M4 Pro, one system on the GPU at a time, each clip decoded after a warm-up. The live v2t engine could still take the GPU during a dictation.</li>
<li>Wait = seconds from releasing the key to the final text: the whole-file decode for whole-file systems; the last half-second push plus flush for streaming ones, after everything earlier was decoded while recording. Parakeet rows follow v2t's rule (whole-file under 60 s, the 5 s-push stream above).</li>
<li>Error = word error rate after Whisper's text normalisation. Your dictations have no reference, so each system is scored against the transcript the other systems and Wispr Flow's own ASR agree with most (leave-one-out medoid). Low disagreement means "sounds like the rest", not "correct".</li>
<li>RTF = compute over audio; a streaming system needs it well under 1 to keep up live.</li>
<li>Not run: parakeet-unified-en and the English Nemotron streaming model; no faithful MLX runtime exists for either (see utils/asr_grid/README.md).</li>
</ul></details>
<footer>ASR grid report · generated __STAMP__ · voice2text branch claude/cool-mendel-f8031c, utils/asr_grid · private: ~/.v2t/eval/grid/__FILE__</footer>
</main><div class="tip" id="tip"></div>
<script>
const DATA=__DATA__;
const THEMES=['system','light','dark'];let THEME=document.documentElement.dataset.theme||'system';
function setTheme(t){THEME=t;document.documentElement.dataset.theme=t;document.getElementById('theme').textContent='Theme: '+t[0].toUpperCase()+t.slice(1);try{localStorage.setItem('html-theme',t)}catch{}}
setTheme(THEME);document.getElementById('theme').onclick=()=>setTheme(THEMES[(THEMES.indexOf(THEME)+1)%3]);
const NS='http://www.w3.org/2000/svg';const pct=v=>(v*100).toFixed(1)+'%';const sec=v=>v<10?v.toFixed(2)+' s':v.toFixed(1)+' s';
function el(tag,attrs,parent){const e=document.createElementNS(NS,tag);for(const k in attrs)e.setAttribute(k,attrs[k]);parent&&parent.appendChild(e);return e}
function shape(g,mode,x,y,r){const st=`fill:var(--s-${mode});stroke:var(--surface);stroke-width:2`;
 if(mode==='stream')return el('path',{d:`M${x},${y-r-1.5}L${x+r+1.5},${y}L${x},${y+r+1.5}L${x-r-1.5},${y}Z`,style:st},g);
 if(mode==='offline')return el('rect',{x:x-r,y:y-r,width:2*r,height:2*r,rx:2,style:st},g);
 return el('circle',{cx:x,cy:y,r:r,style:st},g)}
const tip=document.getElementById('tip');
function chart(id,key){const svg=document.getElementById(id);const W=520,H=330,m={l:52,r:18,t:12,b:44};svg.setAttribute('viewBox',`0 0 ${W} ${H}`);svg.style.width='100%';
 const pts=DATA.systems.filter(s=>s[key]);if(!pts.length){el('text',{x:W/2,y:H/2,'text-anchor':'middle',style:'fill:var(--fg3);font-size:13px'},svg).textContent='No finished cells yet';return}
 const xs=pts.flatMap(s=>[s[key].p50,s[key].p90]);const lo=Math.log10(Math.max(0.05,Math.min(...xs)*0.7)),hi=Math.log10(Math.max(...xs)*1.4);
 const ymax=Math.max(...pts.map(s=>s[key].wer))*1.25;const X=v=>m.l+(Math.log10(v)-lo)/(hi-lo)*(W-m.l-m.r);const Y=v=>H-m.b-(v/ymax)*(H-m.t-m.b);
 const ticks=[0.05,0.1,0.2,0.3,0.5,1,2,3,5,10,20,30,50].filter(t=>Math.log10(t)>=lo&&Math.log10(t)<=hi);
 for(const t of ticks){el('line',{x1:X(t),x2:X(t),y1:m.t,y2:H-m.b,style:'stroke:var(--grid)'},svg);el('text',{x:X(t),y:H-m.b+16,'text-anchor':'middle',style:'fill:var(--fg3);font-size:11px'},svg).textContent=t+'s'}
 const step=ymax>0.2?0.05:ymax>0.1?0.02:0.01;for(let v=0;v<=ymax;v+=step){el('line',{x1:m.l,x2:W-m.r,y1:Y(v),y2:Y(v),style:'stroke:var(--grid)'},svg);el('text',{x:m.l-7,y:Y(v)+4,'text-anchor':'end',style:'fill:var(--fg3);font-size:11px'},svg).textContent=Math.round(v*100)+'%'}
 el('text',{x:(m.l+W-m.r)/2,y:H-8,'text-anchor':'middle',style:'fill:var(--fg2);font-size:12px'},svg).textContent='wait after release (log scale)';
 const placed=[];
 for(const s of pts.sort((a,b)=>a[key].p50-b[key].p50)){const d=s[key],x=X(d.p50),y=Y(d.wer);const g=el('g',{},svg);
  el('line',{x1:x,x2:X(d.p90),y1:y,y2:y,style:`stroke:var(--s-${s.mode});stroke-width:2;stroke-linecap:round;opacity:.55`},g);
  if(s.id==='parakeet-v3')el('circle',{cx:x,cy:y,r:10,style:'fill:none;stroke:var(--fg);stroke-width:1.5'},g);
  shape(g,s.mode,x,y,5.5);let ly=y-9;while(placed.some(p=>Math.abs(p.y-ly)<13&&Math.abs(p.x-x)<150))ly+=14;placed.push({x,y:ly});
  const t=el('text',{x:x+9,y:ly,style:`fill:var(--fg);font-size:11.5px;font-weight:${s.id==='parakeet-v3'?700:400}`},g);t.textContent=s.name;
  const hit=el('circle',{cx:x,cy:y,r:14,style:'fill:transparent;cursor:default'},g);
  hit.onmousemove=e=>{tip.innerHTML=`<b>${s.name}</b>${DATA.pipelines[s.mode]}<br>error ${pct(d.wer)} · wait p50 ${sec(d.p50)} · p90 ${sec(d.p90)}${d.rtf!==undefined?`<br>compute ${d.rtf.toFixed(2)}× audio`:''}<br>${d.n} clips`;tip.style.left=e.clientX+14+'px';tip.style.top=e.clientY+14+'px';tip.style.opacity=1};
  hit.onmouseleave=()=>tip.style.opacity=0}}
chart('c-wispr','wispr');chart('c-labelled','labelled');
const lg=document.getElementById('legend');for(const [mode,label] of Object.entries(DATA.pipelines)){const sp=document.createElement('span');const s=el('svg',{width:14,height:14,viewBox:'0 0 14 14'});shape(s,mode,7,7,4.5);sp.appendChild(s);sp.append(label);lg.appendChild(sp)}
const cols=[['ls-clean','LS clean'],['ls-other','LS other'],['fleurs-es','FLEURS es']];
const best=k=>Math.min(...DATA.systems.map(s=>s.sets[k]?s.sets[k].wer:9));
let h='<tr><th>system</th><th>pipeline</th>'+cols.map(c=>`<th>${c[1]}</th>`).join('')+'<th>your dictations</th><th>wait p50</th><th>p90</th><th>max</th><th>compute / audio</th></tr>';
for(const s of DATA.systems){const w=s.wispr;h+=`<tr><td>${s.name}</td><td>${s.mode==='hacky'?'v2t rule':s.mode==='stream'?'streaming':'whole-file'}</td>`+
 cols.map(c=>{const v=s.sets[c[0]];return v?`<td class="${v.wer===best(c[0])?'best':''}">${pct(v.wer)}</td>`:'<td>–</td>'}).join('')+
 (w?`<td class="${w.wer===best('wispr')?'best':''}">${pct(w.wer)}</td><td>${sec(w.p50)}</td><td>${sec(w.p90)}</td><td>${sec(w.max)}</td><td>${w.rtf.toFixed(2)}×</td>`:'<td>–</td><td>–</td><td>–</td><td>–</td><td>–</td>')+'</tr>'}
document.getElementById('table').innerHTML=h;
</script></body></html>
"""


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--headline", default="ASR grid: results so far")
    p.add_argument("--sub", default="")
    a = p.parse_args(argv)
    now = datetime.now(ZoneInfo("Europe/London"))
    name = f"{now.date().isoformat()}-grid-report.html"
    page = (
        PAGE.replace("__DATA__", json.dumps(collect()))
        .replace("__HEADLINE__", html.escape(a.headline))
        .replace("__SUB__", html.escape(a.sub))
        .replace("__DATE__", now.date().isoformat())
        .replace("__STAMP__", now.strftime("%Y-%m-%d %H:%M %Z"))
        .replace("__FILE__", name)
    )
    path = grid.GRID / name
    path.write_text(page)
    path.chmod(0o600)
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
