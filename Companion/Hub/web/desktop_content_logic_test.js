"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
const match = html.match(/\/\* desktop-content-logic:start \*\/([\s\S]*?)\/\* desktop-content-logic:end \*\//);
assert.ok(match, "desktop content pure-logic block must remain extractable");

const context = {};
vm.runInNewContext(match[1] + `
  globalThis.desktopContentLogic = {
    shouldRequestDesktopContent,
    nextContentUnavailableRef
  };
`, context, { filename: "index.html#desktop-content-logic" });

const { shouldRequestDesktopContent, nextContentUnavailableRef } = context.desktopContentLogic;
const state = {
  connected: true,
  observerMode: "unavailable",
  publicRef: "thread-a",
  selectedRef: "thread-a",
  contentLoading: false,
  force: true,
  hasContent: false,
  contentRef: "",
  unavailableRef: "",
  retryUnavailable: false
};
let requests = 0;

function refresh() {
  if (shouldRequestDesktopContent(state)) requests += 1;
}

refresh();
assert.equal(requests, 0, "an unavailable observer makes no content request");

state.observerMode = "shared_live";
refresh();
assert.equal(requests, 1, "the selected thread requests once when the observer is available");

state.unavailableRef = nextContentUnavailableRef(state.unavailableRef, {
  type: "unavailable", publicRef: state.publicRef
});
refresh();
refresh();
assert.equal(requests, 1, "repeated automatic refreshes do not retry a selected 503");

state.unavailableRef = nextContentUnavailableRef(state.unavailableRef, { type: "retry" });
state.retryUnavailable = true;
refresh();
state.retryUnavailable = false;
assert.equal(requests, 2, "an explicit retry requests content again");

state.unavailableRef = nextContentUnavailableRef(state.unavailableRef, {
  type: "unavailable", publicRef: state.publicRef
});
state.observerMode = "unavailable";
refresh();
assert.equal(requests, 2, "an unavailable observer still makes no request after a 503");

state.unavailableRef = nextContentUnavailableRef(state.unavailableRef, {
  type: "observer", previousMode: "unavailable", nextMode: "shared_live"
});
state.observerMode = "shared_live";
refresh();
assert.equal(requests, 3, "observer recovery clears the selected 503 gate");

state.unavailableRef = nextContentUnavailableRef("thread-a", { type: "reset" });
state.publicRef = "thread-b";
state.selectedRef = "thread-b";
refresh();
assert.equal(requests, 4, "changing threads clears the prior thread's 503 gate");

console.log("desktop content logic: 8 assertions passed");
