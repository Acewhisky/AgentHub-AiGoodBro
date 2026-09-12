#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const htmlPath = path.join(__dirname, "..", "Resources", "UpstreamCharts", "trend.html");
const html = fs.readFileSync(htmlPath, "utf8");
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
  .map((match) => match[1])
  .filter((source) => source.trim().length > 0);
assert.equal(scripts.length, 1, "expected one inline trend adapter");

function harness(charts) {
  const host = { innerHTML: "stale" };
  const context = {
    Number,
    Error,
    window: { TokenMonitorUsageCharts: charts },
    document: { getElementById: (id) => (id === "trend" ? host : null) },
  };
  vm.createContext(context);
  vm.runInContext(scripts[0], context, { filename: "trend.html" });
  return { context, host };
}

const validCharts = {
  areaLineChart: (rows, options) => ({ rows, options }),
  areaLineSvg: (model) => `<svg data-count="${model.rows.length}"></svg>`,
};

{
  const { context, host } = harness(validCharts);
  const svg = context.window.__renderTrend([{ date: "2026-09-12", tokens: 0 }], { width: 320, height: 40 });
  assert.match(svg, /^<svg/);
  assert.equal(host.innerHTML, svg, "success installs SVG output");
}

{
  const { context } = harness(validCharts);
  const svg = context.window.__renderTrend([{ date: "2026-09-12", tokens: 1 }], {});
  assert.match(svg, /data-count="1"/, "single point renders");
  delete context.window.__renderTrend;
  assert.equal(typeof context.window.__renderTrend, "undefined", "missing render function is observable");
}

{
  const { context, host } = harness(validCharts);
  assert.throws(() => context.window.__renderTrend([], {}), /empty/);
  assert.equal(host.innerHTML, "", "empty input cannot leave stale chart content");
}

{
  const { context, host } = harness({
    areaLineChart: () => ({}),
    areaLineSvg: () => null,
  });
  assert.throws(() => context.window.__renderTrend([{ date: "2026-09-12", tokens: 1 }], {}), /no output/);
  assert.equal(host.innerHTML, "", "invalid result clears stale content");
}

{
  const { context, host } = harness({
    areaLineChart: () => { throw new Error("fixture JS error"); },
    areaLineSvg: () => "<svg></svg>",
  });
  assert.throws(() => context.window.__renderTrend([{ date: "2026-09-12", tokens: 1 }], {}), /fixture JS error/);
  assert.equal(host.innerHTML, "", "JS exception clears stale content");
  context.window.TokenMonitorUsageCharts = validCharts;
  assert.match(
    context.window.__renderTrend([{ date: "2026-09-12", tokens: 1 }], {}),
    /^<svg/,
    "adapter recovers after a safe retry"
  );
}

{
  const { context, host } = harness(undefined);
  assert.throws(() => context.window.__renderTrend([{ date: "2026-09-12", tokens: 1 }], {}), /unavailable/);
  assert.equal(host.innerHTML, "", "missing chart library is a failure, not empty data");
}

console.log("upstream trend adapter fixture passed");
