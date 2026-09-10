"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
const match = html.match(/\/\* task-live-logic:start \*\/([\s\S]*?)\/\* task-live-logic:end \*\//);
assert.ok(match, "task live pure-logic block must remain extractable");

const context = {};
vm.runInNewContext(match[1] + `
  globalThis.taskLiveLogic = {
    appendLiveAssistant,
    mergeAssistantSegments,
    taskConversationMessages,
    taskCancelControl
  };
`, context, { filename: "index.html#task-live-logic" });

const {
  appendLiveAssistant,
  mergeAssistantSegments,
  taskConversationMessages,
  taskCancelControl
} = context.taskLiveLogic;

const first = appendLiveAssistant(null, "第一", "2026-09-01T01:00:00Z", 0);
const complete = appendLiveAssistant(first, "段回复", "2026-09-01T01:00:01Z", 2);
assert.equal(complete.text, "第一段回复", "chunks concatenate without invented newlines");
assert.equal(complete.createdAt, "2026-09-01T01:00:00Z", "first chunk owns the live timestamp");

assert.equal(mergeAssistantSegments("第一", complete.segments), "第一段回复");
assert.equal(mergeAssistantSegments("第一段回复", complete.segments), "第一段回复");
assert.equal(mergeAssistantSegments("ha", [{ offset: 2, text: "ha" }]), "haha", "identical adjacent chunks are not deduplicated");
assert.equal(mergeAssistantSegments("你好", [{ offset: 2, text: "世界" }]), "你好世界", "offsets count Unicode code points");

const persisted = [
  { role: "user", text: "问题", createdAt: "2026-09-01T00:59:00Z" },
  { role: "assistant", text: "第一", createdAt: "2026-09-01T01:00:00Z" }
];
const view = taskConversationMessages(persisted, complete);
assert.equal(view.length, 2, "stream and persisted assistant render as one message");
assert.equal(view[1].text, "第一段回复");
assert.equal(view[1].livePhase, "streaming");
assert.equal(persisted[1].text, "第一", "view merge does not mutate API history");

const interrupted = taskConversationMessages(persisted, { ...complete, phase: "interrupted" });
assert.equal(interrupted.length, 2);
assert.equal(interrupted[1].text, "第一段回复");
assert.equal(interrupted[1].livePhase, "interrupted");

assert.deepEqual({ ...taskCancelControl("starting", false, false) }, { visible: true, enabled: true, label: "停止" });
assert.deepEqual({ ...taskCancelControl("starting", true, false) }, { visible: true, enabled: false, label: "停止中" });
assert.deepEqual({ ...taskCancelControl("running", false, false) }, { visible: true, enabled: true, label: "停止" });
assert.deepEqual({ ...taskCancelControl("running", true, false) }, { visible: true, enabled: false, label: "停止中" });
assert.deepEqual({ ...taskCancelControl("cancel_requested", false, false) }, { visible: true, enabled: false, label: "停止中" });
assert.deepEqual({ ...taskCancelControl("awaiting_approval", false, false) }, { visible: true, enabled: true, label: "取消" });
assert.deepEqual({ ...taskCancelControl("awaiting_approval", false, true) }, { visible: false, enabled: false, label: "" });
assert.deepEqual({ ...taskCancelControl("cancelled", false, false) }, { visible: false, enabled: false, label: "" });

console.log("task live logic: 22 assertions passed");
