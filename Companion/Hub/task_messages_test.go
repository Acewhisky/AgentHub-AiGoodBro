package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestTaskMessageStoreKeepsMessagesInProcessOnly(t *testing.T) {
	dataDir := filepath.Join(t.TempDir(), "data")
	store, err := openTaskMessageStore(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	for _, message := range []TaskMessage{
		{TaskID: "task-12345678", Role: "user", Text: "normal prompt", CreatedAt: now},
		{TaskID: "task-12345678", Role: "assistant", Text: "normal ", CreatedAt: now.Add(time.Second)},
		{TaskID: "task-12345678", Role: "assistant", Text: "response", CreatedAt: now.Add(2 * time.Second)},
	} {
		if err := store.append(message); err != nil {
			t.Fatal(err)
		}
	}
	messages := store.taskMessages("task-12345678")
	if len(messages) != 2 || messages[0].Role != "user" || messages[0].Text != "normal prompt" ||
		messages[1].Role != "assistant" || messages[1].Text != "normal response" || !messages[1].CreatedAt.Equal(now.Add(time.Second)) {
		t.Fatalf("in-process messages were not aggregated: %#v", messages)
	}
	if _, err := os.Stat(dataDir); !os.IsNotExist(err) {
		t.Fatalf("opening or appending created durable message storage: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	if got := store.taskMessages("task-12345678"); len(got) != 0 {
		t.Fatalf("Close retained messages: %#v", got)
	}
	if err := store.append(TaskMessage{TaskID: "task-12345678", Role: "user", Text: "after close", CreatedAt: now}); err == nil {
		t.Fatal("append after Close succeeded")
	}
}

func TestTaskMessageStoreLeavesLegacyFileUntouched(t *testing.T) {
	dataDir := filepath.Join(t.TempDir(), "data")
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dataDir, "task-messages.ndjson")
	legacy := []byte("not parsed or modified by the in-memory message store\n")
	if err := os.WriteFile(path, legacy, 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := openTaskMessageStore(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.append(TaskMessage{TaskID: "task-12345678", Role: "user", Text: "in process only", CreatedAt: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(legacy) {
		t.Fatalf("legacy file changed: %q", got)
	}
}

func TestKimiNDJSONAssistantChunksBecomeCompleteMessage(t *testing.T) {
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	task, err := hub.create(CreateRequest{
		RequestID: "kimi-message-create-0001", Agent: "kimi", Project: "demo", Prompt: "original question",
	})
	if err != nil {
		t.Fatal(err)
	}
	stream := strings.Join([]string{
		`{"role":"assistant","content":"first "}`,
		`{"role":"tool","tool_call_id":"tool-12345678","content":"not part of assistant"}`,
		`{"role":"assistant","content":"complete answer"}`,
		`{"role":"meta","type":"session.resume_hint","session_id":"52345678-abcd-4000-acde-1234567890ab"}`,
	}, "\n")
	hub.scanOutput(task.ID, "kimi", "stdout", strings.NewReader(stream))

	conversation, err := hub.taskConversation(task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Agent != "kimi" || len(conversation.Messages) != 2 {
		t.Fatalf("unexpected Kimi conversation: %#v", conversation)
	}
	if conversation.Messages[0].Role != "user" || conversation.Messages[0].Text != "original question" {
		t.Fatalf("Kimi user prompt missing: %#v", conversation.Messages)
	}
	if conversation.Messages[1].Role != "assistant" || conversation.Messages[1].Text != "first complete answer" {
		t.Fatalf("Kimi assistant chunks not aggregated: %#v", conversation.Messages)
	}

	api := &API{hub: hub, requireTokenSet: true, requireToken: false}
	request := httptest.NewRequest(http.MethodGet, "/api/tasks/"+task.ID+"/messages", nil)
	response := httptest.NewRecorder()
	api.routes().ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"text":"first complete answer"`) {
		t.Fatalf("task messages API response = %d %s", response.Code, response.Body.String())
	}
}

func TestKimiAssistantOutputEventIsTypedForLiveConversation(t *testing.T) {
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	_, events, unsubscribe := hub.subscribe(0)
	defer unsubscribe()

	hub.handleOutputLine("task-live-kimi", "kimi", "stdout", `{"role":"assistant","content":"你好"}`)
	assistant := <-events
	if assistant.Type != "agent.output" || assistant.OutputKind != "assistant" || assistant.MessageOffset != 0 || assistant.Text != "你好" {
		t.Fatalf("assistant live event was not typed: %#v", assistant)
	}
	hub.handleOutputLine("task-live-kimi", "kimi", "stdout", `{"role":"assistant","content":"世界"}`)
	continued := <-events
	if continued.OutputKind != "assistant" || continued.MessageOffset != 2 || continued.Text != "世界" {
		t.Fatalf("assistant live event offset was not rune-safe: %#v", continued)
	}

	hub.handleOutputLine("task-live-kimi", "kimi", "stdout", `{"role":"tool","content":"tool chunk"}`)
	tool := <-events
	if tool.Type != "agent.output" || tool.OutputKind != "" || tool.Text != "[tool] tool chunk" {
		t.Fatalf("tool output was confused with assistant text: %#v", tool)
	}
}

func TestHubDoesNotRestoreTaskMessagesAfterRestart(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	first, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	task, err := first.create(CreateRequest{
		RequestID: "kimi-message-restart-0001", Agent: "kimi", Project: "demo", Prompt: "survives restart",
	})
	if err != nil {
		first.shutdown(context.Background())
		t.Fatal(err)
	}
	first.handleOutputLine(task.ID, "kimi", "stdout", `{"role":"assistant","content":"restored answer"}`)
	first.shutdown(context.Background())

	restarted, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { restarted.shutdown(context.Background()) })
	conversation, err := restarted.taskConversation(task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(conversation.Messages) != 0 {
		t.Fatalf("Hub restart retained task messages: %#v", conversation.Messages)
	}
}

func TestTaskConversationIncludesResumeChain(t *testing.T) {
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	parentDTO, err := hub.create(CreateRequest{
		RequestID: "kimi-message-chain-parent-0001", Agent: "kimi", Project: "demo", Prompt: "parent question",
	})
	if err != nil {
		t.Fatal(err)
	}
	hub.handleOutputLine(parentDTO.ID, "kimi", "stdout", `{"role":"assistant","content":"parent answer"}`)
	hub.bindSession(parentDTO.ID, "62345678-abcd-4000-acde-1234567890ab")
	hub.mu.Lock()
	parent := hub.tasks[parentDTO.ID]
	if err := hub.transitionLocked(parent, stateStarting, "test_start", "task.approved", nil); err == nil {
		err = hub.transitionLocked(parent, stateRunning, "test_running", "task.running", nil)
	}
	if err == nil {
		err = hub.transitionLocked(parent, stateSucceeded, "test_succeeded", "task.succeeded", nil)
	}
	hub.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	child, err := hub.resume(parentDTO.ID, CreateRequest{RequestID: "kimi-message-chain-child-0001", Prompt: "child question"})
	if err != nil {
		t.Fatal(err)
	}
	hub.handleOutputLine(child.ID, "kimi", "stdout", `{"role":"assistant","content":"child answer"}`)

	conversation, err := hub.taskConversation(child.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"parent question", "parent answer", "child question", "child answer"}
	if len(conversation.Messages) != len(want) {
		t.Fatalf("resume history length = %d, want %d: %#v", len(conversation.Messages), len(want), conversation.Messages)
	}
	for index, text := range want {
		if conversation.Messages[index].Text != text {
			t.Fatalf("resume history[%d] = %q, want %q", index, conversation.Messages[index].Text, text)
		}
	}
}

func TestEmbeddedWebOffersCurrentProcessKimiConversationAndUnavailableDesktopSummary(t *testing.T) {
	html := string(indexHTML)
	for _, required := range []string{
		`/messages`,
		`查看本次会话`,
		`当前运行期间还没有可显示的消息`,
		`服务重启后，内容不会保留`,
		`发送并批准`,
		`resumeKimiConversation`,
		`event.outputKind === "assistant"`,
		`taskConversationMessages`,
		`taskCancelControl`,
		`已中断`,
		`/approve`,
		`task.agent !== "kimi"`,
		`function observerCanReadContent()`,
		`state.observer.mode !== "unavailable"`,
		`function shouldRequestDesktopContent({`,
		`function nextContentUnavailableRef(currentRef, event)`,
		`contentUnavailableRef`,
		`error.code === "codex_content_unavailable"`,
		`retryUnavailable`,
		`if (!observerCanReadContent())`,
		`Desktop 当前未连接，正文没有缓存；重连后会重新读取。`,
		`当前无法读取该线程正文，正文没有缓存；请重试或重连后重新读取。`,
	} {
		if !strings.Contains(html, required) {
			t.Fatalf("embedded web current-process conversation UI is missing %q", required)
		}
	}
}
