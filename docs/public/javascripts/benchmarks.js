/* Read-only benchmark views. Historical measurements live in benchmarks.json. */
(() => {
  "use strict";
  const element = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const format = (value, unit) => `${unit === "ms" ? value.toFixed(0) : value.toFixed(2)}${unit === "%" ? "%" : ` ${unit}`}`;
  const scale = (maximum) => {
    if (!Number.isFinite(maximum) || maximum < 0) throw new Error("Invalid measurement range");
    if (maximum === 0) return { maximum: 1, ticks: [0, 0.25, 0.5, 0.75, 1] };
    const magnitude = 10 ** Math.floor(Math.log10(maximum / 4));
    const step = [1, 2, 2.5, 5, 10].find((n) => n * magnitude >= maximum / 4) * magnitude;
    const steps = Math.ceil(maximum / step);
    return { maximum: steps * step, ticks: Array.from({ length: steps + 1 }, (_, i) => i * step) };
  };

  function bars(rows, field, unit, title) {
    const section = element("section", "bench-chart");
    section.setAttribute("aria-label", title);
    section.append(element("h3", "bench-metric", title), element("p", "bench-direction", "Lower is better"));
    const range = scale(Math.max(...rows.map((row) => row[field])));
    const max = range.maximum;
    const sorted = [...rows].sort((a, b) => a[field] - b[field]);
    for (const row of sorted) {
      const line = element("div", "bench-bar-row");
      const label = element("div", "bench-row-label", row.name);
      if (row.badge) label.append(element("span", "bench-badge", row.badge));
      const track = element("div", "bench-track");
      track.setAttribute("aria-hidden", "true");
      const fill = element("div", "bench-fill");
      fill.style.width = `${100 * row[field] / max}%`;
      track.append(fill);
      line.append(label, track, element("strong", "bench-value", format(row[field], unit)));
      section.append(line);
    }
    const axis = element("div", "bench-axis");
    for (const value of range.ticks) {
      axis.append(element("span", "", `${Number(value.toFixed(2))}${unit === "%" ? "%" : ` ${unit}`}`));
    }
    section.append(axis);
    return section;
  }

  function measurements(rows, dataset) {
    const details = element("details", "bench-data");
    details.append(element("summary", "", "Recorded measurements"));
    const table = element("table");
    table.append(element("caption", "bench-sr-only", dataset.label));
    const header = element("tr");
    for (const label of ["Model / pipeline", dataset.metric, ...(dataset.latency ? [dataset.latencyLabel] : [])]) {
      const th = element("th", "", label);
      th.scope = "col";
      header.append(th);
    }
    const head = element("thead");
    head.append(header);
    const body = element("tbody");
    for (const row of rows) {
      const line = element("tr");
      line.append(element("td", "", row.name), element("td", "", format(row[dataset.field], dataset.unit)));
      if (dataset.latency) line.append(element("td", "", format(row[dataset.latency], dataset.latencyUnit)));
      body.append(line);
    }
    table.append(head, body);
    const scroll = element("div", "bench-table-scroll");
    scroll.append(table);
    details.append(scroll);
    return details;
  }

  async function initialize() {
    const root = document.querySelector("[data-v2t-bench]");
    if (!root || root.dataset.bound) return;
    root.dataset.bound = "true";
    try {
      const response = await fetch(new URL(root.dataset.source, document.baseURI));
      if (!response.ok) throw new Error(`Measurements returned HTTP ${response.status}`);
      const data = await response.json();
      const url = new URL(location.href);
      let group = data.groups.find((g) => g.id === url.searchParams.get("bench")) || data.groups[0];
      let dataset = group.datasets.find((d) => d.id === url.searchParams.get("dataset")) || group.datasets[0];
      const updateURL = () => {
        const next = new URL(location.href);
        next.searchParams.set("bench", group.id);
        next.searchParams.set("dataset", dataset.id);
        next.searchParams.delete("variant");
        history.replaceState(null, "", next);
      };
      const render = () => {
        root.replaceChildren();
        const tabs = element("div", "bench-tabs");
        tabs.setAttribute("role", "group");
        tabs.setAttribute("aria-label", "Benchmark comparison");
        for (const item of data.groups) {
          const button = element("button", "bench-tab", item.label);
          button.type = "button";
          button.setAttribute("aria-pressed", String(item.id === group.id));
          button.addEventListener("click", () => { group = item; dataset = item.datasets[0]; updateURL(); render(); });
          tabs.append(button);
        }
        const panel = element("div", "bench-panel");
        panel.append(element("p", "bench-context", group.context), element("h2", "bench-title", group.title));
        const controls = element("div", "bench-controls");
        const label = element("label", "", "Compare ");
        const select = element("select", "bench-select");
        select.setAttribute("aria-label", "Dataset or measurement");
        for (const item of group.datasets) {
          const option = element("option", "", item.label);
          option.value = item.id;
          option.selected = item.id === dataset.id;
          select.append(option);
        }
        select.addEventListener("change", () => { dataset = group.datasets.find((d) => d.id === select.value); updateURL(); render(); });
        label.append(select);
        controls.append(label);
        panel.append(controls);
        panel.append(bars(group.rows, dataset.field, dataset.unit, dataset.metric));
        if (dataset.latency) panel.append(bars(group.rows, dataset.latency, dataset.latencyUnit, dataset.latencyLabel));
        panel.append(measurements(group.rows, dataset), element("p", "bench-note", group.note));
        const source = element("a", "bench-source", `${group.sourceLabel} ↗`);
        source.href = group.source;
        panel.append(source);
        root.append(tabs, element("p", "bench-status", data.status), panel);
        root.dataset.ready = "true";
      };
      render();
    } catch (error) {
      root.replaceChildren(element("p", "bench-loading", "The recorded measurements could not be loaded. Reload the page or open the source links below."));
      console.error("V2T benchmark:", error.message);
    }
  }
  if (typeof document$ !== "undefined") document$.subscribe(initialize);
  else if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initialize);
  else initialize();
})();
